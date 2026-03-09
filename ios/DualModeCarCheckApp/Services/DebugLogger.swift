import Foundation
import Combine
import UIKit

nonisolated enum DebugLogCategory: String, CaseIterable, Sendable, Identifiable, Codable {
    case automation = "Automation"
    case login = "Login"
    case ppsr = "PPSR"
    case superTest = "Super Test"
    case network = "Network"
    case proxy = "Proxy"
    case dns = "DNS"
    case vpn = "VPN"
    case url = "URL Rotation"
    case fingerprint = "Fingerprint"
    case stealth = "Stealth"
    case webView = "WebView"
    case persistence = "Persistence"
    case system = "System"
    case evaluation = "Evaluation"
    case screenshot = "Screenshot"
    case timing = "Timing"
    case healing = "Healing"
    case flowRecorder = "Flow Recorder"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .automation: "gearshape.2.fill"
        case .login: "person.badge.key.fill"
        case .ppsr: "car.side.fill"
        case .superTest: "bolt.horizontal.circle.fill"
        case .network: "wifi"
        case .proxy: "network"
        case .dns: "lock.shield.fill"
        case .vpn: "shield.lefthalf.filled"
        case .url: "arrow.triangle.2.circlepath"
        case .fingerprint: "fingerprint"
        case .stealth: "eye.slash.fill"
        case .webView: "safari.fill"
        case .persistence: "externaldrive.fill"
        case .system: "cpu"
        case .evaluation: "chart.bar.xaxis"
        case .screenshot: "camera.fill"
        case .timing: "stopwatch.fill"
        case .healing: "cross.circle.fill"
        case .flowRecorder: "record.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .automation: "blue"
        case .login: "green"
        case .ppsr: "cyan"
        case .superTest: "purple"
        case .network: "orange"
        case .proxy: "red"
        case .dns: "indigo"
        case .vpn: "teal"
        case .url: "mint"
        case .fingerprint: "pink"
        case .stealth: "gray"
        case .webView: "blue"
        case .persistence: "brown"
        case .system: "secondary"
        case .evaluation: "yellow"
        case .screenshot: "purple"
        case .timing: "orange"
        case .healing: "green"
        case .flowRecorder: "red"
        }
    }
}

nonisolated enum DebugLogLevel: String, CaseIterable, Sendable, Comparable, Codable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"
    case critical = "CRIT"

    nonisolated static func < (lhs: DebugLogLevel, rhs: DebugLogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var sortOrder: Int {
        switch self {
        case .trace: 0
        case .debug: 1
        case .info: 2
        case .success: 3
        case .warning: 4
        case .error: 5
        case .critical: 6
        }
    }

    var emoji: String {
        switch self {
        case .trace: "🔍"
        case .debug: "🐛"
        case .info: "ℹ️"
        case .success: "✅"
        case .warning: "⚠️"
        case .error: "❌"
        case .critical: "🔴"
        }
    }
}

nonisolated struct DebugLogEntry: Identifiable, Sendable, Codable {
    let id: UUID
    let timestamp: Date
    let category: DebugLogCategory
    let level: DebugLogLevel
    let message: String
    let detail: String?
    let sessionId: String?
    let durationMs: Int?
    let metadata: [String: String]?

    init(
        category: DebugLogCategory,
        level: DebugLogLevel,
        message: String,
        detail: String? = nil,
        sessionId: String? = nil,
        durationMs: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.level = level
        self.message = message
        self.detail = detail
        self.sessionId = sessionId
        self.durationMs = durationMs
        self.metadata = metadata
    }

    var formattedTime: String {
        DateFormatters.timeWithMillis.string(from: timestamp)
    }

    var fullTimestamp: String {
        DateFormatters.fullTimestamp.string(from: timestamp)
    }

    var compactLine: String {
        let dur = durationMs.map { " [\($0)ms]" } ?? ""
        let sess = sessionId.map { " <\($0)>" } ?? ""
        return "[\(formattedTime)] [\(level.rawValue)] [\(category.rawValue)]\(sess)\(dur) \(message)"
    }

    var exportLine: String {
        let dur = durationMs.map { " duration=\($0)ms" } ?? ""
        let sess = sessionId.map { " session=\($0)" } ?? ""
        let det = detail.map { " | \($0)" } ?? ""
        let meta = metadata.map { dict in
            " {" + dict.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "}"
        } ?? ""
        return "[\(fullTimestamp)] [\(level.rawValue)] [\(category.rawValue)]\(sess)\(dur) \(message)\(det)\(meta)"
    }
}

