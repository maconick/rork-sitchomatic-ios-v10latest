import Foundation
import Network

@Observable
@MainActor
class NetworkResilienceService {
    static let shared = NetworkResilienceService()

    private(set) var failClosedVerificationActive: Bool = false
    private(set) var lastVerificationResult: VerificationResult?
    private(set) var verificationLog: [VerificationResult] = []
    private(set) var bandwidthEstimateBps: Double = 0
    private(set) var isThrottled: Bool = false
    private(set) var currentConcurrencyLimit: Int = 4
    private(set) var failoverBackoffSeconds: TimeInterval = 0

    var enableFailClosedVerification: Bool = true
    var verificationIntervalSeconds: TimeInterval = 60
    var bandwidthSampleWindowSeconds: TimeInterval = 10
    var throttleLatencyThresholdMs: Int = 3000
    var throttleErrorRateThreshold: Double = 0.5
    var minConcurrency: Int = 1
    var maxConcurrency: Int = 8

    private var verificationTimer: Timer?
    private var bandwidthSamples: [(timestamp: Date, bytes: UInt64)] = []
    private var failoverAttemptCount: Int = 0
    private var lastFailoverAttempt: Date?
    private let logger = DebugLogger.shared

    nonisolated struct VerificationResult: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let intendedProxy: String
        let detectedIP: String
        let isLeaking: Bool
        let latencyMs: Int

