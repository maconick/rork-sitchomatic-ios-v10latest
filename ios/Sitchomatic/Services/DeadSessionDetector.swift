import Foundation
import WebKit

@MainActor
class DeadSessionDetector {
    static let shared = DeadSessionDetector()

    private let logger = DebugLogger.shared
    private let heartbeatTimeoutSeconds: TimeInterval = 15

    func isSessionAlive(_ webView: WKWebView?, sessionId: String = "") async -> Bool {
        guard let webView else {
            logger.log("DeadSessionDetector: webView is nil — session dead", category: .webView, level: .warning, sessionId: sessionId)
            return false
        }

        let alive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let result = try await webView.evaluateJavaScript("'heartbeat_ok'")
                    return (result as? String) == "heartbeat_ok"
                } catch {
                    return false
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(self.heartbeatTimeoutSeconds))
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !alive {
            logger.log("DeadSessionDetector: session HUNG — no JS response in \(Int(heartbeatTimeoutSeconds))s", category: .webView, level: .error, sessionId: sessionId)
        }

        return alive
    }

    func checkAndRecover(
        webView: WKWebView?,
        sessionId: String,
        onRecovery: () async -> Void
    ) async -> Bool {
        let alive = await isSessionAlive(webView, sessionId: sessionId)
        if !alive {
            logger.log("DeadSessionDetector: triggering recovery for session \(sessionId)", category: .webView, level: .warning, sessionId: sessionId)
            await onRecovery()
            return true
        }
        return false
    }
}
