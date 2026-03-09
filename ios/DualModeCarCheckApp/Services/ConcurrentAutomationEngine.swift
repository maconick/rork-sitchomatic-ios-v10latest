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

@MainActor
class ConcurrentAutomationEngine {
    static let shared = ConcurrentAutomationEngine()

    private let logger = DebugLogger.shared
    private let coordinator = AIAutomationCoordinator.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let throttler = AutomationThrottler(maxConcurrency: 5)
    private(set) var isRunning: Bool = false
    private var cancelFlag: Bool = false

    func cancel() {
        cancelFlag = true
    }

    func runConcurrentPPSRBatch(
        checks: [PPSRCheck],
        engine: PPSRAutomationEngine,
        maxConcurrency: Int = 5,
        timeout: TimeInterval = 30,
        onProgress: @escaping (Int, Int, CheckOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, CheckOutcome)> {
        isRunning = true
        cancelFlag = false
        let startTime = Date()
        let batchId = "concurrent_ppsr_\(UUID().uuidString.prefix(8))"

        await throttler.updateMaxConcurrency(maxConcurrency)
        logger.startSession(batchId, category: .ppsr, message: "ConcurrentEngine: starting \(checks.count) PPSR checks, maxConcurrency=\(maxConcurrency)")

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
                    let cardId = check.card.id
                    group.addTask {
                        await self.throttler.acquire()
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
                }
                processed += 1
                onProgress(processed, checks.count, outcome)
            }

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
                let cooldown = Int.random(in: 300...800)
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
        timeout: TimeInterval = 45,
        proxyTarget: ProxyRotationService.ProxyTarget = .joe,
        onProgress: @escaping (Int, Int, LoginOutcome) -> Void
    ) async -> ConcurrentBatchResult<(String, LoginOutcome)> {
        isRunning = true
        cancelFlag = false
        let startTime = Date()
        let batchId = "concurrent_login_\(UUID().uuidString.prefix(8))"

        await throttler.updateMaxConcurrency(maxConcurrency)

        let proxyService = ProxyRotationService.shared
        let networkMode = proxyService.connectionMode(for: proxyTarget)
        let networkSummary = proxyService.networkSummary(for: proxyTarget)
        engine.proxyTarget = proxyTarget

        logger.startSession(batchId, category: .login, message: "ConcurrentEngine: starting \(attempts.count) login tests across \(urls.count) URLs | network=\(networkSummary) mode=\(networkMode.label) target=\(proxyTarget.rawValue)")

        var allResults: [(String, LoginOutcome)] = []
        var successCount = 0
        var failureCount = 0
        var latencies: [Int] = []
        var processed = 0

        let batchSize = maxConcurrency
        for batchStart in stride(from: 0, to: attempts.count, by: batchSize) {
            if cancelFlag { break }

            let batchEnd = min(batchStart + batchSize, attempts.count)
            let batchIndices = Array(batchStart..<batchEnd)

            let batchResults: [(String, LoginOutcome, Int)] = await withTaskGroup(of: (String, LoginOutcome, Int).self) { group in
                for index in batchIndices {
                    let attempt = attempts[index]
                    let url = urls[index % urls.count]
                    let username = attempt.credential.username

                    group.addTask {
                        await self.throttler.acquire()
                        let taskStart = Date()

                        var outcome = await engine.runLoginTest(attempt, targetURL: url, timeout: timeout)
                        var retries = 0
                        let maxRetries = 2

                        while (outcome == .connectionFailure || outcome == .timeout) && retries < maxRetries {
                            retries += 1
                            let backoff = 1000 * (1 << (retries - 1))
                            try? await Task.sleep(for: .milliseconds(backoff))
                            let nextURL = urls[(index + retries) % urls.count]
                            outcome = await engine.runLoginTest(attempt, targetURL: nextURL, timeout: timeout)
                        }

                        let latency = Int(Date().timeIntervalSince(taskStart) * 1000)
                        let succeeded = outcome == .success
                        await self.throttler.release(succeeded: succeeded)
                        return (username, outcome, latency)
                    }
                }

                var results: [(String, LoginOutcome, Int)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            for (username, outcome, latency) in batchResults {
                allResults.append((username, outcome))
                latencies.append(latency)
                if outcome == .success {
                    successCount += 1
                } else {
                    failureCount += 1
                }
                processed += 1
                onProgress(processed, attempts.count, outcome)
            }

            if batchEnd < attempts.count && !cancelFlag {
                let cooldown = Int.random(in: 500...1200)
                try? await Task.sleep(for: .milliseconds(cooldown))
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
}
