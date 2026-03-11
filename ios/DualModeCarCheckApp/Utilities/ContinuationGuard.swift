import Foundation

final class ContinuationGuard: @unchecked Sendable {
    private var consumed = false
    private let lock = NSLock()

    nonisolated init() {
        consumed = false
    }

    nonisolated func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
