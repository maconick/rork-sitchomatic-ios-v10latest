import Foundation
import UIKit

@MainActor
final class CrashProtectionService {
    static let shared = CrashProtectionService()

    private let logger = DebugLogger.shared
    private var memoryTrimTimer: Task<Void, Never>?
    private var isRegistered: Bool = false
    private let memoryThresholdMB: Int = 350
    private let criticalMemoryThresholdMB: Int = 500

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        installSignalHandlers()
        startPeriodicMemoryTrimming()
        logger.log("CrashProtection: registered signal handlers and memory trimmer", category: .system, level: .info)
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
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.performMemoryCheck()
            }
        }
    }

    private func performMemoryCheck() {
        let usedMB = currentMemoryUsageMB()

        if usedMB > criticalMemoryThresholdMB {
            logger.log("CrashProtection: CRITICAL memory (\(usedMB)MB) — aggressive cleanup", category: .system, level: .critical)
            performAggressiveCleanup()
        } else if usedMB > memoryThresholdMB {
            logger.log("CrashProtection: High memory (\(usedMB)MB) — soft cleanup", category: .system, level: .warning)
            performSoftCleanup()
        }
    }

    private func performSoftCleanup() {
        DebugLogger.shared.trimEntries(to: 2000)
        WebViewPool.shared.drainPreWarmed()
        LoginViewModel.shared.trimAttemptsIfNeeded()
        PPSRAutomationViewModel.shared.trimChecksIfNeeded()
    }

    private func performAggressiveCleanup() {
        DebugLogger.shared.trimEntries(to: 1000)
        DebugLogger.shared.handleMemoryPressure()
        WebViewPool.shared.handleMemoryPressure()
        ScreenshotCacheService.shared.setMaxCacheCounts(memory: 10, disk: 200)
        LoginViewModel.shared.handleMemoryPressure()
        LoginViewModel.shared.trimAttemptsIfNeeded()
        PPSRAutomationViewModel.shared.handleMemoryPressure()
        PPSRAutomationViewModel.shared.trimChecksIfNeeded()
    }

    private nonisolated func currentMemoryUsageMB() -> Int {
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
}
