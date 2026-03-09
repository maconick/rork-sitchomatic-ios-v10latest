import BackgroundTasks
import UIKit

@MainActor
class BackgroundTaskService {
    static let shared = BackgroundTaskService()
    static let batchProcessingIdentifier = "Sitchomatic.ios77.batchProcessing"

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func beginExtendedBackgroundExecution(reason: String) {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            self?.endExtendedBackgroundExecution()
        }
        DebugLogger.shared.log("Background execution started: \(reason)", category: .system, level: .info)
    }

    func endExtendedBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        DebugLogger.shared.log("Background execution ended", category: .system, level: .info)
    }

    var isRunningInBackground: Bool {
        backgroundTask != .invalid
    }

    var remainingBackgroundTime: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}