@MainActor
class DebugLogger {
    static let shared = DebugLogger()

    let didChange = PassthroughSubject<Void, Never>()

    private(set) var entries: [DebugLogEntry] = []
    var maxEntries: Int = 5000
    var minimumLevel: DebugLogLevel = .trace
    var enabledCategories: Set<DebugLogCategory> = Set(DebugLogCategory.allCases)
    var isRecording: Bool = true

    private var sessionTimers: [String: Date] = [:]
    private var stepTimers: [String: Date] = [:]

    private(set) var errorHealingLog: [ErrorHealingEvent] = []
    private(set) var retryTracker: [String: RetryState] = [:]
    private let criticalLogKey = "debug_critical_logs_v1"

    private var pendingEntries: [DebugLogEntry] = []
    private var flushTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?

    private(set) var cachedErrorCount: Int = 0
    private(set) var cachedWarningCount: Int = 0
    private(set) var cachedCriticalCount: Int = 0

    struct ErrorHealingEvent: Identifiable {
        let id: UUID = UUID()
        let timestamp: Date
        let category: DebugLogCategory
        let originalError: String
        let healingAction: String
        let succeeded: Bool
        let attemptNumber: Int
        let durationMs: Int?
    }

    struct RetryState {
        var attempts: Int = 0
        var maxAttempts: Int = 3
        var lastAttempt: Date?
        var lastError: String?
        var backoffMs: Int = 1000
        var isExhausted: Bool { attempts >= maxAttempts }

        mutating func recordAttempt(error: String?) {
            attempts += 1
            lastAttempt = Date()
            lastError = error
            backoffMs = min(backoffMs * 2, 30000)
        }

        mutating func reset() {
            attempts = 0
            lastError = nil
            backoffMs = 1000
        }
    }

    var filteredEntries: [DebugLogEntry] {
        entries
    }

    var entryCount: Int { entries.count }

    var errorCount: Int { cachedErrorCount }

    var warningCount: Int { cachedWarningCount }

    var criticalCount: Int { cachedCriticalCount }

    var healingSuccessRate: Double {
        guard !errorHealingLog.isEmpty else { return 1.0 }
        let successes = errorHealingLog.filter(\.succeeded).count
        return Double(successes) / Double(errorHealingLog.count)
    }

    var recentErrors: [DebugLogEntry] {
        Array(entries.filter { $0.level >= .error }.prefix(50))
    }

    func log(
        _ message: String,
        category: DebugLogCategory = .system,
        level: DebugLogLevel = .info,
        detail: String? = nil,
        sessionId: String? = nil,
        durationMs: Int? = nil,
        metadata: [String: String]? = nil
    ) {
        guard isRecording else { return }
        guard level >= minimumLevel else { return }
        guard enabledCategories.contains(category) else { return }

        let entry = DebugLogEntry(
            category: category,
            level: level,
            message: message,
            detail: detail,
            sessionId: sessionId,
            durationMs: durationMs,
            metadata: metadata
        )

        pendingEntries.append(entry)

        if level >= .error {
            flushPendingEntries()
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.flushPendingEntries()
        }
    }

    private func flushPendingEntries() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingEntries.isEmpty else { return }
        let batch = pendingEntries
        pendingEntries.removeAll()

        for entry in batch {
            if entry.level >= .error { cachedErrorCount += 1 }
            if entry.level == .warning { cachedWarningCount += 1 }
            if entry.level >= .critical { cachedCriticalCount += 1 }
        }

        entries.insert(contentsOf: batch.reversed(), at: 0)
        if entries.count > maxEntries {
            let overflow = entries.suffix(from: maxEntries)
            for entry in overflow {
                if entry.level >= .error { cachedErrorCount = max(0, cachedErrorCount - 1) }
                if entry.level == .warning { cachedWarningCount = max(0, cachedWarningCount - 1) }
                if entry.level >= .critical { cachedCriticalCount = max(0, cachedCriticalCount - 1) }
            }
            entries.removeLast(entries.count - maxEntries)
        }

        if batch.contains(where: { $0.level >= .critical }) {
            schedulePersistCritical()
        }