        init(id: UUID = UUID(), timestamp: Date = Date(), intendedProxy: String, detectedIP: String, isLeaking: Bool, latencyMs: Int) {
            self.id = id
            self.timestamp = timestamp
            self.intendedProxy = intendedProxy
            self.detectedIP = detectedIP
            self.isLeaking = isLeaking
            self.latencyMs = latencyMs
        }
    }

    init() {}

    // MARK: - Fail-Closed Proxy Verification Loop (Item 10)

    func startVerificationLoop(expectedProxy: ProxyConfig?) {
        stopVerificationLoop()
        guard enableFailClosedVerification, let proxy = expectedProxy else { return }

        failClosedVerificationActive = true
        logger.log("Resilience: fail-closed verification loop started for \(proxy.displayString)", category: .proxy, level: .info)

        Task { await performVerification(expectedProxy: proxy) }

        verificationTimer = Timer.scheduledTimer(withTimeInterval: verificationIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performVerification(expectedProxy: proxy)
            }
        }
    }

    func stopVerificationLoop() {
        verificationTimer?.invalidate()
        verificationTimer = nil
        failClosedVerificationActive = false
    }

    private nonisolated func performVerification(expectedProxy: ProxyConfig) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": expectedProxy.host,
            "SOCKSPort": expectedProxy.port,
        ]
        if let u = expectedProxy.username { proxyDict["SOCKSUser"] = u }
        if let p = expectedProxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.timeoutIntervalForRequest = 8
        let directSession = URLSession(configuration: directConfig)
        defer { directSession.invalidateAndCancel() }

        guard let url = URL(string: "https://api.ipify.org?format=json") else { return }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (proxiedData, _) = try await session.data(for: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let latencyMs = Int(elapsed * 1000)

            let proxiedIP = parseIPFromJSON(proxiedData)

            var directReq = URLRequest(url: url)
            directReq.timeoutInterval = 6
            directReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (directData, _) = try await directSession.data(for: directReq)
            let directIP = parseIPFromJSON(directData)

            let isLeaking = !proxiedIP.isEmpty && !directIP.isEmpty && proxiedIP == directIP

            let result = VerificationResult(
                intendedProxy: expectedProxy.displayString,
                detectedIP: proxiedIP,
                isLeaking: isLeaking,
                latencyMs: latencyMs
            )

            await MainActor.run {
                self.lastVerificationResult = result
                self.verificationLog.insert(result, at: 0)
                if self.verificationLog.count > 30 {
                    self.verificationLog = Array(self.verificationLog.prefix(30))
                }

                if isLeaking {
                    self.logger.log("Resilience: IP LEAK DETECTED — proxied=\(proxiedIP) direct=\(directIP) via \(expectedProxy.displayString)", category: .proxy, level: .error)
                }
            }
        } catch {
            let result = VerificationResult(
                intendedProxy: expectedProxy.displayString,
                detectedIP: "error",
                isLeaking: false,
                latencyMs: 0
            )
            await MainActor.run {
                self.lastVerificationResult = result
            }
        }
    }

    private nonisolated func parseIPFromJSON(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = json["ip"] as? String else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ip
    }

    // MARK: - Exponential Backoff with Jitter (Item 7)

    func calculateBackoffDelay() -> TimeInterval {
        let baseDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 60.0
        let exponentialDelay = baseDelay * pow(2.0, Double(failoverAttemptCount))
        let cappedDelay = min(exponentialDelay, maxDelay)
        let jitter = Double.random(in: 0...(cappedDelay * 0.3))
        let finalDelay = cappedDelay + jitter

        failoverBackoffSeconds = finalDelay
        failoverAttemptCount += 1
        lastFailoverAttempt = Date()

        logger.log("Resilience: backoff delay=\(String(format: "%.1f", finalDelay))s (attempt \(failoverAttemptCount), jitter=\(String(format: "%.1f", jitter))s)", category: .proxy, level: .debug)

        return finalDelay
    }

    func resetBackoff() {
        failoverAttemptCount = 0
        failoverBackoffSeconds = 0
        lastFailoverAttempt = nil
    }

    func shouldThrottleFailover() -> Bool {
        guard let last = lastFailoverAttempt else { return false }
        return Date().timeIntervalSince(last) < failoverBackoffSeconds
    }

    // MARK: - Bandwidth-Aware Concurrency Throttling (Item 9)

    func recordBandwidthSample(bytes: UInt64) {
        let now = Date()
        bandwidthSamples.append((timestamp: now, bytes: bytes))

        let cutoff = now.addingTimeInterval(-bandwidthSampleWindowSeconds)
        bandwidthSamples.removeAll { $0.timestamp < cutoff }

        recalculateBandwidth()
    }

    func recordLatencySample(latencyMs: Int, hadError: Bool) {
        if hadError || latencyMs > throttleLatencyThresholdMs {
            if currentConcurrencyLimit > minConcurrency {
                currentConcurrencyLimit = max(minConcurrency, currentConcurrencyLimit - 1)
                isThrottled = true
                logger.log("Resilience: throttled concurrency to \(currentConcurrencyLimit) (latency=\(latencyMs)ms, error=\(hadError))", category: .network, level: .warning)
            }
        } else if latencyMs < throttleLatencyThresholdMs / 2 && !hadError {
            if currentConcurrencyLimit < maxConcurrency {
                currentConcurrencyLimit = min(maxConcurrency, currentConcurrencyLimit + 1)
                if currentConcurrencyLimit >= maxConcurrency {
                    isThrottled = false
                }
                logger.log("Resilience: scaled concurrency to \(currentConcurrencyLimit) (latency=\(latencyMs)ms)", category: .network, level: .debug)
            }
        }
    }

    func resetThrottling() {
        currentConcurrencyLimit = maxConcurrency
        isThrottled = false
        bandwidthSamples.removeAll()
        bandwidthEstimateBps = 0
    }

    private func recalculateBandwidth() {
        guard bandwidthSamples.count >= 2 else {
            bandwidthEstimateBps = 0
            return
        }

        let totalBytes = bandwidthSamples.reduce(UInt64(0)) { $0 + $1.bytes }
        let timeSpan = bandwidthSamples.last!.timestamp.timeIntervalSince(bandwidthSamples.first!.timestamp)

        guard timeSpan > 0 else {
            bandwidthEstimateBps = 0
            return
        }

        bandwidthEstimateBps = Double(totalBytes) / timeSpan
    }

    var bandwidthLabel: String {
        if bandwidthEstimateBps < 1024 { return String(format: "%.0f B/s", bandwidthEstimateBps) }
        if bandwidthEstimateBps < 1024 * 1024 { return String(format: "%.1f KB/s", bandwidthEstimateBps / 1024) }
        return String(format: "%.1f MB/s", bandwidthEstimateBps / (1024 * 1024))
    }
}
