import Foundation
import UIKit

actor AutomationThrottler {
    private var activeCount: Int = 0
    private var maxConcurrency: Int
    private var backoffMs: Int = 0
    private var consecutiveFailures: Int = 0

    init(maxConcurrency: Int = 5) {
        self.maxConcurrency = maxConcurrency
    }

    func acquire() async {
        while activeCount >= maxConcurrency {
            try? await Task.sleep(for: .milliseconds(100))
        }
        activeCount += 1
        if backoffMs > 0 {
            try? await Task.sleep(for: .milliseconds(backoffMs))
        }
    }

    func release(succeeded: Bool) {
        activeCount -= 1
        if succeeded {
            consecutiveFailures = 0
            backoffMs = max(0, backoffMs - 200)
        } else {
            consecutiveFailures += 1
            backoffMs = min(10000, 500 * (1 << min(consecutiveFailures, 5)))
        }
    }

    func updateMaxConcurrency(_ newMax: Int) {
        maxConcurrency = max(1, min(10, newMax))
    }

    func currentStats() -> (active: Int, maxConcurrency: Int, backoffMs: Int, consecutiveFailures: Int) {
        (activeCount, maxConcurrency, backoffMs, consecutiveFailures)
    }

    func reset() {
        activeCount = 0
        backoffMs = 0
        consecutiveFailures = 0
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
    private let urlQualityScoring = URLQualityScoringService.shared
    private let proxyQualityDecay = ProxyQualityDecayService.shared
    private let preflightService = PreflightSmokeTestService.shared
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
        let failureRate = recentOutcomeWindow.count >= autoPauseWindowSize
            ? Double(recentOutcomeWindow.suffix(autoPauseWindowSize).filter { !$0 }.count) / Double(autoPauseWindowSize)
            : 0
        if failureRate >= autoPauseFailureThreshold && recentOutcomeWindow.count >= autoPauseWindowSize {
            autoPaused = true
            logger.log("ConcurrentEngine: AUTO-PAUSED — \(Int(failureRate * 100))% failure rate over last \(autoPauseWindowSize) attempts. Waiting \(autoPauseDurationSeconds)s...", category: .automation, level: .critical)
            let stats = computeLiveStats(processed: processed, total: total, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
            onBatchStats?(stats)
            try? await Task.sleep(for: .seconds(autoPauseDurationSeconds))
            recentOutcomeWindow.removeAll()
            autoPaused = false
            logger.log("ConcurrentEngine: resuming after auto-pause", category: .automation, level: .info)
            return true
        }
        return false
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

        await throttler.updateMaxConcurrency(maxConcurrency)
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
                        await self.throttler.acquire()
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

            if processed % 5 == 0 || processed == checks.count {
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

            if coordinator.adaptiveConcurrency && processed > 3 {
                let recentOutcomes = batchResults.map { (cardId: $0.0, outcome: $0.1, latencyMs: $0.2) }
                let analytics = coordinator.computeBatchAnalytics(outcomes: recentOutcomes)
                if analytics.suggestedConcurrency != maxConcurrency {
                    await throttler.updateMaxConcurrency(analytics.suggestedConcurrency)
                    logger.log("ConcurrentEngine: adaptive concurrency → \(analytics.suggestedConcurrency)", category: .automation, level: .info)
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

        logger.endSession(batchId, category: .ppsr, message: "ConcurrentEngine: batch complete — \(successCount) pass, \(failureCount) fail, avgLatency=\(avgLatency)ms, total=\(totalMs)ms")

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
        isRunning = true
        cancelFlag = false
        deadAccounts.removeAll()
        recentOutcomeWindow.removeAll()
        let startTime = Date()
        let batchId = "concurrent_login_\(UUID().uuidString.prefix(8))"

        await throttler.updateMaxConcurrency(maxConcurrency)

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

        if let firstURL = urls.first {
            let smokeResult = await preflightService.runPreflightTest(
                targetURL: firstURL,
                networkConfig: netConfig,
                proxyTarget: proxyTarget,
                stealthEnabled: engine.stealthEnabled,
                timeout: 15
            )
            if !smokeResult.passed {
                logger.log("ConcurrentEngine: PREFLIGHT SMOKE TEST FAILED — \(smokeResult.detail)", category: .automation, level: .critical)
                if !smokeResult.proxyWorking {
                    logger.log("ConcurrentEngine: network route broken — consider rotating proxy/URL before batch", category: .network, level: .critical)
                }
            } else {
                logger.log("ConcurrentEngine: preflight passed in \(smokeResult.latencyMs)ms", category: .automation, level: .success)
            }
        }

        var allResults: [(String, LoginOutcome)] = []
        var successCount = 0
        var failureCount = 0
        var latencies: [Int] = []
        var processed = 0
        var carryOverIndices: [Int] = []

        let batchSize = maxConcurrency
        for batchStart in stride(from: 0, to: attempts.count, by: batchSize) {
            if cancelFlag { break }

            let batchEnd = min(batchStart + batchSize, attempts.count)
            let batchIndices = Array(batchStart..<batchEnd)

            var effectiveURLs: [Int: URL] = [:]
            for index in batchIndices {
                let url = urls[index % urls.count]
                let urlHost = url.host ?? ""
                if urlCooldown.isAutoDisabled(url.absoluteString) {
                    logger.log("ConcurrentEngine: URL \(urlHost) is AUTO-DISABLED — skipping", category: .network, level: .warning)
                    let alternate = urls.first { !self.urlCooldown.isAutoDisabled($0.absoluteString) && !self.urlCooldown.isOnCooldown($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else if urlCooldown.isOnCooldown(url.absoluteString) {
                    let remaining = Int(urlCooldown.cooldownRemaining(url.absoluteString))
                    logger.log("ConcurrentEngine: URL \(urlHost) on cooldown (\(remaining)s left) — rotating", category: .network, level: .warning)
                    let alternate = urls.first { !self.urlCooldown.isOnCooldown($0.absoluteString) && !self.urlCooldown.isAutoDisabled($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else if !circuitBreaker.shouldAllow(host: urlHost) {
                    let remaining = Int(circuitBreaker.cooldownRemaining(host: urlHost))
                    logger.log("ConcurrentEngine: URL \(urlHost) circuit OPEN (\(remaining)s left) — rotating", category: .network, level: .warning)
                    let alternate = urls.first { self.circuitBreaker.shouldAllow(host: $0.host ?? "") && !self.urlCooldown.isOnCooldown($0.absoluteString) && $0 != url }
                    effectiveURLs[index] = alternate ?? url
                } else {
                    effectiveURLs[index] = url
                }
            }

            let batchResults: [(String, LoginOutcome, Int, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
                for index in batchIndices {
                    if self.cancelFlag { break }
                    let attempt = attempts[index]
                    let effectiveURL = effectiveURLs[index] ?? urls[index % urls.count]
                    let username = attempt.credential.username

                    if self.deadAccounts.contains(username) {
                        self.logger.log("ConcurrentEngine: skipping dead account \(username)", category: .automation, level: .info)
                        continue
                    }

                    group.addTask {
                        guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, index) }
                        await self.throttler.acquire()
                        guard !Task.isCancelled else {
                            await self.throttler.release(succeeded: false)
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

            let connectionFailedSessions = batchResults.filter { $0.1 == .connectionFailure || $0.1 == .timeout }
            let succeededSessions = batchResults.filter { $0.1 != .connectionFailure && $0.1 != .timeout }
            let allFailed = !batchResults.isEmpty && connectionFailedSessions.count == batchResults.count
            let someFailed = !connectionFailedSessions.isEmpty && !succeededSessions.isEmpty

            if allFailed && !cancelFlag {
                logger.log("ConcurrentEngine: ALL \(batchResults.count) sessions in batch hit connection failure — rotating IP and retrying batch", category: .network, level: .critical)

                rotateIP(for: proxyTarget)
                try? await Task.sleep(for: .milliseconds(2000))

                var retryEffectiveURLs: [Int: URL] = [:]
                for (_, _, _, originalIndex) in connectionFailedSessions {
                    retryEffectiveURLs[originalIndex] = urls[originalIndex % urls.count]
                }

                let retryResults: [(String, LoginOutcome, Int, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int, Int).self) { group in
                    for (_, _, _, originalIndex) in connectionFailedSessions {
                        if self.cancelFlag { break }
                        let attempt = attempts[originalIndex]
                        let retryURL = retryEffectiveURLs[originalIndex] ?? urls[originalIndex % urls.count]
                        let username = attempt.credential.username

                        group.addTask {
                            guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0, originalIndex) }
                            await self.throttler.acquire()
                            guard !Task.isCancelled else {
                                await self.throttler.release(succeeded: false)
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

                let finalBatchResults = retryResults
                for (_, outcome, _, _) in finalBatchResults {
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    if outcome == .connectionFailure || outcome == .timeout {
                        urlCooldown.recordFailure(for: matchingURL)
                    } else {
                        urlCooldown.recordSuccess(for: matchingURL)
                    }
                }
                for (username, outcome, latency, _) in finalBatchResults {
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
            } else if someFailed && !cancelFlag {
                for (_, outcome, _, _) in succeededSessions {
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    urlCooldown.recordSuccess(for: matchingURL)
                }
                for (username, outcome, latency, _) in succeededSessions {
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
                        consecutiveConnectionFailures = 0
                    }
                    processed += 1
                    recentOutcomeWindow.append(outcome == .success)
                    onProgress(processed, attempts.count, outcome)
                }

                let failedIndices = connectionFailedSessions.map { $0.3 }
                logger.log("ConcurrentEngine: \(connectionFailedSessions.count) sessions failed connection — carrying over to next batch (indices: \(failedIndices))", category: .network, level: .warning)
                carryOverIndices.append(contentsOf: failedIndices)
            } else {
                for (_, outcome, _, _) in batchResults {
                    let matchingURL = effectiveURLs[batchIndices.first ?? 0]?.absoluteString ?? ""
                    if outcome == .connectionFailure || outcome == .timeout {
                        urlCooldown.recordFailure(for: matchingURL)
                    } else {
                        urlCooldown.recordSuccess(for: matchingURL)
                    }
                }
                for (username, outcome, latency, _) in batchResults {
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
            }

            if consecutiveConnectionFailures >= nodeMavenAutoRotateThreshold {
                if NodeMavenService.shared.isEnabled {
                    logger.log("ConcurrentEngine: \(consecutiveConnectionFailures) consecutive connection failures — rotating NodeMaven IP", category: .network, level: .warning)
                    let _ = NodeMavenService.shared.generateProxyConfig(sessionId: "autorotate_\(Int(Date().timeIntervalSince1970))")
                } else {
                    logger.log("ConcurrentEngine: \(consecutiveConnectionFailures) consecutive connection failures — forcing IP rotation", category: .network, level: .warning)
                    rotateIP(for: proxyTarget)
                    try? await Task.sleep(for: .milliseconds(2000))
                }
                consecutiveConnectionFailures = 0
            }

            if processed % 5 == 0 || processed == attempts.count {
                let stats = computeLiveStats(processed: processed, total: attempts.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
                onBatchStats?(stats)
            }

            let didPause = await checkAutoPause(processed: processed, total: attempts.count, successCount: successCount, failureCount: failureCount, latencies: latencies, startTime: startTime)
            if didPause && cancelFlag { break }

            if batchEnd < attempts.count && !cancelFlag {
                let batchSuccessRate = batchResults.isEmpty ? 0.5 : Double(batchResults.filter { $0.1 == .success }.count) / Double(batchResults.count)
                let cooldown: Int
                if batchSuccessRate > 0.8 {
                    cooldown = Int.random(in: 250...600)
                } else if batchSuccessRate < 0.3 {
                    cooldown = Int.random(in: 1500...3000)
                    logger.log("ConcurrentEngine: low login success rate (\(Int(batchSuccessRate * 100))%) — extended cooldown \(cooldown)ms", category: .automation, level: .warning)
                } else {
                    cooldown = Int.random(in: 500...1200)
                }
                try? await Task.sleep(for: .milliseconds(cooldown))
            }
        }

        if !carryOverIndices.isEmpty && !cancelFlag {
            logger.log("ConcurrentEngine: processing \(carryOverIndices.count) carried-over sessions from previous batches", category: .automation, level: .info)

            rotateIP(for: proxyTarget)
            try? await Task.sleep(for: .milliseconds(2000))

            let carryOverResults: [(String, LoginOutcome, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int).self) { group in
                for index in carryOverIndices {
                    if self.cancelFlag { break }
                    let attempt = attempts[index]
                    let retryURL = urls[index % urls.count]
                    let username = attempt.credential.username
                    if self.deadAccounts.contains(username) { continue }

                    group.addTask {
                        guard !Task.isCancelled else { return (username, LoginOutcome.timeout, 0) }
                        await self.throttler.acquire()
                        guard !Task.isCancelled else {
                            await self.throttler.release(succeeded: false)
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

        let totalMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let avgLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / latencies.count

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
        }
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