        didChange.send()
    }

    private func schedulePersistCritical() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.persistCriticalEntries()
            self?.persistTask = nil
        }
    }

    func logError(
        _ message: String,
        error: Error,
        category: DebugLogCategory = .system,
        sessionId: String? = nil,
        metadata: [String: String]? = nil
    ) {
        let nsError = error as NSError
        let detail = "[\(nsError.domain):\(nsError.code)] \(nsError.localizedDescription)"
        var enrichedMeta = metadata ?? [:]
        enrichedMeta["errorDomain"] = nsError.domain
        enrichedMeta["errorCode"] = "\(nsError.code)"
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            enrichedMeta["underlyingError"] = "[\(underlyingError.domain):\(underlyingError.code)] \(underlyingError.localizedDescription)"
        }
        if let urlError = error as? URLError {
            enrichedMeta["urlErrorCode"] = "\(urlError.code.rawValue)"
            enrichedMeta["failingURL"] = urlError.failureURLString ?? "N/A"
        }
        log(message, category: category, level: .error, detail: detail, sessionId: sessionId, metadata: enrichedMeta)
    }

    func logHealing(
        category: DebugLogCategory,
        originalError: String,
        healingAction: String,
        succeeded: Bool,
        attemptNumber: Int = 1,
        durationMs: Int? = nil,
        sessionId: String? = nil
    ) {
        let event = ErrorHealingEvent(
            timestamp: Date(),
            category: category,
            originalError: originalError,
            healingAction: healingAction,
            succeeded: succeeded,
            attemptNumber: attemptNumber,
            durationMs: durationMs
        )
        errorHealingLog.insert(event, at: 0)
        if errorHealingLog.count > 500 { errorHealingLog = Array(errorHealingLog.prefix(500)) }

        let level: DebugLogLevel = succeeded ? .success : .warning
        log(
            "HEAL [\(succeeded ? "OK" : "FAIL")] attempt #\(attemptNumber): \(healingAction)",
            category: category,
            level: level,
            detail: "Original error: \(originalError)",
            sessionId: sessionId,
            durationMs: durationMs
        )
    }

    func getRetryState(for key: String, maxAttempts: Int = 3) -> RetryState {
        if retryTracker[key] == nil {
            retryTracker[key] = RetryState(maxAttempts: maxAttempts)
        }
        return retryTracker[key]!
    }

    func recordRetryAttempt(for key: String, error: String?) {
        if retryTracker[key] == nil {
            retryTracker[key] = RetryState()
        }
        retryTracker[key]?.recordAttempt(error: error)
    }

    func resetRetryState(for key: String) {
        retryTracker[key]?.reset()
    }

    func shouldRetry(key: String) -> (shouldRetry: Bool, backoffMs: Int) {
        let state = getRetryState(for: key)
        if state.isExhausted { return (false, 0) }
        return (true, state.backoffMs)
    }

    func startTimer(key: String) {
        stepTimers[key] = Date()
    }

    func stopTimer(key: String) -> Int? {
        guard let start = stepTimers.removeValue(forKey: key) else { return nil }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    func startSession(_ sessionId: String, category: DebugLogCategory, message: String) {
        sessionTimers[sessionId] = Date()
        log(message, category: category, level: .info, sessionId: sessionId)
    }

    func endSession(_ sessionId: String, category: DebugLogCategory, message: String, level: DebugLogLevel = .info) {
        let durationMs: Int?
        if let start = sessionTimers.removeValue(forKey: sessionId) {
            durationMs = Int(Date().timeIntervalSince(start) * 1000)
        } else {
            durationMs = nil
        }
        log(message, category: category, level: level, sessionId: sessionId, durationMs: durationMs)
    }

    func clearAll() {
        entries.removeAll()
        sessionTimers.removeAll()
        stepTimers.removeAll()
        errorHealingLog.removeAll()
        retryTracker.removeAll()
        cachedErrorCount = 0
        cachedWarningCount = 0
        cachedCriticalCount = 0
        didChange.send()
    }

    func exportLogToFile() -> URL? {
        let content = exportFullLog()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = "debug_log_\(DateFormatters.exportTimestamp.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func exportDiagnosticReportToFile(credentials: [LoginCredential] = [], automationSettings: AutomationSettings? = nil) -> URL? {
        let content = exportDiagnosticReport(credentials: credentials, automationSettings: automationSettings)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = "diagnostic_report_\(DateFormatters.exportTimestamp.string(from: Date()).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: ":", with: "-")).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func exportFullLog() -> String {
        let header = """
        === DEBUG LOG EXPORT ===
        Exported: \(DebugLogEntry(category: .system, level: .info, message: "").fullTimestamp)
        Total Entries: \(entries.count)
        Errors: \(errorCount)
        Warnings: \(warningCount)
        Critical: \(criticalCount)
        Healing Events: \(errorHealingLog.count) (\(String(format: "%.0f%%", healingSuccessRate * 100)) success)
        ========================
        
        """
        let lines = entries.reversed().map(\.exportLine).joined(separator: "\n")
        return header + lines
    }

    func exportFilteredLog(
        categories: Set<DebugLogCategory>? = nil,
        minLevel: DebugLogLevel? = nil,
        sessionId: String? = nil,
        since: Date? = nil
    ) -> String {
        var filtered = entries.reversed() as [DebugLogEntry]
        if let cats = categories {
            filtered = filtered.filter { cats.contains($0.category) }
        }
        if let lvl = minLevel {
            filtered = filtered.filter { $0.level >= lvl }
        }
        if let sid = sessionId {
            filtered = filtered.filter { $0.sessionId == sid }
        }
        if let date = since {
            filtered = filtered.filter { $0.timestamp >= date }
        }
        return filtered.map(\.exportLine).joined(separator: "\n")
    }

    func exportHealingLog() -> String {
        let header = "=== ERROR HEALING LOG (\(errorHealingLog.count) events, \(String(format: "%.0f%%", healingSuccessRate * 100)) success) ===\n"
        let lines = errorHealingLog.map { event in
            let status = event.succeeded ? "OK" : "FAIL"
            let dur = event.durationMs.map { " [\($0)ms]" } ?? ""
            return "[\(DateFormatters.timeWithMillis.string(from: event.timestamp))] [\(status)] [\(event.category.rawValue)] #\(event.attemptNumber)\(dur) \(event.healingAction) | Error: \(event.originalError)"
        }.joined(separator: "\n")
        return header + lines
    }

    func entriesForSession(_ sessionId: String) -> [DebugLogEntry] {
        entries.filter { $0.sessionId == sessionId }
    }

    var uniqueSessionIds: [String] {
        let ids = entries.compactMap(\.sessionId)
        return Array(Set(ids)).sorted()
    }

    var categoryBreakdown: [(category: DebugLogCategory, count: Int)] {
        var counts: [DebugLogCategory: Int] = [:]
        for entry in entries {
            counts[entry.category, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    var levelBreakdown: [(level: DebugLogLevel, count: Int)] {
        var counts: [DebugLogLevel: Int] = [:]
        for entry in entries {
            counts[entry.level, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.level < $1.level }
    }

    func classifyNetworkError(_ error: Error) -> (code: Int, domain: String, userMessage: String, isRetryable: Bool) {
        let nsError = error as NSError
        let retryableCodes: Set<Int> = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed
        ]
        let isRetryable = nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code)
        let userMessage: String
        switch nsError.code {
        case NSURLErrorTimedOut: userMessage = "Connection timed out"
        case NSURLErrorNotConnectedToInternet: userMessage = "No internet connection"
        case NSURLErrorCannotFindHost: userMessage = "DNS resolution failed"
        case NSURLErrorCannotConnectToHost: userMessage = "Cannot connect to server"
        case NSURLErrorNetworkConnectionLost: userMessage = "Network connection lost"
        case NSURLErrorDNSLookupFailed: userMessage = "DNS lookup failed"
        case NSURLErrorSecureConnectionFailed: userMessage = "SSL/TLS handshake failed"
        default: userMessage = nsError.localizedDescription
        }
        return (nsError.code, nsError.domain, userMessage, isRetryable)
    }

    private func persistCriticalEntries() {
        let criticals = Array(entries.filter { $0.level >= .error }.prefix(200))
        if let data = try? JSONEncoder().encode(criticals) {
            UserDefaults.standard.set(data, forKey: criticalLogKey)
        }
    }

    func loadPersistedCriticalLogs() -> [DebugLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: criticalLogKey) else { return [] }
        return (try? JSONDecoder().decode([DebugLogEntry].self, from: data)) ?? []
    }

    func exportDiagnosticReport(credentials: [LoginCredential] = [], automationSettings: AutomationSettings? = nil) -> String {
        let now = DateFormatters.fullTimestamp.string(from: Date())

        var report = """
        ========================================
        DIAGNOSTIC REPORT FOR RORK MAX
        Generated: \(now)
        ========================================

        SYSTEM INFO:
        - iOS Version: \(UIDevice.current.systemVersion)
        - Device: \(UIDevice.current.model)
        - App Entries: \(entries.count)
        - Errors: \(errorCount)
        - Warnings: \(warningCount)
        - Critical: \(criticalCount)
        - Healing Success Rate: \(String(format: "%.0f%%", healingSuccessRate * 100))

        CREDENTIAL SUMMARY:
        - Total: \(credentials.count)
        - Working: \(credentials.filter { $0.status == .working }.count)
        - No Acc: \(credentials.filter { $0.status == .noAcc }.count)
        - Perm Disabled: \(credentials.filter { $0.status == .permDisabled }.count)
        - Temp Disabled: \(credentials.filter { $0.status == .tempDisabled }.count)
        - Unsure: \(credentials.filter { $0.status == .unsure }.count)
        - Untested: \(credentials.filter { $0.status == .untested }.count)

        DEBUG LOGIN BUTTON CONFIGS:
        \(debugButtonConfigSummary())

        CALIBRATION DATA:
        \(calibrationSummary())

        """

        if let settings = automationSettings {
            report += """
            AUTOMATION SETTINGS:
            - Login Button Mode: \(settings.loginButtonDetectionMode.rawValue)
            - Click Method: \(settings.loginButtonClickMethod.rawValue)
            - Max Concurrency: \(settings.maxConcurrency)
            - Stealth JS: \(settings.stealthJSInjection)
            - Fingerprint Spoof: \(settings.fingerprintSpoofing)
            - Session Isolation: \(settings.sessionIsolation.rawValue)
            - Page Load Timeout: \(Int(settings.pageLoadTimeout))s
            - Submit Retries: \(settings.submitRetryCount)
            - Max Submit Cycles: \(settings.maxSubmitCycles)
            - Pattern Learning: \(settings.patternLearningEnabled)
            - Vision ML Fallback: \(settings.fallbackToVisionMLClick)
            - Coordinate Fallback: \(settings.fallbackToCoordinateClick)
            - OCR Fallback: \(settings.fallbackToOCRClick)
            - URL Flow Assignments: \(settings.urlFlowAssignments.count)

            """
        }

        report += """
        CATEGORY BREAKDOWN:
        \(categoryBreakdown.map { "  - \($0.category.rawValue): \($0.count)" }.joined(separator: "\n"))

        LEVEL BREAKDOWN:
        \(levelBreakdown.map { "  - \($0.level.rawValue): \($0.count)" }.joined(separator: "\n"))

        ========================================
        ERROR LOG (last 100):
        ========================================
        \(entries.filter { $0.level >= .error }.prefix(100).map(\.exportLine).joined(separator: "\n"))

        ========================================
        WARNING LOG (last 50):
        ========================================
        \(entries.filter { $0.level == .warning }.prefix(50).map(\.exportLine).joined(separator: "\n"))

        ========================================
        FULL LOG (last 500):
        ========================================
        \(entries.prefix(500).map(\.exportLine).joined(separator: "\n"))

        ========================================
        HEALING LOG:
        ========================================
        \(exportHealingLog())

        ========================================
        END OF DIAGNOSTIC REPORT
        ========================================
        """

        return report
    }

    private func debugButtonConfigSummary() -> String {
        let configs = DebugLoginButtonService.shared.configs
        if configs.isEmpty { return "  No saved debug login button configs" }
        return configs.map { host, config in
            let method = config.successfulMethod?.methodName ?? "none"
            let confirmed = config.userConfirmed ? "USER" : "AUTO"
            return "  - \(host): \(method) [\(confirmed)] attempts=\(config.totalAttempts)"
        }.joined(separator: "\n")
    }

    private func calibrationSummary() -> String {
        let cals = LoginCalibrationService.shared.calibrations
        if cals.isEmpty { return "  No calibration data" }
        return cals.map { host, cal in
            let email = cal.emailField?.cssSelector ?? "none"
            let pass = cal.passwordField?.cssSelector ?? "none"
            let btn = cal.loginButton?.cssSelector ?? "none"
            return "  - \(host): email=\(email) pass=\(pass) btn=\(btn) confidence=\(String(format: "%.0f%%", cal.confidence * 100)) success=\(cal.successCount) fail=\(cal.failCount)"
        }.joined(separator: "\n")
    }
}
