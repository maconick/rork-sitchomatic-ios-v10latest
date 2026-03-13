import Foundation

nonisolated enum RequeuePriority: Int, Comparable, Sendable {
    case high = 0
    case medium = 1
    case low = 2

    nonisolated static func < (lhs: RequeuePriority, rhs: RequeuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct RequeueEntry: Sendable {
    let credentialId: String
    let username: String
    let priority: RequeuePriority
    let reason: String
    let suggestDifferentProxy: Bool
    let requeueCount: Int
}

@MainActor
class RequeuePriorityService {
    static let shared = RequeuePriorityService()

    private let logger = DebugLogger.shared
    private var requeueCounts: [String: Int] = [:]
    private let maxRequeueCount: Int = 3

    func prioritize(credentialId: String, username: String, outcome: LoginOutcome) -> RequeueEntry? {
        let count = (requeueCounts[credentialId] ?? 0) + 1
        requeueCounts[credentialId] = count

        if count > maxRequeueCount {
            logger.log("RequeuePriority: \\(username) exceeded max requeue count (\\(maxRequeueCount)) — dropping", category: .automation, level: .warning)
            return nil
        }

        let priority: RequeuePriority
        let reason: String
        let suggestProxy: Bool

        switch outcome {
        case .timeout:
            priority = .high
            reason = "timeout (likely transient)"
            suggestProxy = false
        case .connectionFailure:
            priority = .medium
            reason = "connection failure"
            suggestProxy = true
        case .redBannerError:
            priority = .medium
            reason = "red banner error"
            suggestProxy = true
        case .unsure:
            priority = .low
            reason = "unsure result"
            suggestProxy = false
        default:
            return nil
        }

        logger.log("RequeuePriority: \\(username) → \\(priority) (\\(reason)) requeue #\\(count)", category: .automation, level: .info)
        return RequeueEntry(
            credentialId: credentialId,
            username: username,
            priority: priority,
            reason: reason,
            suggestDifferentProxy: suggestProxy,
            requeueCount: count
        )
    }

    func sortByPriority(_ entries: [RequeueEntry]) -> [RequeueEntry] {
        entries.sorted { a, b in
            if a.priority != b.priority {
                return a.priority < b.priority
            }
            return a.requeueCount < b.requeueCount
        }
    }

    func resetCounts() {
        requeueCounts.removeAll()
    }

    func requeueCount(for credentialId: String) -> Int {
        requeueCounts[credentialId] ?? 0
    }
}
