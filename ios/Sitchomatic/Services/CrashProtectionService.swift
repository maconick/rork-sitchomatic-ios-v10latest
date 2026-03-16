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

    private var memoryHistory: [(timestamp: Date, mb: Int)] = []
    private let memoryHistoryMaxCount: Int = 30
    private var memoryGrowthRateMBPerSecond: Double = 0
    private var lastMemoryCheckTime: Date = Date()
    private var lastMemoryCheckMB: Int = 0
    private var memoryDeathSpiralDetected: Bool = false
    private var preemptiveThrottleActive: Bool = false

    private let adaptiveCheckIntervalBase: TimeInterval = 5
    private let adaptiveCheckIntervalMin: TimeInterval = 2
    private let adaptiveCheckIntervalMax: TimeInterval = 10

    private var crashCount: Int = 0
    private var lastCrashRecoveryTime: Date = .distantPast
    private var sessionCrashLog: [(timestamp: Date, signal: String, memoryMB: Int)] = []
    private(set) var lastCrashReport: CrashReport?

    private let stateFile = "crash_protection_state.json"
    private let crashReportFile = "crash_report_pending.json"
    private var continuousLogFlushTask: Task<Void, Never>?

    nonisolated struct CrashReport: Codable, Sendable {
        let signal: String
        let memoryMB: Int
        let timestamp: TimeInterval
        let crashLog: String
        let diagnosticLog: String
        let iosVersion: String
        let deviceModel: String
        let appVersion: String
        let screenshotKeys: [String]
    }

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        installSignalHandlers()
        restoreState()
        startAdaptiveMemoryTrimming()
        startContinuousLogFlush()
        logger.log("CrashProtection: registered (soft=\(softMemoryThresholdMB)MB, high=\(memoryThresholdMB)MB, critical=\(criticalMemoryThresholdMB)MB, emergency=\(emergencyMemoryThresholdMB)MB, previousCrashes=\(crashCount))", category: .system, level: .info)
    }

    private func startContinuousLogFlush() {
        continuousLogFlushTask?.cancel()
        continuousLogFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                DebugLogger.shared.persistLatestLog()
                self.persistPreCrashDiagnostics()
            }
        }
    }

    private func persistPreCrashDiagnostics() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let diagURL = docs?.appendingPathComponent("pre_crash_diagnostics.txt") else { return }
        let memMB = currentMemoryUsageMB()
        let growth = String(format: "%.1f", memoryGrowthRateMBPerSecond)
        let webViews = WebViewPool.shared.activeCount
        let loginRunning = LoginViewModel.shared.isRunning
        let ppsrRunning = PPSRAutomationViewModel.shared.isRunning
        let diag = """
        === PRE-CRASH DIAGNOSTICS ===
        Timestamp: \(Date())
        Memory: \(memMB)MB (growth: \(growth)MB/s)
        WebViews: \(webViews)
        Login Batch: \(loginRunning ? "RUNNING" : "idle")
        PPSR Batch: \(ppsrRunning ? "RUNNING" : "idle")
        Death Spiral: \(memoryDeathSpiralDetected)
        Consecutive Critical: \(consecutiveCriticalChecks)
        Emergency Kills: \(emergencyBatchKillCount)
        Total Crashes: \(crashCount)
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        App: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        ===
        """
        try? diag.write(to: diagURL, atomically: true, encoding: .utf8)
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

            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            let memResult = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            let memMB = memResult == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 0

            let entry = "CRASH: \(signalName) at \(Date()) | Memory: \(memMB)MB | WebViews: unknown\n"
            if let data = entry.data(using: .utf8) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let crashLog = docs?.appendingPathComponent("last_crash.log") {
                    try? data.write(to: crashLog, options: .atomic)
                }
            }

            let stateJSON = "{\"crashCount\":\(1),\"lastCrashSignal\":\"\(signalName)\",\"lastCrashMemoryMB\":\(memMB),\"lastCrashTimestamp\":\(Date().timeIntervalSince1970)}"
            if let stateData = stateJSON.data(using: .utf8) {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let stateFile = docs?.appendingPathComponent("crash_protection_state.json") {
                    try? stateData.write(to: stateFile, options: .atomic)
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

    private func startAdaptiveMemoryTrimming() {
        memoryTrimTimer?.cancel()
        lastMemoryCheckTime = Date()
        lastMemoryCheckMB = currentMemoryUsageMB()
        memoryTrimTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.computeAdaptiveCheckInterval()
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.performMemoryCheck()
            }
        }
    }

    private func computeAdaptiveCheckInterval() -> TimeInterval {
        let mb = lastMemoryCheckMB
        if mb > criticalMemoryThresholdMB || memoryDeathSpiralDetected {
            return adaptiveCheckIntervalMin
        } else if mb > memoryThresholdMB {
            return 3
        } else if mb > softMemoryThresholdMB {
            return adaptiveCheckIntervalBase
        }
        return adaptiveCheckIntervalMax
    }

    private func performMemoryCheck() {
        let now = Date()
        let usedMB = currentMemoryUsageMB()

        let timeDelta = now.timeIntervalSince(lastMemoryCheckTime)
        if timeDelta > 0 {
            let mbDelta = Double(usedMB - lastMemoryCheckMB)
            memoryGrowthRateMBPerSecond = mbDelta / timeDelta
        }
        lastMemoryCheckTime = now
        lastMemoryCheckMB = usedMB

        memoryHistory.append((now, usedMB))
        if memoryHistory.count > memoryHistoryMaxCount {
            memoryHistory.removeFirst(memoryHistory.count - memoryHistoryMaxCount)
        }

        detectMemoryDeathSpiral(currentMB: usedMB)
        detectRunawayGrowth(currentMB: usedMB)

        if usedMB > emergencyMemoryThresholdMB {
            consecutiveCriticalChecks += 1
            logger.log("CrashProtection: EMERGENCY memory (\(usedMB)MB, growth=\(String(format: "%.1f", memoryGrowthRateMBPerSecond))MB/s) — killing active batches and purging all caches (consecutive critical: \(consecutiveCriticalChecks))", category: .system, level: .critical)
            performEmergencyCleanup(usedMB: usedMB)
        } else if usedMB > criticalMemoryThresholdMB {
            consecutiveCriticalChecks += 1
            logger.log("CrashProtection: CRITICAL memory (\(usedMB)MB, growth=\(String(format: "%.1f", memoryGrowthRateMBPerSecond))MB/s) — aggressive cleanup (consecutive: \(consecutiveCriticalChecks))", category: .system, level: .critical)
            performAggressiveCleanup()
            if consecutiveCriticalChecks >= 3 {
                logger.log("CrashProtection: \(consecutiveCriticalChecks) consecutive critical checks — escalating to emergency", category: .system, level: .critical)
                performEmergencyCleanup(usedMB: usedMB)
            }
        } else if usedMB > memoryThresholdMB {
            consecutiveCriticalChecks = max(0, consecutiveCriticalChecks - 1)
            logger.log("CrashProtection: High memory (\(usedMB)MB) — soft cleanup", category: .system, level: .warning)
            performSoftCleanup()
            preemptiveThrottleActive = false
        } else if usedMB > softMemoryThresholdMB {
            consecutiveCriticalChecks = 0
            performPreemptiveCleanup()
            preemptiveThrottleActive = false
            memoryDeathSpiralDetected = false
        } else {
            consecutiveCriticalChecks = 0
            preemptiveThrottleActive = false
            memoryDeathSpiralDetected = false
        }
    }

    private func detectMemoryDeathSpiral(currentMB: Int) {
        guard memoryHistory.count >= 5 else { return }
        let recent = memoryHistory.suffix(5)
        let allIncreasing = zip(recent.dropLast(), recent.dropFirst()).allSatisfy { $0.mb < $1.mb }
        let totalGrowth = recent.last!.mb - recent.first!.mb
        let timeSpan = recent.last!.timestamp.timeIntervalSince(recent.first!.timestamp)

        if allIncreasing && totalGrowth > 500 && timeSpan > 0 {
            let ratePerMin = Double(totalGrowth) / (timeSpan / 60.0)
            if ratePerMin > 200 {
                memoryDeathSpiralDetected = true
                logger.log("CrashProtection: DEATH SPIRAL DETECTED — memory growing \(Int(ratePerMin))MB/min over last \(Int(timeSpan))s (\(recent.first!.mb)MB → \(recent.last!.mb)MB)", category: .system, level: .critical)

                AppAlertManager.shared.pushCritical(
                    source: .system,
                    title: "Memory Death Spiral",
                    message: "Memory growing at \(Int(ratePerMin))MB/min. Batches will be stopped to prevent crash."
                )

                if currentMB > criticalMemoryThresholdMB {
                    performEmergencyCleanup(usedMB: currentMB)
                }
            }
        }
    }

    private func detectRunawayGrowth(currentMB: Int) {
        guard memoryGrowthRateMBPerSecond > 50 && currentMB > softMemoryThresholdMB else { return }

        if !preemptiveThrottleActive {
            preemptiveThrottleActive = true
            logger.log("CrashProtection: RUNAWAY GROWTH — \(String(format: "%.0f", memoryGrowthRateMBPerSecond))MB/s detected at \(currentMB)MB — preemptive throttle active", category: .system, level: .critical)

            performAggressiveCleanup()
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

        DeadSessionDetector.shared.stopAllWatchdogs()

        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.memoryCapacity = 0

        NetworkResilienceService.shared.invalidateSharedSessions()

        if timeSinceLast < 60 {
            logger.log("CrashProtection: TWO emergency cleanups within \(Int(timeSinceLast))s — app may be in memory death spiral", category: .system, level: .critical)

            PersistentFileStorageService.shared.forceSave()
            LoginViewModel.shared.persistCredentialsNow()
            PPSRAutomationViewModel.shared.persistCardsNow()
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
        let crashInfo = String(data: data, encoding: .utf8)

        let diagURL = docs?.appendingPathComponent("pre_crash_diagnostics.txt")
        let diagnosticLog = diagURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No pre-crash diagnostics"

        let persistedLog = docs?.appendingPathComponent("debug_log_latest.txt")
        let savedLog = persistedLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        let screenshotDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ScreenshotCache", isDirectory: true)
        var screenshotKeys: [String] = []
        if let dir = screenshotDir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let recent = files.filter { $0.pathExtension == "jpg" }
                .sorted { a, b in
                    let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return aDate > bDate
                }
                .prefix(20)
            screenshotKeys = recent.map { $0.deletingPathExtension().lastPathComponent }
        }

        if let crashInfo {
            crashCount += 1
            lastCrashRecoveryTime = Date()
            let mb = currentMemoryUsageMB()
            sessionCrashLog.append((Date(), crashInfo.components(separatedBy: " ").first ?? "UNKNOWN", mb))
            persistState()

            let stateJSON = docs?.appendingPathComponent(stateFile)
            var signal = "UNKNOWN"
            var crashMemMB = 0
            var crashTimestamp: TimeInterval = Date().timeIntervalSince1970
            if let stateURL = stateJSON, let stateData = try? Data(contentsOf: stateURL),
               let json = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] {
                signal = json["lastCrashSignal"] as? String ?? "UNKNOWN"
                crashMemMB = json["lastCrashMemoryMB"] as? Int ?? 0
                crashTimestamp = json["lastCrashTimestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
            }

            let report = CrashReport(
                signal: signal,
                memoryMB: crashMemMB,
                timestamp: crashTimestamp,
                crashLog: crashInfo,
                diagnosticLog: diagnosticLog + "\n\n=== PERSISTED LOG (tail) ===\n" + String(savedLog.suffix(5000)),
                iosVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                screenshotKeys: screenshotKeys
            )
            lastCrashReport = report

            if let encoded = try? JSONEncoder().encode(report) {
                let reportURL = docs?.appendingPathComponent(crashReportFile)
                try? encoded.write(to: reportURL!, options: .atomic)
            }
        }

        try? FileManager.default.removeItem(at: crashLog)
        if let diagURL { try? FileManager.default.removeItem(at: diagURL) }

        return crashInfo
    }

    func loadPendingCrashReport() -> CrashReport? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let reportURL = docs?.appendingPathComponent(crashReportFile) else { return nil }
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(CrashReport.self, from: data)
    }

    func clearPendingCrashReport() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let reportURL = docs?.appendingPathComponent(crashReportFile) {
            try? FileManager.default.removeItem(at: reportURL)
        }
        lastCrashReport = nil
    }

    func generateCrashReportText() -> String {
        guard let report = lastCrashReport else { return "No crash report available" }
        let crashDate = Date(timeIntervalSince1970: report.timestamp)
        return """
        ========================================
        CRASH REPORT FOR RORK
        ========================================
        Signal: \(report.signal)
        Memory at Crash: \(report.memoryMB)MB
        Crash Time: \(crashDate)
        iOS Version: \(report.iosVersion)
        Device: \(report.deviceModel)
        App Version: \(report.appVersion)
        Screenshots Preserved: \(report.screenshotKeys.count)

        === CRASH LOG ===
        \(report.crashLog)

        === PRE-CRASH DIAGNOSTICS ===
        \(report.diagnosticLog)
        ========================================
        END OF CRASH REPORT
        ========================================
        """
    }

    var isMemoryDeathSpiral: Bool { memoryDeathSpiralDetected }
    var isPreemptiveThrottleActive: Bool { preemptiveThrottleActive }
    var currentGrowthRateMBPerSec: Double { memoryGrowthRateMBPerSecond }
    var totalCrashCount: Int { crashCount }

    var shouldReduceConcurrency: Bool {
        let mb = currentMemoryUsageMB()
        return mb > memoryThresholdMB || memoryDeathSpiralDetected || preemptiveThrottleActive
    }

    var recommendedMaxConcurrency: Int {
        let mb = currentMemoryUsageMB()
        if mb > criticalMemoryThresholdMB || memoryDeathSpiralDetected { return 1 }
        if mb > memoryThresholdMB || preemptiveThrottleActive { return 2 }
        if mb > softMemoryThresholdMB { return 3 }
        return 5
    }

    var diagnosticSummary: String {
        let mb = currentMemoryUsageMB()
        let webViews = WebViewPool.shared.activeCount
        let growth = String(format: "%.1f", memoryGrowthRateMBPerSecond)
        let spiral = memoryDeathSpiralDetected ? " SPIRAL!" : ""
        return "Memory: \(mb)MB (\(growth)MB/s\(spiral)) | WebViews: \(webViews) | EmergencyKills: \(emergencyBatchKillCount) | Crashes: \(crashCount) | ConsecutiveCritical: \(consecutiveCriticalChecks)"
    }

    private func persistState() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let stateURL = docs?.appendingPathComponent(stateFile) else { return }
        let json = "{\"crashCount\":\(crashCount),\"emergencyKills\":\(emergencyBatchKillCount),\"lastCrashTimestamp\":\(lastCrashRecoveryTime.timeIntervalSince1970)}"
        try? json.data(using: .utf8)?.write(to: stateURL, options: .atomic)
    }

    private func restoreState() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let stateURL = docs?.appendingPathComponent(stateFile) else { return }
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let count = json["crashCount"] as? Int {
            crashCount = count
        }
        if let kills = json["emergencyKills"] as? Int {
            emergencyBatchKillCount = kills
        }
    }
}
