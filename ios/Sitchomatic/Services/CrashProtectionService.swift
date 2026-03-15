import Foundation
import UIKit

@MainActor
final class CrashProtectionService {
    static let shared = CrashProtectionService()

    private let logger = DebugLogger.shared
    private var memoryTrimTimer: Task<Void, Never>?
    private var isRegistered: Bool = false
    private let softMemoryThresholdMB: Int = 1500
    private let memoryThresholdMB: Int = 2500
    private let criticalMemoryThresholdMB: Int = 4000
    private let emergencyMemoryThresholdMB: Int = 5000
    private var consecutiveCriticalChecks: Int = 0
    private var lastEmergencyCleanup: Date = .distantPast
    private var emergencyBatchKillCount: Int = 0

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        installSignalHandlers()
        startPeriodicMemoryTrimming()
        logger.log("CrashProtection: registered signal handlers and memory trimmer (soft=\(softMemoryThresholdMB)MB, high=\(memoryThresholdMB)MB, critical=\(criticalMemoryThresholdMB)MB, emergency=\(emergencyMemoryThresholdMB)MB)", category: .system, level: .info)
    }

    private func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signal in
            let signalName: String
            switch signal {
            case SIGABRT: signalName = "SIGABRT"
            case SIGSEGV: signalName = "SIGSEGV"
            case SIGBUS: signalName = "SIGBUS"
            case SIGFPE: signalName = "SIGFPE"
            case SIGILL: signalName = "SIGILL"
            case SIGTRAP: signalName = "SIGTRAP"
            default: signalName = "SIGNAL(\(signal))"
            }

            let entry = "CRASH: \(signalName) at \(Date())\n"
            if let data = entry.data(using: .utf8) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let crashLog = docs?.appendingPathComponent("last_crash.log") {
                    try? data.write(to: crashLog, options: .atomic)
                }
            }
        }

        signal(SIGABRT, handler)
        signal(SIGSEGV, handler)
        signal(SIGBUS, handler)
        signal(SIGFPE, handler)
        signal(SIGILL, handler)
        signal(SIGTRAP, handler)

        NSSetUncaughtExceptionHandler { exception in
            let entry = "EXCEPTION: \(exception.name.rawValue) - \(exception.reason ?? "unknown")\nStack: \(exception.callStackSymbols.prefix(20).joined(separator: "\n"))\n"
            if let data = entry.data(using: .utf8) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let crashLog = docs?.appendingPathComponent("last_crash.log") {
                    try? data.write(to: crashLog, options: .atomic)
                }
            }
        }
    }

    private func startPeriodicMemoryTrimming() {
        memoryTrimTimer?.cancel()
        memoryTrimTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.performMemoryCheck()
            }
        }
    }

    private func performMemoryCheck() {
        let usedMB = currentMemoryUsageMB()

        if usedMB > emergencyMemoryThresholdMB {
            consecutiveCriticalChecks += 1
            logger.log("CrashProtection: EMERGENCY memory (\(usedMB)MB) — killing active batches and purging all caches (consecutive critical: \(consecutiveCriticalChecks))", category: .system, level: .critical)
            performEmergencyCleanup(usedMB: usedMB)
        } else if usedMB > criticalMemoryThresholdMB {
            consecutiveCriticalChecks += 1
            logger.log("CrashProtection: CRITICAL memory (\(usedMB)MB) — aggressive cleanup (consecutive: \(consecutiveCriticalChecks))", category: .system, level: .critical)
            performAggressiveCleanup()
            if consecutiveCriticalChecks >= 3 {
                logger.log("CrashProtection: \(consecutiveCriticalChecks) consecutive critical checks — escalating to emergency", category: .system, level: .critical)
                performEmergencyCleanup(usedMB: usedMB)
            }
        } else if usedMB > memoryThresholdMB {
            consecutiveCriticalChecks = max(0, consecutiveCriticalChecks - 1)
            logger.log("CrashProtection: High memory (\(usedMB)MB) — soft cleanup", category: .system, level: .warning)
            performSoftCleanup()
        } else if usedMB > softMemoryThresholdMB {
            consecutiveCriticalChecks = 0
            performPreemptiveCleanup()
        } else {
            consecutiveCriticalChecks = 0
        }
    }

    private func performPreemptiveCleanup() {
        DebugLogger.shared.trimEntries(to: 2500)
        WebViewPool.shared.drainPreWarmed()
    }

    private func performSoftCleanup() {
        DebugLogger.shared.trimEntries(to: 1500)
        WebViewPool.shared.drainPreWarmed()
        LoginViewModel.shared.trimAttemptsIfNeeded()
        PPSRAutomationViewModel.shared.trimChecksIfNeeded()
    }

    private func performAggressiveCleanup() {
        DebugLogger.shared.trimEntries(to: 800)
        DebugLogger.shared.handleMemoryPressure()
        WebViewPool.shared.handleMemoryPressure()
        ScreenshotCacheService.shared.setMaxCacheCounts(memory: 10, disk: 200)
        LoginViewModel.shared.handleMemoryPressure()
        LoginViewModel.shared.trimAttemptsIfNeeded()
        PPSRAutomationViewModel.shared.handleMemoryPressure()
        PPSRAutomationViewModel.shared.trimChecksIfNeeded()
    }

    private func performEmergencyCleanup(usedMB: Int) {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastEmergencyCleanup)
        lastEmergencyCleanup = now
        emergencyBatchKillCount += 1

        DebugLogger.shared.trimEntries(to: 300)
        DebugLogger.shared.handleMemoryPressure()
        WebViewPool.shared.emergencyPurgeAll()
        ScreenshotCacheService.shared.setMaxCacheCounts(memory: 5, disk: 100)
        ScreenshotCacheService.shared.clearAll()
        LoginViewModel.shared.handleMemoryPressure()
        LoginViewModel.shared.clearDebugScreenshots()
        LoginViewModel.shared.trimAttemptsIfNeeded()
        PPSRAutomationViewModel.shared.handleMemoryPressure()
        PPSRAutomationViewModel.shared.trimChecksIfNeeded()

        if LoginViewModel.shared.isRunning {
            logger.log("CrashProtection: EMERGENCY — force-stopping login batch to prevent OOM crash (memory: \(usedMB)MB, kill #\(emergencyBatchKillCount))", category: .system, level: .critical)
            LoginViewModel.shared.emergencyStop()
        }
        if PPSRAutomationViewModel.shared.isRunning {
            logger.log("CrashProtection: EMERGENCY — force-stopping PPSR batch to prevent OOM crash (memory: \(usedMB)MB)", category: .system, level: .critical)
            PPSRAutomationViewModel.shared.emergencyStop()
        }

        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.memoryCapacity = 0

        if timeSinceLast < 60 {
            logger.log("CrashProtection: TWO emergency cleanups within \(Int(timeSinceLast))s — app may be in memory death spiral", category: .system, level: .critical)
        }

        let afterMB = currentMemoryUsageMB()
        logger.log("CrashProtection: emergency cleanup freed ~\(usedMB - afterMB)MB (now \(afterMB)MB)", category: .system, level: .critical)
    }

    func currentMemoryUsageMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / (1024 * 1024))
    }

    func checkForPreviousCrash() -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let crashLog = docs?.appendingPathComponent("last_crash.log") else { return nil }
        guard let data = try? Data(contentsOf: crashLog) else { return nil }
        try? FileManager.default.removeItem(at: crashLog)
        return String(data: data, encoding: .utf8)
    }

    var diagnosticSummary: String {
        let mb = currentMemoryUsageMB()
        let webViews = WebViewPool.shared.activeCount
        return "Memory: \(mb)MB | WebViews: \(webViews) | EmergencyKills: \(emergencyBatchKillCount) | ConsecutiveCritical: \(consecutiveCriticalChecks)"
    }
}
