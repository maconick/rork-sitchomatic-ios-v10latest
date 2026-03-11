import Foundation

nonisolated final class ContinuationGuard: @unchecked Sendable {
    private var consumed = false
    private let lock = NSLock()

    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
