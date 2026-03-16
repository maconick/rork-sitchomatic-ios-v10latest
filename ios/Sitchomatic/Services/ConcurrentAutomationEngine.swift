import Foundation
import UIKit

actor AutomationThrottler {
    private var activeCount: Int = 0
    private var maxConcurrency: Int
    private var backoffMs: Int = 0
    private var consecutiveFailures: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isCancelled: Bool = false

    init(maxConcurrency: Int = 5) {
        self.maxConcurrency = maxConcurrency
    }

    func acquire() async -> Bool {
        guard !isCancelled else { return false }
        if activeCount < maxConcurrency {
            activeCount += 1
        } else {
            await withCheckedContinuation { continuation in
                if isCancelled {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
            guard !isCancelled else { return false }
        }
        if backoffMs > 0 {
            try? await Task.sleep(for: .milliseconds(backoffMs))
        }
        return !isCancelled
    }

    func release(succeeded: Bool) {
        activeCount = max(0, activeCount - 1)
        if succeeded {
            consecutiveFailures = 0
            backoffMs = max(0, backoffMs - 200)
        } else {
            consecutiveFailures += 1
            backoffMs = min(10000, 500 * (1 << min(consecutiveFailures, 5)))
        }
        resumeNextWaiterIfPossible()
    }

    private func resumeNextWaiterIfPossible() {
        while !waiters.isEmpty && activeCount < maxConcurrency {
            activeCount += 1
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    func updateMaxConcurrency(_ newMax: Int) {
        let old = maxConcurrency
        maxConcurrency = max(1, min(10, newMax))
        if maxConcurrency > old {
            resumeNextWaiterIfPossible()
        }
    }

    func currentStats() -> (active: Int, maxConcurrency: Int, backoffMs: Int, consecutiveFailures: Int) {
        (activeCount, maxConcurrency, backoffMs, consecutiveFailures)
    }

    func reset() {
        activeCount = 0
        backoffMs = 0
        consecutiveFailures = 0
        isCancelled = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func cancelAll() {
        isCancelled = true
        activeCount = 0
        backoffMs = 0
        consecutiveFailures = 0
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

nonisolated struct ConcurrentBatchResult<T: Sendable>: Sendable {
    let results: [T]
    let totalTimeMs: Int
    let successCount: Int
    let failureCount: Int
    let avgLatencyMs: Int
}

nonisolated struct BatchLiveStats: Sendable {
    let processed: Int
    let total: Int
    let successCount: Int
    let failureCount: Int
    let successRate: Double
    let avgLatencyMs: Int
    let throughputPerMinute: Double
    let estimatedRemainingSeconds: Int
    let elapsedMs: Int
    let deadAccountCount: Int
    let deadCardCount: Int
}

@MainActor
class ConcurrentAutomationEngine {
    static let shared = ConcurrentAutomationEngine()

    private let logger = DebugLogger.shared
    private let coordinator = AIAutomationCoordinator.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let urlCooldown = URLCooldownService.shared
    private let throttler = AutomationThrottler(maxConcurrency: 5)
    private let circuitBreaker = HostCircuitBreakerService.shared
    private let anomalyForecasting = AIAnomalyForecastingService.shared
    private let urlQualityScoring = URLQualityScoringService.shared
    private let aiCredentialPriority = AICredentialPriorityScoringService.shared
    private let proxyQualityDecay = ProxyQualityDecayService.shared
    private let preflightService = PreflightSmokeTestService.shared
    private let customTools = AICustomToolsCoordinator.shared
    private let liveSpeed = LiveSpeedAdaptationService.shared
    private(set) var isRunning: Bool = false
    private var cancelFlag: Bool = false
    private var deadAccounts: Set<String> = []
    private var deadCards: Set<String> = []
    private var consecutiveConnectionFailures: Int = 0
    private let nodeMavenAutoRotateThreshold: Int = 3
    private var autoPaused: Bool = false
    private let autoPauseFailureThreshold: Double = 0.8
    private let autoPauseWindowSize: Int = 10
    private let autoPauseDurationSeconds: Int = 30
    private var recentOutcomeWindow: [Bool] = []
    private var credentialRetryTracker: [String: Int] = [:]
    private let maxCredentialRetries: Int = 3
    private var consecutiveAllFailBatches: Int = 0
    private let maxAllFailBackoffMs: Int = 30000
    private var batchDeadline: Date?
    private var rateLimitSignalCount: Int = 0
    private var autoPauseTriggerCount: Int = 0
    private let autoPauseEscalationFactor: Double = 0.6
    var onBatchStats: ((BatchLiveStats) -> Void)?

    func cancel() {
        cancelFlag = true
    }

    private func computeLiveStats(processed: Int, total: Int, successCount: Int, failureCount: Int, latencies: [Int], startTime: Date) -> BatchLiveStats {
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count
        let successRate = (successCount + failureCount) > 0 ? Double(successCount) / Double(successCount + failureCount) : 0
        let elapsedMinutes = max(0.01, Double(elapsedMs) / 60000.0)
        let throughput = Double(processed) / elapsedMinutes
        let remaining = processed > 0 ? Int(Double(total - processed) / max(0.01, throughput) * 60) : 0
        return BatchLiveStats(
            processed: processed,
            total: total,
            successCount: successCount,
            failureCount: failureCount,
            successRate: successRate,
            avgLatencyMs: avgLatency,
            throughputPerMinute: throughput,
            estimatedRemainingSeconds: remaining,
            elapsedMs: elapsedMs,
            deadAccountCount: deadAccounts.count,
            deadCardCount: deadCards.count
        )
    }

    private func checkAutoPause(processed: Int, total: Int, successCount: Int, failureCount: Int, latencies: [Int], startTime: Date) async -> Bool {
        let windowToCheck = max(5, autoPauseWindowSize - (autoPauseTriggerCount * 2))
        let thresholdToUse = max(0.5, autoPauseFailureThreshold - (Double(autoPauseTriggerCount) * autoPauseEscalationFactor * 0.1))

        let failureRate = recentOutcomeWindow.count >= windowToCheck
            ? Double(recentOutcomeWindow.suffix(windowToCheck).filter { !$0 }.count) / Double(windowToCheck)
            : 0
        if failureRate >= thresholdToUse && recentOutcomeWindow.count >= windowToCheck {
            autoPauseTriggerCount += 1
            let escalatedDuration = min(120, autoPauseDurationSeconds + (autoPauseTriggerCount * 10))
            autoPaused = true
            logger.log("ConcurrentEngine: AUTO-PAUSED (#\(autoPauseTriggerCount)) — \(Int(failureRate * 100))% failure rate over last \(windowToCheck) attempts. Waiting \(escalatedDuration)s (threshold=\(Int(thresholdToUse * 100))%)", category: .automation, level: .critical)
            let stats = computeLiveStats(processed: processed, total: total, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
            onBatchStats?(stats)
            try? await Task.sleep(for: .seconds(escalatedDuration))
            recentOutcomeWindow = Array(recentOutcomeWindow.suffix(3))
            autoPaused = false
            logger.log("ConcurrentEngine: resuming after auto-pause #\(autoPauseTriggerCount)", category: .automation, level: .info)
            return true
        }
        if recentOutcomeWindow.suffix(windowToCheck).filter({ $0 }).count > windowToCheck / 2 {
            autoPauseTriggerCount = max(0, autoPauseTriggerCount - 1)
        }
        return false
    }

    private func isBatchDeadlineExceeded() -> Bool {
        guard let deadline = batchDeadline else { return false }
        return Date() >= deadline
    }

    func runConcurrentPPSRBatch(
        checks: [PPSRCheck],
        engine: PPSRAutomationEngine,
        maxConcurrency: Int = 5,
        timeout: TimeInterval = 90,
        onProgress: @escaping (Int, Int, CheckOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, CheckOutcome)> {
        isRunning = true
        cancelFlag = false
        deadCards.removeAll()
        recentOutcomeWindow.removeAll()
        let startTime = Date()
        let batchId = "concurrent_ppsr_\(UUID().uuidString.prefix(8))"

        let stabilityCap = CrashProtectionService.shared.recommendedMaxConcurrency
        let effectiveMaxConcurrency = min(maxConcurrency, stabilityCap)
        if effectiveMaxConcurrency < maxConcurrency {
            logger.log("ConcurrentEngine: concurrency capped \(maxConcurrency) → \(effectiveMaxConcurrency) by stability monitor", category: .automation, level: .warning)
        }
        await throttler.updateMaxConcurrency(effectiveMaxConcurrency)

        AppStabilityCoordinator.shared.registerTaskGroupWatchdog(id: batchId, timeout: Double(checks.count) * timeout * 0.8) { [weak self] in
            self?.logger.log("ConcurrentEngine: PPSR batch watchdog FIRED — force cancelling", category: .automation, level: .critical)
            self?.cancel()
        }
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        logger.startSession(batchId, category: .ppsr, message: "ConcurrentEngine: starting \(checks.count) PPSR checks, maxConcurrency=\(maxConcurrency)")

        ScreenshotCacheService.shared.resetBatchCounter()

        let proxyOK = await performProxyPreCheck(batchId: batchId)
        if !proxyOK {
            logger.log("ConcurrentEngine: proxy pre-check FAILED — rotating proxy before batch", category: .network, level: .warning)
        }

        var allResults: [(String, CheckOutcome)] = []
        var successCount = 0
        var failureCount = 0
        var latencies: [Int] = []
        var processed = 0

        let batchSize = maxConcurrency
        for batchStart in stride(from: 0, to: checks.count, by: batchSize) {
            if cancelFlag { break }

            if CrashProtectionService.shared.isMemoryDeathSpiral {
                logger.log("ConcurrentEngine: PPSR batch aborting — memory death spiral detected", category: .automation, level: .critical)
                break
            }

            let currentCap = CrashProtectionService.shared.recommendedMaxConcurrency
            if currentCap < batchSize {
                await throttler.updateMaxConcurrency(currentCap)
            }

            let batchEnd = min(batchStart + batchSize, checks.count)
            let batch = Array(checks[batchStart..<batchEnd])

            let batchResults: [(String, CheckOutcome, Int)] = await withTaskGroup(of: (String, CheckOutcome, Int).self) { group in
                for check in batch {
                    if self.cancelFlag { break }
                    let cardId = check.card.id
                    if self.deadCards.contains(cardId) {
                        self.logger.log("ConcurrentEngine: skipping dead card \(check.card.displayNumber)", category: .automation, level: .info)
                        continue
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return (cardId, CheckOutcome.timeout, 0) }
                        let acquired = await self.throttler.acquire()
                        guard acquired else { return (cardId, CheckOutcome.timeout, 0) }
                        guard !Task.isCancelled else {
                            await self.throttler.release(succeeded: false)
                            return (cardId, CheckOutcome.timeout, 0)
                        }
                        let taskStart = Date()
                        let outcome = await engine.runCheck(check, timeout: timeout)
                        let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                        let succeeded = outcome == .pass
                        await self.throttler.release(succeeded: succeeded)
                        return (cardId, outcome, latency)
                    }
                }

                var results: [(String, CheckOutcome, Int)] = []
                for await result in group {
                    results.append(result)
                    if self.cancelFlag {
                        group.cancelAll()
                        break
                    }
                }
                return results
            }

            for (cardId, outcome, latency) in batchResults {
                allResults.append((cardId, outcome))
                latencies.append(latency)
                if outcome == .pass {
                    successCount += 1
                } else {
                    failureCount += 1
                    if outcome == .failInstitution {
                        deadCards.insert(cardId)
                        logger.log("ConcurrentEngine: card \(cardId) marked DEAD (failInstitution)", category: .automation, level: .warning)
                    }
                }
                processed += 1
                recentOutcomeWindow.append(outcome == .pass)
                onProgress(processed, checks.count, outcome)
            }

            if processed % 2 == 0 || processed == checks.count {
                let stats = computeLiveStats(processed: processed, total: checks.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
                onBatchStats?(stats)
            }

            let didPause = await checkAutoPause(processed: processed, total: checks.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
            if didPause && cancelFlag { break }

            let throttleCheck = coordinator.shouldThrottle()
            if throttleCheck.shouldThrottle {
                logger.log("ConcurrentEngine: throttling for \(String(format: "%.1f", throttleCheck.waitSeconds))s", category: .automation, level: .warning)
                try? await Task.sleep(for: .seconds(throttleCheck.waitSeconds))
            }

            let anomalyThrottle = anomalyForecasting.shouldThrottleRequests(key: "ppsr_batch")
            if anomalyThrottle.shouldThrottle {
                logger.log("ConcurrentEngine: anomaly forecasting throttle \(anomalyThrottle.delayMs)ms", category: .automation, level: .warning)
                try? await Task.sleep(for: .milliseconds(anomalyThrottle.delayMs))
            }

            if coordinator.adaptiveConcurrency && processed > 3 {
                let recentOutcomes = batchResults.map { (cardId: $0.0, outcome: $0.1, latencyMs: $0.2) }
                let analytics = coordinator.computeBatchAnalytics(outcomes: recentOutcomes)
                let anomalyConcurrency = anomalyForecasting.recommendedConcurrency(key: "ppsr_batch", currentMax: analytics.suggestedConcurrency)
                let finalConcurrency = min(analytics.suggestedConcurrency, anomalyConcurrency)
                if finalConcurrency != maxConcurrency {
                    await throttler.updateMaxConcurrency(finalConcurrency)
                    logger.log("ConcurrentEngine: adaptive concurrency → \(finalConcurrency) (anomaly: \(anomalyConcurrency))", category: .automation, level: .info)
                }
            }

            if batchEnd < checks.count && !cancelFlag {
                let batchSuccessRate = batchResults.isEmpty ? 0.5 : Double(batchResults.filter { $0.1 == .pass }.count) / Double(batchResults.count)
                let cooldown: Int
                if batchSuccessRate > 0.8 {
                    cooldown = Int.random(in: 150...400)
                } else if batchSuccessRate < 0.3 {
                    cooldown = Int.random(in: 1200...2500)
                    logger.log("ConcurrentEngine: low success rate (\(Int(batchSuccessRate * 100))%) — extended cooldown \(cooldown)ms", category: .automation, level: .warning)
                } else {
                    cooldown = Int.random(in: 300...800)
                }
                try? await Task.sleep(for: .milliseconds(cooldown))
            }
        }

        let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count

        AppStabilityCoordinator.shared.cancelTaskGroupWatchdog(id: batchId)
        logger.endSession(batchId, category: .ppsr, message: "ConcurrentEngine: batch complete — \(successCount) pass, \(failureCount) fail, avgLatency=\(avgLatency)ms, total=\(totalMs)ms")

        if allResults.count >= 3 {
            Task {
                let batchResults = allResults.map { (cardId: $0.0, outcome: "\($0.1)", latencyMs: avgLatency) }
                let _ = await customTools.summarizeBatchPerformance(
                    batchId: batchId,
                    results: batchResults,
                    concurrency: maxConcurrency,
                    proxyTarget: "ppsr",
                    networkMode: "default",
                    stealthEnabled: engine.stealthEnabled,
                    fingerprintSpoofing: false,
                    pageLoadTimeout: Int(timeout),
                    submitRetryCount: engine.retrySubmitOnFail ? 1 : 0
                )
            }
        }

        isRunning = false
        return ConcurrentBatchResult(
            results: allResults,
            totalTimeMs: totalMs,
            successCount: successCount,
            failureCount: failureCount,
            avgLatencyMs: avgLatency
        )
    }

    func runConcurrentLoginBatch(
        attempts: [LoginAttempt],
        urls: [URL],
        engine: LoginAutomationEngine,
        maxConcurrency: Int = 5,
        timeout: TimeInterval = 90,
        proxyTarget: ProxyRotationService.ProxyTarget = .joe,
        onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, LoginOutcome)> {
        let sortedUsernames = aiCredentialPriority.sortedCredentials(attempts.map { $0.credential.username })
        let usernameOrder = Dictionary(uniqueKeysWithValues: sortedUsernames.enumerated().map { ($1, $0) })
        let attempts = attempts.sorted { a, b in
            let orderA = usernameOrder[a.credential.username] ?? Int.max
            let orderB = usernameOrder[b.credential.username] ?? Int.max
            return orderA < orderB
        }
        logger.log("ConcurrentEngine: credentials reordered by AI priority scoring", category: .automation, level: .info)

        isRunning = true
        cancelFlag = false
        deadAccounts.removeAll()
        recentOutcomeWindow.removeAll()
        autoPauseTriggerCount = 0
        rateLimitSignalCount = 0
        let startTime = Date()
        let batchId = "concurrent_login_\(UUID().uuidString.prefix(8))"
        let maxBatchDurationSeconds: TimeInterval = max(300, Double(attempts.count) * timeout * 0.6)
        batchDeadline = Date().addingTimeInterval(maxBatchDurationSeconds)
        logger.log("ConcurrentEngine: batch deadline set to \(Int(maxBatchDurationSeconds))s from now", category: .automation, level: .info)

        let stabilityCap = CrashProtectionService.shared.recommendedMaxConcurrency
        let effectiveMaxConcurrency = min(maxConcurrency, stabilityCap)
        if effectiveMaxConcurrency < maxConcurrency {
            logger.log("ConcurrentEngine: login concurrency capped \(maxConcurrency) → \(effectiveMaxConcurrency) by stability monitor", category: .automation, level: .warning)
        }
        await throttler.updateMaxConcurrency(effectiveMaxConcurrency)

        AppStabilityCoordinator.shared.registerTaskGroupWatchdog(id: batchId, timeout: maxBatchDurationSeconds * 1.2) { [weak self] in
            self?.logger.log("ConcurrentEngine: login batch watchdog FIRED — force cancelling", category: .automation, level: .critical)
            self?.cancel()
        }

        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let proxyService = ProxyRotationService.shared
        let networkMode = proxyService.connectionMode(for: proxyTarget)
        let networkSummary = proxyService.networkSummary(for: proxyTarget)
        engine.proxyTarget = proxyTarget

        logger.startSession(batchId, category: .login, message: "ConcurrentEngine: starting \(attempts.count) login tests across \(urls.count) URLs | network=\(networkSummary) mode=\(networkMode.label) target=\(proxyTarget.rawValue)")

        ScreenshotCacheService.shared.resetBatchCounter()
        consecutiveConnectionFailures = 0

        let stealthOn = engine.stealthEnabled
        let netConfig = networkFactory.nextConfig(for: proxyTarget)
        WebViewPool.shared.preWarm(count: min(maxConcurrency, 3), stealthEnabled: stealthOn, networkConfig: netConfig, target: proxyTarget)

        let proxyOK = await performProxyPreCheck(batchId: batchId)
        if !proxyOK {
            logger.log("ConcurrentEngine: proxy pre-check FAILED for login batch — proceeding with caution", category: .network, level: .warning)
        }

        let wireProxyOK = await performWireProxyHealthGate(for: proxyTarget)
        if !wireProxyOK {
            logger.log("ConcurrentEngine: WireProxy health gate FAILED — batch proceeding with caution", category: .network, level: .critical)
        }

        let preflightResult = await preflightService.runPreflightForAllURLs(
            urls: urls,
            networkConfig: netConfig,
            proxyTarget: proxyTarget,
            stealthEnabled: engine.stealthEnabled,
            timeout: 12
        )
        let healthyURLs: [URL]
        if preflightResult.healthyURLs.isEmpty {
            logger.log("ConcurrentEngine: ALL URLs failed preflight — using original list with caution", category: .automation, level: .critical)
            healthyURLs = urls
        } else {
            if !preflightResult.failedURLs.isEmpty {
                for failed in preflightResult.failedURLs {
                    logger.log("ConcurrentEngine: preflight SKIP \(failed.url.host ?? "") — \(failed.reason)", category: .automation, level: .warning)
                }
            }
            logger.log("ConcurrentEngine: preflight passed \(preflightResult.healthyURLs.count)/\(urls.count) URLs in \(preflightResult.totalMs)ms", category: .automation, level: .success)
            healthyURLs = preflightResult.healthyURLs
        }

        var allResults: [(String, LoginOutcome)] = []
        var successCount = 0
        var failureCount = 0
        var latencies: [Int] = []
        var processed = 0
        var carryOverIndices: [Int] = []
        credentialRetryTracker.removeAll()
        consecutiveAllFailBatches = 0

        let batchSize = effectiveMaxConcurrency
        for batchStart in stride(from: 0, to: attempts.count, by: batchSize) {
            if cancelFlag { break }
            if isBatchDeadlineExceeded() {
                logger.log("ConcurrentEngine: BATCH DEADLINE EXCEEDED after \(Int(Date().timeIntervalSince(startTime)))s — stopping batch", category: .automation, level: .critical)
                break
            }

            if CrashProtectionService.shared.isMemoryDeathSpiral {
                logger.log("ConcurrentEngine: login batch aborting — memory death spiral detected at \(CrashProtectionService.shared.currentMemoryUsageMB())MB", category: .automation, level: .critical)
                PersistentFileStorageService.shared.forceSave()
                LoginViewModel.shared.persistCredentialsNow()
                break
            }

            let currentCap = CrashProtectionService.shared.recommendedMaxConcurrency
            let currentThrottlerMax = await throttler.currentStats().maxConcurrency
            if currentCap < currentThrottlerMax {
                await throttler.updateMaxConcurrency(currentCap)
                logger.log("ConcurrentEngine: stability throttle \(currentThrottlerMax) → \(currentCap)", category: .automation, level: .warning)
            }

            let batchEnd = min(batchStart + batchSize, attempts.count)
            let batchIndices = Array(batchStart..<batchEnd)

            var effectiveURLs: [Int: URL] = [:]
            for index in batchIndices {
                let url = healthyURLs[index % healthyURLs.count]
                let urlHost = url.host ?? ""
                if urlCooldown.isAutoDisabled(url.absoluteString) {
                    logger.log("ConcurrentEngine: URL \(urlHost) is AUTO-DISABLED — skipping", category: .network, level: .warning)
                    let alternate = healthyURLs.first { !self.urlCooldown.isAutoDisabled($0.absoluteString) && !self.urlCooldown.isOnCooldown($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else if urlCooldown.isOnCooldown(url.absoluteString) {
                    let remaining = Int(urlCooldown.cooldownRemaining(url.absoluteString))
                    logger.log("ConcurrentEngine: URL \(urlHost) on cooldown (\(remaining)s left) — rotating", category: .network, level: .warning)
                    let alternate = healthyURLs.first { !self.urlCooldown.isOnCooldown($0.absoluteString) && !self.urlCooldown.isAutoDisabled($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else if !circuitBreaker.shouldAllow(host: urlHost) {
                    let remaining = Int(circuitBreaker.cooldownRemaining(host: urlHost))
                    logger.log("ConcurrentEngine: URL \(urlHost) circuit OPEN (\(remaining)s left) — rotating", category: .network, level: .warning)
                    let alternate = healthyURLs.first { self.circuitBreaker.shouldAllow(host: $0.host ?? "") && !self.urlCooldown.isOnCooldown($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else {
                    effectiveURLs[index] = url
                }
            }

            let batchResults: [(String, LoginOutcome, Int, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
                for index in batchIndices {
                    if self.cancelFlag { break }
                    let attempt = attempts[index]
                    let effectiveURL = effectiveURLs[index] ?? healthyURLs[index % healthyURLs.count]
                    let username = attempt.credential.username

                    if self.deadAccounts.contains(username) {
                        self.logger.log("ConcurrentEngine: skipping dead account \(username)", category: .automation, level: .info)
                        continue
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, index) }
                        let acquired = await self.throttler.acquire()
                        guard acquired, !Task.isCancelled else {
                            if acquired { await self.throttler.release(succeeded: false) }
                            return (username, LoginOutcome.timeout, 0, index)
                        }
                        let taskStart = Date()
                        let outcome = await engine.runLoginTest(attempt, targetURL: effectiveURL, timeout: timeout)
                        let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                        let succeeded = outcome == .success
                        await self.throttler.release(succeeded: succeeded)
                        return (username, outcome, latency, index)
                    }
                }

                var results: [(String, LoginOutcome, Int, Int)] = []
                for await result in group {
                    results.append(result)
                    if self.cancelFlag {
                        group.cancelAll()
                        break
                    }
                }
                return results
            }

            let conclusiveSessions = batchResults.filter { isConclusiveOutcome($0.1) }
            let retryableSessions = batchResults.filter { !isConclusiveOutcome($0.1) }
            let hasRetryable = !retryableSessions.isEmpty
            let allRetryable = !batchResults.isEmpty && conclusiveSessions.isEmpty

            for (username, outcome, latency, _) in conclusiveSessions {
                allResults.append((username, outcome))
                latencies.append(latency)
                let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                urlCooldown.recordSuccess(for: matchingURL)
                if outcome == .success {
                    successCount += 1
                    consecutiveConnectionFailures = 0
                } else {
                    failureCount += 1
                    if outcome == .permDisabled {
                        deadAccounts.insert(username)
                        logger.log("ConcurrentEngine: account '\(username)' marked DEAD (permDisabled)", category: .automation, level: .warning)
                    }
                    consecutiveConnectionFailures = 0
                }
                processed += 1
                recentOutcomeWindow.append(outcome == .success)
                onProgress(processed, attempts.count, outcome)
            }

            if allRetryable && hasRetryable && !cancelFlag {
                logger.log("ConcurrentEngine: ALL \(batchResults.count) sessions in batch need retry — rotating IP and retrying batch", category: .network, level: .critical)

                await rotateIPAndWaitForReady(for: proxyTarget)

                var retryEffectiveURLs: [Int: URL] = [:]
                for (_, _, _, originalIndex) in retryableSessions {
                    retryEffectiveURLs[originalIndex] = healthyURLs[originalIndex % healthyURLs.count]
                }

                let retryResults: [(String, LoginOutcome, Int, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
                    for (_, _, _, originalIndex) in retryableSessions {
                        if self.cancelFlag { break }
                        let attempt = attempts[originalIndex]
                        let retryURL = retryEffectiveURLs[originalIndex] ?? healthyURLs[originalIndex % healthyURLs.count]
                        let username = attempt.credential.username

                        group.addTask {
                            guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, originalIndex) }
                            let acquired = await self.throttler.acquire()
                            guard acquired, !Task.isCancelled else {
                                if acquired { await self.throttler.release(succeeded: false) }
                                return (username, LoginOutcome.timeout, 0, originalIndex)
                            }
                            let taskStart = Date()
                            let outcome = await engine.runLoginTest(attempt, targetURL: retryURL, timeout: timeout)
                            let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                            await self.throttler.release(succeeded: outcome == .success)
                            return (username, outcome, latency, originalIndex)
                        }
                    }
                    var results: [(String, LoginOutcome, Int, Int)] = []
                    for await result in group {
                        results.append(result)
                        if self.cancelFlag { group.cancelAll(); break }
                    }
                    return results
                }

                for (_, outcome, _, _) in retryResults {
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    if outcome == .connectionFailure || outcome == .timeout {
                        urlCooldown.recordFailure(for: matchingURL)
                    } else {
                        urlCooldown.recordSuccess(for: matchingURL)
                    }
                }
                for (username, outcome, latency, _) in retryResults {
                    allResults.append((username, outcome))
                    latencies.append(latency)
                    if outcome == .success {
                        successCount += 1
                        consecutiveConnectionFailures = 0
                    } else {
                        failureCount += 1
                        if outcome == .permDisabled {
                            deadAccounts.insert(username)
                            logger.log("ConcurrentEngine: account '\(username)' marked DEAD (permDisabled)", category: .automation, level: .warning)
                        }
                        if outcome == .connectionFailure || outcome == .timeout {
                            consecutiveConnectionFailures += 1
                        } else {
                            consecutiveConnectionFailures = 0
                        }
                    }
                    processed += 1
                    recentOutcomeWindow.append(outcome == .success)
                    onProgress(processed, attempts.count, outcome)
                }
            } else if hasRetryable && !cancelFlag {
                var eligibleForCarryOver: [Int] = []
                for (username, _, _, originalIndex) in retryableSessions {
                    let currentRetries = credentialRetryTracker[username] ?? 0
                    if currentRetries >= maxCredentialRetries {
                        logger.log("ConcurrentEngine: credential '\(username)' exhausted \(maxCredentialRetries) retries — marking as final failure", category: .automation, level: .warning)
                        allResults.append((username, .unsure))
                        failureCount += 1
                        processed += 1
                        recentOutcomeWindow.append(false)
                        onProgress(processed, attempts.count, .unsure)
                    } else {
                        credentialRetryTracker[username] = currentRetries + 1
                        eligibleForCarryOver.append(originalIndex)
                    }
                }
                if !eligibleForCarryOver.isEmpty {
                    logger.log("ConcurrentEngine: \(eligibleForCarryOver.count) sessions inconclusive — carrying over (\(retryableSessions.count - eligibleForCarryOver.count) exhausted retries)", category: .network, level: .warning)
                    carryOverIndices.append(contentsOf: eligibleForCarryOver)
                }
            } else if !hasRetryable {
                for (_, outcome, _, _) in batchResults where !isConclusiveOutcome(outcome) {
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    if outcome == .connectionFailure || outcome == .timeout {
                        urlCooldown.recordFailure(for: matchingURL)
                    } else {
                        urlCooldown.recordSuccess(for: matchingURL)
                    }
                }
            }

            let batchAllFailed = !batchResults.isEmpty && batchResults.allSatisfy({ !isConclusiveOutcome($0.1) })
            if batchAllFailed {
                consecutiveAllFailBatches += 1
                let backoffMs = min(maxAllFailBackoffMs, 2000 * (1 << min(consecutiveAllFailBatches - 1, 4)))
                logger.log("ConcurrentEngine: consecutive all-fail batch #\(consecutiveAllFailBatches) — exponential backoff \(backoffMs)ms before next batch", category: .network, level: .critical)
                try? await Task.sleep(for: .milliseconds(backoffMs))
            } else if batchResults.contains(where: { isConclusiveOutcome($0.1) }) {
                consecutiveAllFailBatches = 0
            }

            if consecutiveConnectionFailures >= nodeMavenAutoRotateThreshold {
                if NodeMavenService.shared.isEnabled {
                    logger.log("ConcurrentEngine: \(consecutiveConnectionFailures) consecutive connection failures — rotating NodeMaven IP", category: .network, level: .warning)
                    let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "autorotate_\(Int(Date().timeIntervalSince1970))")
                } else {
                    logger.log("ConcurrentEngine: \(consecutiveConnectionFailures) consecutive connection failures — forcing IP rotation", category: .network, level: .warning)
                    await rotateIPAndWaitForReady(for: proxyTarget)
                }
                consecutiveConnectionFailures = 0
            }

            if processed % 2 == 0 || processed == attempts.count {
                let stats = computeLiveStats(processed: processed, total: attempts.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
                onBatchStats?(stats)
            }

            let didPause = await checkAutoPause(processed: processed, total: attempts.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
            if didPause && cancelFlag { break }

            let hasRateLimitSignals = batchResults.contains(where: { $0.1 == .redBannerError || $0.1 == .smsDetected })
            if hasRateLimitSignals {
                rateLimitSignalCount += batchResults.filter({ $0.1 == .redBannerError || $0.1 == .smsDetected }).count
            }

            for (_, outcome, latency, _) in batchResults {
                let forecastKey = "login_\(proxyTarget.rawValue)"
                anomalyForecasting.recordLatency(key: forecastKey, latencyMs: latency)
                if outcome == .success {
                    anomalyForecasting.recordSuccess(key: forecastKey)
                } else {
                    let isRL = outcome == .redBannerError || outcome == .smsDetected
                    anomalyForecasting.recordError(key: forecastKey, isRateLimit: isRL)
                }

                let isSuccess = outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled
                liveSpeed.recordLatency(
                    latencyMs: latency,
                    success: isSuccess,
                    wasTimeout: outcome == .timeout,
                    wasConnectionFailure: outcome == .connectionFailure
                )
            }

            if let concurrencyDelta = liveSpeed.currentConcurrencyRecommendation, concurrencyDelta != 0 {
                let currentMax = await throttler.currentStats().maxConcurrency
                let newMax = max(1, min(10, currentMax + concurrencyDelta))
                if newMax != currentMax {
                    await throttler.updateMaxConcurrency(newMax)
                    logger.log("ConcurrentEngine: LiveSpeed concurrency \(currentMax) → \(newMax) (\(liveSpeed.lastAdaptationReason))", category: .automation, level: .info)
                }
            }

            let loginForecast = anomalyForecasting.forecast(key: "login_\(proxyTarget.rawValue)")
            if loginForecast.softBreakRecommended {
                for url in healthyURLs {
                    if let host = url.host {
                        circuitBreaker.applySoftBreak(host: host)
                    }
                }
            }
            if let reduction = loginForecast.concurrencyReduction, reduction > 0 {
                let newMax = max(1, maxConcurrency - reduction)
                await throttler.updateMaxConcurrency(newMax)
                logger.log("ConcurrentEngine: anomaly forecast reducing concurrency to \(newMax)", category: .automation, level: .warning)
            }

            if batchEnd < attempts.count && !cancelFlag {
                let anomalyThrottle = anomalyForecasting.shouldThrottleRequests(key: "login_\(proxyTarget.rawValue)")
                let batchSuccessRate = batchResults.isEmpty ? 0.5 : Double(batchResults.filter { $0.1 == .success }.count) / Double(batchResults.count)
                let rateLimitMultiplier = rateLimitSignalCount > 3 ? 2.5 : (rateLimitSignalCount > 0 ? 1.5 : 1.0)
                let baseCooldown: Int
                if anomalyThrottle.shouldThrottle {
                    baseCooldown = anomalyThrottle.delayMs
                } else if batchSuccessRate > 0.8 {
                    baseCooldown = Int(Double(Int.random(in: 250...600)) * rateLimitMultiplier)
                } else if batchSuccessRate < 0.3 {
                    baseCooldown = Int(Double(Int.random(in: 1500...3000)) * rateLimitMultiplier)
                    logger.log("ConcurrentEngine: low login success rate (\(Int(batchSuccessRate * 100))%) — extended cooldown \(baseCooldown)ms (rateLimitSignals=\(rateLimitSignalCount))", category: .automation, level: .warning)
                } else {
                    baseCooldown = Int(Double(Int.random(in: 500...1200)) * rateLimitMultiplier)
                }
                let adaptedCooldown = liveSpeed.adaptDelay(baseCooldown)
                if adaptedCooldown != baseCooldown {
                    logger.log("ConcurrentEngine: LiveSpeed adapted cooldown \(baseCooldown)ms → \(adaptedCooldown)ms (\(String(format: "%.2f", liveSpeed.currentSpeedMultiplier))x)", category: .timing, level: .debug)
                }
                try? await Task.sleep(for: .milliseconds(adaptedCooldown))
            }
        }

        let dedupedCarryOver = Array(Set(carryOverIndices))
        let prioritizedCarryOver = dedupedCarryOver.sorted { a, b in
            let retriesA = credentialRetryTracker[attempts[a].credential.username] ?? 0
            let retriesB = credentialRetryTracker[attempts[b].credential.username] ?? 0
            return retriesA < retriesB
        }
        if !prioritizedCarryOver.isEmpty && !cancelFlag {
            let eligibleCarryOver = prioritizedCarryOver.filter { index in
                let username = attempts[index].credential.username
                let retries = credentialRetryTracker[username] ?? 0
                if retries >= maxCredentialRetries {
                    logger.log("ConcurrentEngine: carry-over credential '\(username)' exhausted retries — skipping", category: .automation, level: .warning)
                    allResults.append((username, .unsure))
                    failureCount += 1
                    processed += 1
                    recentOutcomeWindow.append(false)
                    onProgress(processed, attempts.count, .unsure)
                    return false
                }
                return !deadAccounts.contains(username)
            }

            if !eligibleCarryOver.isEmpty {
            logger.log("ConcurrentEngine: processing \(eligibleCarryOver.count) prioritized carry-over sessions (\(prioritizedCarryOver.count - eligibleCarryOver.count) exhausted/dead)", category: .automation, level: .info)

            await rotateIPAndWaitForReady(for: proxyTarget)

            let carryOverResults: [(String, LoginOutcome, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int).self) { group in
                for index in eligibleCarryOver {
                    if self.cancelFlag { break }
                    let attempt = attempts[index]
                    let retryURL = healthyURLs[index % healthyURLs.count]
                    let username = attempt.credential.username
                    if self.deadAccounts.contains(username) { continue }

                    group.addTask {
                        guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0) }
                        let acquired = await self.throttler.acquire()
                        guard acquired, !Task.isCancelled else {
                            if acquired { await self.throttler.release(succeeded: false) }
                            return (username, LoginOutcome.timeout, 0)
                        }
                        let taskStart = Date()
                        let outcome = await engine.runLoginTest(attempt, targetURL: retryURL, timeout: timeout)
                        let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                        await self.throttler.release(succeeded: outcome == .success)
                        return (username, outcome, latency)
                    }
                }
                var results: [(String, LoginOutcome, Int)] = []
                for await result in group {
                    results.append(result)
                    if self.cancelFlag { group.cancelAll(); break }
                }
                return results
            }

            for (username, outcome, latency) in carryOverResults {
                allResults.append((username, outcome))
                latencies.append(latency)
                if outcome == .success { successCount += 1 } else { failureCount += 1 }
                if outcome == .permDisabled {
                    deadAccounts.insert(username)
                }
                processed += 1
                recentOutcomeWindow.append(outcome == .success)
                onProgress(processed, attempts.count, outcome)
            }
            }
        }

        let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count

        AppStabilityCoordinator.shared.cancelTaskGroupWatchdog(id: batchId)
        logger.endSession(batchId, category: .login, message: "ConcurrentEngine: login batch complete — \(successCount) success, \(failureCount) fail, avgLatency=\(avgLatency)ms | network=\(networkSummary)")

        isRunning = false
        return ConcurrentBatchResult(
            results: allResults,
            totalTimeMs: totalMs,
            successCount: successCount,
            failureCount: failureCount,
            avgLatencyMs: avgLatency
        )
    }

    func resetThrottler() async {
        await throttler.reset()
    }

    func getThrottlerStats() async -> (active: Int, maxConcurrency: Int, backoffMs: Int, consecutiveFailures: Int) {
        await throttler.currentStats()
    }

    private func rotateIP(for target: ProxyRotationService.ProxyTarget) {
        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.isEnabled {
            deviceProxy.rotateNow(reason: "Batch connection failure — IP rotation")
            logger.log("ConcurrentEngine: rotated united IP (DeviceProxy) for \(target.rawValue)", category: .network, level: .warning)
            return
        }

        if NodeMavenService.shared.isEnabled {
            let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "batch_rotate_\(Int(Date().timeIntervalSince1970))")
            logger.log("ConcurrentEngine: rotated NodeMaven session IP for \(target.rawValue)", category: .network, level: .warning)
            return
        }

        let proxyService = ProxyRotationService.shared
        let mode = proxyService.connectionMode(for: target)
        switch mode {
        case .wireguard:
            let _ = proxyService.nextReachableWGConfig(for: target)
            logger.log("ConcurrentEngine: rotated to next WireGuard IP for \(target.rawValue)", category: .network, level: .warning)
        case .openvpn:
            let _ = proxyService.nextReachableOVPNConfig(for: target)
            logger.log("ConcurrentEngine: rotated to next OpenVPN IP for \(target.rawValue)", category: .network, level: .warning)
        case .proxy:
            let _ = proxyService.nextWorkingProxy(for: target)
            logger.log("ConcurrentEngine: rotated to next SOCKS5 IP for \(target.rawValue)", category: .network, level: .warning)
        case .dns, .nodeMaven:
            logger.log("ConcurrentEngine: no IP pool to rotate for mode \(mode.label) on \(target.rawValue)", category: .network, level: .warning)
        case .hybrid:
            HybridNetworkingService.shared.resetBatch()
            logger.log("ConcurrentEngine: hybrid mode — reset and re-assigned for \(target.rawValue)", category: .network, level: .warning)
        }
    }

    private func rotateIPAndWaitForReady(for target: ProxyRotationService.ProxyTarget) async {
        rotateIP(for: target)

        let maxProbeAttempts = 10
        let probeIntervalMs = 500
        let fallbackWaitMs = 3000

        for attempt in 1...maxProbeAttempts {
            let probeOK = await quickIPProbe()
            if probeOK {
                logger.log("ConcurrentEngine: post-rotation probe succeeded on attempt \(attempt) (\(attempt * probeIntervalMs)ms)", category: .network, level: .success)
                return
            }
            try? await Task.sleep(for: .milliseconds(probeIntervalMs))
        }

        logger.log("ConcurrentEngine: post-rotation probe failed after \(maxProbeAttempts) attempts — falling back to \(fallbackWaitMs)ms wait", category: .network, level: .warning)
        try? await Task.sleep(for: .milliseconds(fallbackWaitMs))
    }

    private nonisolated func quickIPProbe() async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.ipify.org?format=json") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    private func isConclusiveOutcome(_ outcome: LoginOutcome) -> Bool {
        switch outcome {
        case .success, .tempDisabled, .permDisabled, .noAcc:
            return true
        case .connectionFailure, .timeout, .unsure, .redBannerError, .smsDetected:
            return false
        }
    }

    private func performWireProxyHealthGate(for target: ProxyRotationService.ProxyTarget) async -> Bool {
        let proxyService = ProxyRotationService.shared
        let mode = proxyService.connectionMode(for: target)
        guard mode == .wireguard else { return true }

        let wireProxyBridge = WireProxyBridge.shared
        let localProxy = LocalProxyServer.shared

        guard wireProxyBridge.isActive || localProxy.wireProxyMode else {
            logger.log("ConcurrentEngine: WireGuard mode but WireProxy not active — skipping health gate", category: .network, level: .info)
            return true
        }

        if wireProxyBridge.isActive {
            let probeOK = await quickIPProbe()
            if probeOK {
                logger.log("ConcurrentEngine: WireProxy health gate PASSED", category: .network, level: .success)
                return true
            }

            logger.log("ConcurrentEngine: WireProxy health gate FAILED — attempting tunnel restart", category: .network, level: .warning)

            let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
            if let firstConfig = configs.first {
                wireProxyBridge.stop()
                try? await Task.sleep(for: .seconds(1))
                await wireProxyBridge.start(with: firstConfig)
                try? await Task.sleep(for: .seconds(2))

                if wireProxyBridge.isActive {
                    let retryProbe = await quickIPProbe()
                    if retryProbe {
                        logger.log("ConcurrentEngine: WireProxy health gate PASSED after restart", category: .network, level: .success)
                        return true
                    }
                }
            }

            logger.log("ConcurrentEngine: WireProxy health gate FAILED after restart attempt — proceeding with caution", category: .network, level: .critical)
            return false
        }

        return true
    }

    private func performProxyPreCheck(batchId: String) async -> Bool {
        logger.log("ConcurrentEngine: running proxy pre-check...", category: .network, level: .info)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 8
        sessionConfig.timeoutIntervalForResource = 10

        let deviceProxy = DeviceProxyService.shared
        if deviceProxy.isEnabled, let netConfig = deviceProxy.activeConfig {
            if case .socks5(let proxy) = netConfig {
                var proxyDict: [String: Any] = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": proxy.port,
                ]
                if let u = proxy.username { proxyDict["SOCKSUser"] = u }
                if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
                sessionConfig.connectionProxyDictionary = proxyDict
            }
        }

        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.ipify.org?format=json") else { return true }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ip = json["ip"] as? String {
                    logger.log("ConcurrentEngine: proxy pre-check PASSED — IP: \(ip)", category: .network, level: .success)
                }
                return true
            }
            logger.log("ConcurrentEngine: proxy pre-check got HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)", category: .network, level: .warning)
            return false
        } catch {
            logger.log("ConcurrentEngine: proxy pre-check FAILED — \(error.localizedDescription)", category: .network, level: .error)
            return false
        }
    }
}
