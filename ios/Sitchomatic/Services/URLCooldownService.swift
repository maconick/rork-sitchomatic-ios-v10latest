import Foundation

@MainActor
class URLCooldownService {
    static let shared = URLCooldownService()

    private var cooldowns: [String: CooldownEntry] = [:]
    private let logger = DebugLogger.shared

    var defaultCooldownSeconds: TimeInterval = 60
    var maxConsecutiveFailuresBeforeCooldown: Int = 2

    private struct CooldownEntry {
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date?
        var lastFailure: Date?
    }

    func recordFailure(for url: String) {
        let host = extractHost(from: url)
        var entry = cooldowns[host] ?? CooldownEntry()
        entry.consecutiveFailures += 1
        entry.lastFailure = Date()

        if entry.consecutiveFailures >= maxConsecutiveFailuresBeforeCooldown {
            entry.cooldownUntil = Date().addingTimeInterval(defaultCooldownSeconds)
            logger.log("URLCooldown: \(host) placed on \(Int(defaultCooldownSeconds))s cooldown after \(entry.consecutiveFailures) consecutive failures", category: .network, level: .warning)
        }

        cooldowns[host] = entry
    }

    func recordSuccess(for url: String) {
        let host = extractHost(from: url)
        cooldowns[host] = nil
    }

    func isOnCooldown(_ url: String) -> Bool {
        let host = extractHost(from: url)
        guard let entry = cooldowns[host], let until = entry.cooldownUntil else { return false }
        if Date() >= until {
            cooldowns[host]?.cooldownUntil = nil
            cooldowns[host]?.consecutiveFailures = 0
            return false
        }
        return true
    }

    func cooldownRemaining(_ url: String) -> TimeInterval {
        let host = extractHost(from: url)
        guard let entry = cooldowns[host], let until = entry.cooldownUntil else { return 0 }
        return max(0, until.timeIntervalSince(Date()))
    }

    func clearAll() {
        cooldowns.removeAll()
        logger.log("URLCooldown: all cooldowns cleared", category: .network, level: .info)
    }

    func activeCooldowns() -> [(host: String, remainingSeconds: Int, failures: Int)] {
        var result: [(host: String, remainingSeconds: Int, failures: Int)] = []
        for (host, entry) in cooldowns {
            guard let until = entry.cooldownUntil, Date() < until else { continue }
            let remaining = Int(until.timeIntervalSince(Date()))
            result.append((host, remaining, entry.consecutiveFailures))
        }
        return result.sorted { $0.remainingSeconds > $1.remainingSeconds }
    }

    private func extractHost(from url: String) -> String {
        if let u = URL(string: url) { return u.host ?? url }
        return url
    }
}
