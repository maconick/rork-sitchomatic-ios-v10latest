import Foundation
import UIKit

@MainActor
final class CrashProtectionService {
    static let shared = CrashProtectionService()

    private let logger = DebugLogger.shared
    private let memoryMonitor = MemoryMonitor()
    private var memoryTrimTimer: Task<Void, Never>?
    private var continuousLogFlushTask: Task<Void, Never>?
    private var isRegistered: Bool = false

    private var emergencyBatchKillCount: Int = 0
    private var lastEmergencyCleanup: Date = .distantPast
    private var crashCount: Int = 0
    private var lastCrashRecoveryTime: Date = .distantPast
    private var sessionCrashLog: [(timestamp: Date, signal: String, memoryMB: Int)] = []
    private(set) var lastCrashReport: CrashReport?

    private let stateFile = "crash_protection_state.json"
    private let crashReportFile = "crash_report_pending.json"

    // MARK: - Public API

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        installSignalHandlers()
        restoreState()
        startAdaptiveMemoryTrimming()
        startContinuousLogFlush()
        let t = memoryMonitor.thresholds
        logger.log("CrashProtection: registered (soft=\(t.softMB)MB, high=\(t.highMB)MB, critical=\(t.criticalMB)MB, emergency=\(t.emergencyMB)MB, previousCrashes=\(crashCount))", category: .system, level: .info)
    }

    func currentMemoryUsageMB() -> Int { MemoryMonitor.currentUsageMB() }
    var isMemoryDeathSpiral: Bool { memoryMonitor.deathSpiralDetected }
    var isPreemptiveThrottleActive: Bool { memoryMonitor.preemptiveThrottleActive }
    var currentGrowthRateMBPerSec: Double { memoryMonitor.growthRateMBPerSecond }
    var totalCrashCount: Int { crashCount }
    var shouldReduceConcurrency: Bool { memoryMonitor.shouldReduceConcurrency }
    var recommendedMaxConcurrency: Int { memoryMonitor.recommendedMaxConcurrency }

    var diagnosticSummary: String {
        let mb = currentMemoryUsageMB()
        let webViews = WebViewPool.shared.activeCount
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)
        let spiral = memoryMonitor.deathSpiralDetected ? " SPIRAL!" : ""
        return "Memory: \(mb)MB (\(growth)MB/s\(spiral)) | WebViews: \(webViews) | EmergencyKills: \(emergencyBatchKillCount) | Crashes: \(crashCount) | ConsecutiveCritical: \(memoryMonitor.consecutiveCriticalChecks)"
    }

    func generateCrashReportText() -> String {
        lastCrashReport?.formattedReport ?? "No crash report available"
    }

    // MARK: - Memory Monitoring Loop

    private func startAdaptiveMemoryTrimming() {
        memoryTrimTimer?.cancel()
        memoryTrimTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = self.memoryMonitor.adaptiveCheckInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self.performMemoryCheck()
            }
        }
    }

    private func performMemoryCheck() {
        let (level, usedMB) = memoryMonitor.update()
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)

        if memoryMonitor.deathSpiralDetected {
            let ratePerMin = memoryMonitor.growthRateMBPerSecond * 60
            logger.log("CrashProtection: DEATH SPIRAL DETECTED — memory growing \(Int(ratePerMin))MB/min", category: .system, level: .critical)
            AppAlertManager.shared.pushCritical(
                source: .system,
                title: "Memory Death Spiral",
                message: "Memory growing at \(Int(ratePerMin))MB/min. Batches will be stopped to prevent crash."
            )
            if usedMB > memoryMonitor.thresholds.criticalMB {
                performEmergencyCleanup(usedMB: usedMB)
                return
            }
        }

        if memoryMonitor.preemptiveThrottleActive {
            logger.log("CrashProtection: RUNAWAY GROWTH — \(String(format: "%.0f", memoryMonitor.growthRateMBPerSecond))MB/s detected at \(usedMB)MB — preemptive throttle active", category: .system, level: .critical)
            performAggressiveCleanup()
        }

        switch level {
        case .emergency:
            logger.log("CrashProtection: EMERGENCY memory (\(usedMB)MB, growth=\(growth)MB/s) — killing active batches (consecutive critical: \(memoryMonitor.consecutiveCriticalChecks))", category: .system, level: .critical)
            performEmergencyCleanup(usedMB: usedMB)
        case .critical:
            logger.log("CrashProtection: CRITICAL memory (\(usedMB)MB, growth=\(growth)MB/s) — aggressive cleanup (consecutive: \(memoryMonitor.consecutiveCriticalChecks))", category: .system, level: .critical)
            performAggressiveCleanup()
            if memoryMonitor.shouldEscalateToCritical {
                logger.log("CrashProtection: \(memoryMonitor.consecutiveCriticalChecks) consecutive critical checks — escalating to emergency", category: .system, level: .critical)
                performEmergencyCleanup(usedMB: usedMB)
            }
        case .high:
            logger.log("CrashProtection: High memory (\(usedMB)MB) — soft cleanup", category: .system, level: .warning)
            performSoftCleanup()
        case .soft:
            performPreemptiveCleanup()
        case .normal:
            break
        }
    }

    // MARK: - Cleanup Tiers

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
            logger.log("CrashProtection: EMERGENCY — force-stopping login batch (memory: \(usedMB)MB, kill #\(emergencyBatchKillCount))", category: .system, level: .critical)
            LoginViewModel.shared.emergencyStop()
        }
        if PPSRAutomationViewModel.shared.isRunning {
            logger.log("CrashProtection: EMERGENCY — force-stopping PPSR batch (memory: \(usedMB)MB)", category: .system, level: .critical)
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

    // MARK: - Continuous Log Flush

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
        let growth = String(format: "%.1f", memoryMonitor.growthRateMBPerSecond)
        let diag = """
        === PRE-CRASH DIAGNOSTICS ===
        Timestamp: \(Date())
        Memory: \(memMB)MB (growth: \(growth)MB/s)
        WebViews: \(WebViewPool.shared.activeCount)
        Login Batch: \(LoginViewModel.shared.isRunning ? "RUNNING" : "idle")
        PPSR Batch: \(PPSRAutomationViewModel.shared.isRunning ? "RUNNING" : "idle")
        Death Spiral: \(memoryMonitor.deathSpiralDetected)
        Consecutive Critical: \(memoryMonitor.consecutiveCriticalChecks)
        Emergency Kills: \(emergencyBatchKillCount)
        Total Crashes: \(crashCount)
        iOS: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        App: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        ===
        """
        try? diag.write(to: diagURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Signal Handlers

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

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            let entry = "CRASH: \(signalName) at \(Date()) | Memory: \(memMB)MB | WebViews: unknown\n"
            if let data = entry.data(using: .utf8), let crashLog = docs?.appendingPathComponent("last_crash.log") {
                try? data.write(to: crashLog, options: .atomic)
            }
            let stateJSON = "{\"crashCount\":\(1),\"lastCrashSignal\":\"\(signalName)\",\"lastCrashMemoryMB\":\(memMB),\"lastCrashTimestamp\":\(Date().timeIntervalSince1970)}"
            if let stateData = stateJSON.data(using: .utf8), let stateFile = docs?.appendingPathComponent("crash_protection_state.json") {
                try? stateData.write(to: stateFile, options: .atomic)
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

    // MARK: - Crash Report Recovery

    func checkForPreviousCrash() -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let crashLog = docs?.appendingPathComponent("last_crash.log"),
              let data = try? Data(contentsOf: crashLog) else { return nil }
        let crashInfo = String(data: data, encoding: .utf8)

        let diagURL = docs?.appendingPathComponent("pre_crash_diagnostics.txt")
        let diagnosticLog = diagURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "No pre-crash diagnostics"
        let persistedLog = docs?.appendingPathComponent("debug_log_latest.txt")
        let savedLog = persistedLog.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

        let screenshotKeys = loadRecentScreenshotKeys()

        if let crashInfo {
            crashCount += 1
            lastCrashRecoveryTime = Date()
            let mb = currentMemoryUsageMB()
            sessionCrashLog.append((Date(), crashInfo.components(separatedBy: " ").first ?? "UNKNOWN", mb))
            persistState()

            let (signal, crashMemMB, crashTimestamp) = loadCrashState(from: docs)

            let report = CrashReport(
                signal: signal, memoryMB: crashMemMB, timestamp: crashTimestamp,
                crashLog: crashInfo,
                diagnosticLog: diagnosticLog + "\n\n=== PERSISTED LOG (tail) ===\n" + String(savedLog.suffix(5000)),
                iosVersion: UIDevice.current.systemVersion,
                deviceModel: UIDevice.current.model,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                screenshotKeys: screenshotKeys
            )
            lastCrashReport = report
            if let encoded = try? JSONEncoder().encode(report),
               let reportURL = docs?.appendingPathComponent(crashReportFile) {
                try? encoded.write(to: reportURL, options: .atomic)
            }
        }

        try? FileManager.default.removeItem(at: crashLog)
        if let diagURL { try? FileManager.default.removeItem(at: diagURL) }
        return crashInfo
    }

    func loadPendingCrashReport() -> CrashReport? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let reportURL = docs?.appendingPathComponent(crashReportFile),
              let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(CrashReport.self, from: data)
    }

    func clearPendingCrashReport() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let reportURL = docs?.appendingPathComponent(crashReportFile) {
            try? FileManager.default.removeItem(at: reportURL)
        }
        lastCrashReport = nil
    }

    // MARK: - Persistence Helpers

    private func loadRecentScreenshotKeys() -> [String] {
        let screenshotDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("ScreenshotCache", isDirectory: true)
        guard let dir = screenshotDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files.filter { $0.pathExtension == "jpg" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate > bDate
            }
            .prefix(20)
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    private func loadCrashState(from docs: URL?) -> (String, Int, TimeInterval) {
        guard let stateURL = docs?.appendingPathComponent(stateFile),
              let stateData = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] else {
            return ("UNKNOWN", 0, Date().timeIntervalSince1970)
        }
        return (
            json["lastCrashSignal"] as? String ?? "UNKNOWN",
            json["lastCrashMemoryMB"] as? Int ?? 0,
            json["lastCrashTimestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        )
    }

    private func persistState() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let stateURL = docs?.appendingPathComponent(stateFile) else { return }
        let json = "{\"crashCount\":\(crashCount),\"emergencyKills\":\(emergencyBatchKillCount),\"lastCrashTimestamp\":\(lastCrashRecoveryTime.timeIntervalSince1970)}"
        try? json.data(using: .utf8)?.write(to: stateURL, options: .atomic)
    }

    private func restoreState() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let stateURL = docs?.appendingPathComponent(stateFile),
              let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let count = json["crashCount"] as? Int { crashCount = count }
        if let kills = json["emergencyKills"] as? Int { emergencyBatchKillCount = kills }
    }
}
