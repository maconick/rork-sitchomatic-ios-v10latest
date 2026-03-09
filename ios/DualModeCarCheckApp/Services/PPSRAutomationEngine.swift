import Foundation
import UIKit

nonisolated enum CheckOutcome: Sendable {
    case pass
    case failInstitution
    case uncertain
    case connectionFailure
    case timeout
}

@MainActor
class PPSRAutomationEngine {
    private var activeSessions: Int = 0
    let maxConcurrency: Int = 8
    var debugMode: Bool = false
    var stealthEnabled: Bool = false
    var retrySubmitOnFail: Bool = false
    var screenshotCropRect: CGRect = .zero
    private let logger = DebugLogger.shared
    var onScreenshot: ((PPSRDebugScreenshot) -> Void)?
    var onConnectionFailure: ((String) -> Void)?
    var onUnusualFailure: ((String) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var onBlankScreenshot: (() -> Void)?
    private let dohService = PPSRDoHService.shared

    var canStartSession: Bool {
        activeSessions < maxConcurrency
    }

    func runCheck(_ check: PPSRCheck, timeout: TimeInterval = 30) async -> CheckOutcome {
        activeSessions += 1
        defer { activeSessions -= 1 }

        let sessionId = "ppsr_\(check.card.displayNumber.suffix(8))_\(UUID().uuidString.prefix(6))"
        check.startedAt = Date()

        logger.startSession(sessionId, category: .ppsr, message: "Starting PPSR check for \(check.card.brand) \(check.card.displayNumber)")
        logger.log("Config: timeout=\(Int(timeout))s stealth=\(stealthEnabled) retrySubmit=\(retrySubmitOnFail) VIN=\(check.vin) email=\(check.email)", category: .ppsr, level: .debug, sessionId: sessionId)

        let session = LoginWebSession()
        session.stealthEnabled = stealthEnabled
        session.onFingerprintLog = { [weak self] msg, level in
            check.logs.append(PPSRLogEntry(message: msg, level: level))
            self?.onLog?(msg, level)
            let debugLevel: DebugLogLevel = level == .error ? .error : level == .warning ? .warning : .trace
            self?.logger.log(msg, category: .fingerprint, level: debugLevel, sessionId: sessionId)
        }
        session.setUp()
        defer {
            session.tearDown()
            logger.log("WebView session tearDown", category: .webView, level: .trace, sessionId: sessionId)
        }

        logger.startTimer(key: sessionId)
        let outcome: CheckOutcome = await withTaskGroup(of: CheckOutcome.self) { group in
            group.addTask {
                return await self.performCheck(session: session, check: check, sessionId: sessionId)
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
            check.status = .failed
            check.errorMessage = "Test timed out after \(Int(timeout))s — auto-requeuing"
            check.completedAt = Date()
            check.logs.append(PPSRLogEntry(message: "TIMEOUT: Test exceeded \(Int(timeout))s limit", level: .warning))
            logger.log("TIMEOUT after \(Int(timeout))s for \(check.card.displayNumber)", category: .ppsr, level: .error, sessionId: sessionId, durationMs: totalMs)
            onUnusualFailure?("Timeout for \(check.card.displayNumber) after \(Int(timeout))s")
        }

        if outcome == .connectionFailure {
            logger.log("CONNECTION FAILURE for \(check.card.displayNumber)", category: .network, level: .error, sessionId: sessionId, durationMs: totalMs)
            onUnusualFailure?("Connection failure for \(check.card.displayNumber)")
        }

        logger.endSession(sessionId, category: .ppsr, message: "PPSR check COMPLETE: \(outcome) for \(check.card.displayNumber)", level: outcome == .pass ? .success : outcome == .failInstitution ? .warning : .error)

        return outcome
    }

    private func performCheck(session: LoginWebSession, check: PPSRCheck, sessionId: String = "") async -> CheckOutcome {
        advanceTo(.fillingVIN, check: check, message: "Loading PPSR CarCheck: \(LoginWebSession.targetURL.absoluteString)")
        logger.log("Phase: LOAD PPSR PAGE", category: .automation, level: .info, sessionId: sessionId)

        if stealthEnabled {
            await performDoHPreflight(check: check, sessionId: sessionId)
        }

        var loaded = false
        for attempt in 1...3 {
            logger.startTimer(key: "\(sessionId)_pageload_\(attempt)")
            loaded = await session.loadPage(timeout: 30)
            let loadMs = logger.stopTimer(key: "\(sessionId)_pageload_\(attempt)")
            if loaded {
                logger.log("Page load attempt \(attempt)/3 SUCCESS", category: .webView, level: .success, sessionId: sessionId, durationMs: loadMs)
                break
            }
            let errorDetail = session.lastNavigationError ?? "unknown error"
            logger.log("Page load attempt \(attempt)/3 FAILED: \(errorDetail)", category: .webView, level: .warning, sessionId: sessionId, durationMs: loadMs)
            check.logs.append(PPSRLogEntry(message: "Page load attempt \(attempt)/3 failed — \(errorDetail)", level: .warning))
            if attempt < 3 {
                let waitTime = Double(attempt) * 2
                check.logs.append(PPSRLogEntry(message: "Healing: waiting \(Int(waitTime))s before retry...", level: .info))
                try? await Task.sleep(for: .seconds(waitTime))
                if attempt == 2 {
                    logger.log("Full session reset before final attempt", category: .webView, level: .debug, sessionId: sessionId)
                    session.tearDown()
                    session.stealthEnabled = stealthEnabled
                    session.setUp()
                }
            }
        }

        guard loaded else {
            let errorDetail = session.lastNavigationError ?? "Unknown error"
            logger.log("FATAL: PPSR page load failed after 3 attempts — \(errorDetail)", category: .network, level: .critical, sessionId: sessionId)
            failCheck(check, message: "FATAL: Failed to load PPSR page after 3 attempts — \(errorDetail)")
            await captureScreenshotForCheck(session: session, check: check, step: "page_load_failed", note: "Page failed to load", autoResult: .unknown)
            onConnectionFailure?("Page load failed: \(errorDetail)")
            return .connectionFailure
        }

        let pageTitle = await session.getPageTitle()
        check.logs.append(PPSRLogEntry(message: "Page loaded: \"\(pageTitle)\"", level: .info))
        logger.log("Page title: \"\(pageTitle)\"", category: .webView, level: .debug, sessionId: sessionId)

        if let initialScreenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, BlankScreenshotDetector.isBlank(initialScreenshot) {
            check.logs.append(PPSRLogEntry(message: "BLANK PAGE after load — requeuing for auto-retry", level: .warning))
            logger.log("BLANK PAGE detected after load for \(check.card.displayNumber)", category: .screenshot, level: .error, sessionId: sessionId)
            failCheck(check, message: "Blank page on load — auto-retry scheduled")
            await captureScreenshotForCheck(session: session, check: check, step: "blank_page_load", note: "BLANK PAGE — auto-retry", autoResult: .unknown)
            onBlankScreenshot?()
            onUnusualFailure?("Blank page for \(check.card.displayNumber) — requeuing")
            return .connectionFailure
        }

        logger.startTimer(key: "\(sessionId)_appready")
        check.logs.append(PPSRLogEntry(message: "Waiting for PPSR app to fully initialize (detecting loading screens)...", level: .info))
        let appReady = await session.waitForAppReady(timeout: 25)
        let readyMs = logger.stopTimer(key: "\(sessionId)_appready")
        logger.log("App readiness: ready=\(appReady.ready) fields=\(appReady.fieldsFound) — \(appReady.detail)", category: .automation, level: appReady.ready ? .success : .warning, sessionId: sessionId, durationMs: readyMs)
        check.logs.append(PPSRLogEntry(message: "App readiness: \(appReady.detail)", level: appReady.ready ? .success : .warning))

        if !appReady.ready && appReady.fieldsFound == 0 {
            check.logs.append(PPSRLogEntry(message: "Healing: dumping page structure for diagnostics...", level: .info))
            let structure = await session.dumpPageStructure()
            logger.log("Page structure dump: \(structure.prefix(500))", category: .automation, level: .debug, sessionId: sessionId)
            check.logs.append(PPSRLogEntry(message: "Page structure: \(structure.prefix(300))", level: .warning))

            check.logs.append(PPSRLogEntry(message: "Healing: reloading page and waiting again...", level: .info))
            let reloaded = await session.loadPage(timeout: 30)
            if reloaded {
                let retryReady = await session.waitForAppReady(timeout: 20)
                logger.log("Retry app readiness: ready=\(retryReady.ready) fields=\(retryReady.fieldsFound)", category: .automation, level: retryReady.ready ? .success : .warning, sessionId: sessionId)
                check.logs.append(PPSRLogEntry(message: "Retry readiness: \(retryReady.detail)", level: retryReady.ready ? .success : .warning))

                if !retryReady.ready && retryReady.fieldsFound == 0 {
                    failCheck(check, message: "FATAL: No form fields found after reload and extended wait")
                    await captureScreenshotForCheck(session: session, check: check, step: "no_fields", note: "No fields after reload", autoResult: .fail)
                    return .connectionFailure
                }
            } else {
                failCheck(check, message: "FATAL: Page reload also failed")
                await captureScreenshotForCheck(session: session, check: check, step: "reload_failed", note: "Reload failed", autoResult: .fail)
                return .connectionFailure
            }
        }

        logger.startTimer(key: "\(sessionId)_fieldverify")
        let verification = await session.verifyFieldsExist()
        let fieldMs = logger.stopTimer(key: "\(sessionId)_fieldverify")
        logger.log("Final field verification: \(verification.found)/6 found", category: .automation, level: verification.found >= 4 ? .debug : .warning, sessionId: sessionId, durationMs: fieldMs)
        if verification.found < 6 {
            check.logs.append(PPSRLogEntry(message: "Field scan: \(verification.found)/6 found. Missing: [\(verification.missing.joined(separator: ", "))]", level: verification.found >= 4 ? .info : .warning))
        } else {
            check.logs.append(PPSRLogEntry(message: "All 6 form fields verified present and enabled", level: .success))
        }

        logger.log("Phase: FILL FORM FIELDS", category: .automation, level: .info, sessionId: sessionId)
        advanceTo(.fillingVIN, check: check, message: "Filling VIN: \(check.vin)")
        let vinResult = await retryFill(session: session, check: check, fieldName: "VIN") {
            await session.fillVIN(check.vin)
        }
        guard vinResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(300))

        advanceTo(.submittingSearch, check: check, message: "Filling email: \(check.email)")
        let emailResult = await retryFill(session: session, check: check, fieldName: "Email") {
            await session.fillEmail(check.email)
        }
        guard emailResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(300))

        logger.log("Phase: FILL PAYMENT", category: .automation, level: .info, sessionId: sessionId)
        advanceTo(.enteringPayment, check: check, message: "Filling card: \(check.card.brand) \(check.card.displayNumber)")
        let cardResult = await retryFill(session: session, check: check, fieldName: "Card Number") {
            await session.fillCardNumber(check.card.number)
        }
        guard cardResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(200))

        let monthResult = await retryFill(session: session, check: check, fieldName: "Exp Month") {
            await session.fillExpMonth(check.expiryMonth)
        }
        guard monthResult else { return .connectionFailure }

        let yearResult = await retryFill(session: session, check: check, fieldName: "Exp Year") {
            await session.fillExpYear(check.expiryYear)
        }
        guard yearResult else { return .connectionFailure }

        let cvvResult = await retryFill(session: session, check: check, fieldName: "CVV") {
            await session.fillCVV(check.cvv)
        }
        guard cvvResult else { return .connectionFailure }
        try? await Task.sleep(for: .milliseconds(500))

        logger.log("Phase: SUBMIT", category: .automation, level: .info, sessionId: sessionId)
        advanceTo(.processingPayment, check: check, message: "Clicking 'Show My Results' button")
        var submitResult: (success: Bool, detail: String) = (false, "")
        for attempt in 1...3 {
            logger.startTimer(key: "\(sessionId)_submit_\(attempt)")
            submitResult = await session.clickShowMyResults()
            let submitMs = logger.stopTimer(key: "\(sessionId)_submit_\(attempt)")
            if submitResult.success {
                check.logs.append(PPSRLogEntry(message: "Submit: \(submitResult.detail)", level: .success))
                logger.log("Submit attempt \(attempt): SUCCESS — \(submitResult.detail)", category: .automation, level: .success, sessionId: sessionId, durationMs: submitMs)
                break
            }
            check.logs.append(PPSRLogEntry(message: "Submit attempt \(attempt)/3 failed: \(submitResult.detail)", level: .warning))
            logger.log("Submit attempt \(attempt)/3 FAILED: \(submitResult.detail)", category: .automation, level: .warning, sessionId: sessionId, durationMs: submitMs)
            if attempt < 3 {
                try? await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
        guard submitResult.success else {
            failCheck(check, message: "SUBMIT FAILED after 3 attempts: \(submitResult.detail)")
            await captureScreenshotForCheck(session: session, check: check, step: "submit_failed", note: "Submit failed", autoResult: .fail)
            return .connectionFailure
        }

        let navigated = await session.waitForNavigation(timeout: 10)
        if !navigated {
            check.logs.append(PPSRLogEntry(message: "Page did not navigate after submit — checking content anyway", level: .warning))
        }
        try? await Task.sleep(for: .seconds(1))

        if let postSubmitScreenshot = await session.captureScreenshotWithCrop(cropRect: nil).full, BlankScreenshotDetector.isBlank(postSubmitScreenshot) {
            check.logs.append(PPSRLogEntry(message: "BLANK SCREENSHOT after submit — requeuing for auto-retry", level: .warning))
            logger.log("BLANK SCREENSHOT after submit for \(check.card.displayNumber)", category: .screenshot, level: .error, sessionId: sessionId)
            failCheck(check, message: "Blank screenshot after submit — auto-retry scheduled")
            await captureScreenshotForCheck(session: session, check: check, step: "blank_post_submit", note: "BLANK PAGE after submit — auto-retry", autoResult: .unknown)
            onBlankScreenshot?()
            onUnusualFailure?("Blank screenshot after submit for \(check.card.displayNumber) — requeuing")
            return .connectionFailure
        }

        var pageContent = await session.getPageContent()
        var contentLower = pageContent.lowercased()

        let evaluation = evaluatePPSRResponse(contentLower: contentLower, pageContent: pageContent)

        if retrySubmitOnFail && evaluation.outcome == .uncertain {
            check.logs.append(PPSRLogEntry(message: "Retry Submit: no clear result — retrying...", level: .warning))
            let retrySubmit = await session.clickShowMyResults()
            if retrySubmit.success {
                let retryNav = await session.waitForNavigation(timeout: 10)
                if !retryNav {
                    check.logs.append(PPSRLogEntry(message: "Retry: page did not navigate", level: .warning))
                }
                try? await Task.sleep(for: .seconds(1))
                pageContent = await session.getPageContent()
                contentLower = pageContent.lowercased()
            }
        }

        let finalEvaluation = evaluatePPSRResponse(contentLower: contentLower, pageContent: pageContent)
        check.responseSnippet = String(pageContent.prefix(500))
        logger.log("PPSR evaluation: \(finalEvaluation.outcome) score=\(finalEvaluation.score) — \(finalEvaluation.reason)", category: .evaluation, level: finalEvaluation.outcome == .pass ? .success : .warning, sessionId: sessionId)

        let autoResult: PPSRDebugScreenshot.AutoDetectedResult
        switch finalEvaluation.outcome {
        case .failInstitution: autoResult = .fail
        case .pass: autoResult = .pass
        default: autoResult = .unknown
        }

        await captureScreenshotForCheck(session: session, check: check, step: "post_submit_result", note: "Score: \(finalEvaluation.score) | \(finalEvaluation.reason)", autoResult: autoResult)

        advanceTo(.confirmingReport, check: check, message: "Evaluating PPSR response...")

        check.logs.append(PPSRLogEntry(
            message: "Evaluation: \(finalEvaluation.outcome) (score: \(finalEvaluation.score)) — \(finalEvaluation.reason)",
            level: finalEvaluation.outcome == .pass ? .success : finalEvaluation.outcome == .uncertain ? .warning : .error
        ))

        switch finalEvaluation.outcome {
        case .failInstitution:
            let snippet = extractRelevantSnippet(from: pageContent, around: "institution")
            failCheck(check, message: "Institution detected: \"\(snippet)\"")
            return .failInstitution

        case .pass:
            advanceTo(.completed, check: check, message: "PASS — \(finalEvaluation.reason)")
            check.completedAt = Date()
            return .pass

        default:
            check.status = .failed
            check.errorMessage = "Uncertain result — \(finalEvaluation.reason). Auto-requeuing."
            check.completedAt = Date()
            let snippet = String(pageContent.prefix(200))
            onUnusualFailure?("Unusual result for \(check.card.displayNumber): \(snippet)")
            return .uncertain
        }
    }

    // MARK: - Weighted PPSR Evaluation

    private struct PPSREvaluation {
        let outcome: CheckOutcome
        let score: Int
        let reason: String
    }

    private func evaluatePPSRResponse(contentLower: String, pageContent: String) -> PPSREvaluation {
        var failScore: Int = 0
        var passScore: Int = 0
        var failSignals: [String] = []
        var passSignals: [String] = []

        let strongFailTerms: [(String, Int)] = [
            ("financial institution", 50),
            ("institution has declined", 50),
            ("payment declined", 40),
            ("card declined", 40),
            ("transaction declined", 40),
            ("payment was declined", 45),
            ("unable to process payment", 35),
            ("payment could not be processed", 35),
            ("insufficient funds", 30),
            ("card has been declined", 45),
            ("do not honour", 35),
            ("expired card", 30),
            ("invalid card", 35),
            ("lost card", 30),
            ("stolen card", 30),
        ]
        for (term, weight) in strongFailTerms {
            if contentLower.contains(term) {
                failScore += weight
                failSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakFailTerms: [(String, Int)] = [
            ("institution", 20),
            ("declined", 15),
            ("error processing", 12),
            ("payment error", 12),
            ("card error", 12),
        ]
        for (term, weight) in weakFailTerms {
            if contentLower.contains(term) {
                failScore += weight
                failSignals.append("+\(weight) '\(term)'")
            }
        }

        let strongPassTerms: [(String, Int)] = [
            ("vehicle searched", 50),
            ("search results", 30),
            ("ppsr certificate", 40),
            ("certificate number", 35),
            ("no encumbrances", 40),
            ("no security interests", 35),
            ("report generated", 30),
            ("search complete", 35),
            ("your results", 25),
        ]
        for (term, weight) in strongPassTerms {
            if contentLower.contains(term) {
                passScore += weight
                passSignals.append("+\(weight) '\(term)'")
            }
        }

        let weakPassTerms: [(String, Int)] = [
            ("search", 5),
            ("result", 5),
            ("report", 5),
            ("confirmation", 8),
            ("receipt", 10),
            ("thank you", 8),
        ]
        for (term, weight) in weakPassTerms {
            if contentLower.contains(term) {
                passScore += weight
                passSignals.append("+\(weight) '\(term)'")
            }
        }

        let passThreshold = 25
        let failThreshold = 20

        if failScore >= failThreshold && failScore > passScore {
            let topSignals = failSignals.prefix(3).joined(separator: ", ")
            return PPSREvaluation(outcome: .failInstitution, score: failScore, reason: "Institution/declined [\(topSignals)]")
        }

        if passScore >= passThreshold && passScore > failScore {
            let topSignals = passSignals.prefix(3).joined(separator: ", ")
            return PPSREvaluation(outcome: .pass, score: passScore, reason: "Vehicle searched [\(topSignals)]")
        }

        let snippet = String(pageContent.prefix(150)).replacingOccurrences(of: "\n", with: " ")
        return PPSREvaluation(outcome: .uncertain, score: max(failScore, passScore), reason: "No clear signals (pass:\(passScore) fail:\(failScore)) \"\(snippet)\"")
    }

    // MARK: - Helpers

    private func retryFill(
        session: LoginWebSession,
        check: PPSRCheck,
        fieldName: String,
        fill: () async -> (success: Bool, detail: String)
    ) async -> Bool {
        for attempt in 1...3 {
            let result = await fill()
            if result.success {
                check.logs.append(PPSRLogEntry(message: "\(fieldName): \(result.detail)", level: .success))
                return true
            }
            check.logs.append(PPSRLogEntry(message: "\(fieldName) attempt \(attempt)/3 FAILED: \(result.detail)", level: .warning))
            if attempt < 3 {
                try? await Task.sleep(for: .milliseconds(Double(attempt) * 500))
            }
        }
        failCheck(check, message: "\(fieldName) FILL FAILED after 3 attempts")
        return false
    }

    private func advanceTo(_ status: PPSRCheckStatus, check: PPSRCheck, message: String) {
        check.status = status
        check.logs.append(PPSRLogEntry(message: message, level: status == .completed ? .success : .info))
    }

    private func failCheck(_ check: PPSRCheck, message: String) {
        check.status = .failed
        check.errorMessage = message
        check.completedAt = Date()
        check.logs.append(PPSRLogEntry(message: "ERROR: \(message)", level: .error))
    }

    private func captureScreenshotForCheck(session: LoginWebSession, check: PPSRCheck, step: String, note: String, autoResult: PPSRDebugScreenshot.AutoDetectedResult = .unknown) async {
        let cropRect = screenshotCropRect == .zero ? nil : screenshotCropRect
        let result = await session.captureScreenshotWithCrop(cropRect: cropRect)
        guard let fullImage = result.full else { return }

        check.responseSnapshot = fullImage


        let compressed: UIImage
        if let jpegData = fullImage.jpegData(compressionQuality: 0.3), let ci = UIImage(data: jpegData) {
            compressed = ci
        } else {
            compressed = fullImage
        }
        var compressedCrop: UIImage?
        if let cropped = result.cropped, let jpegData = cropped.jpegData(compressionQuality: 0.4), let ci = UIImage(data: jpegData) {
            compressedCrop = ci
        }
        let screenshot = PPSRDebugScreenshot(
            stepName: step, cardDisplayNumber: check.card.displayNumber, cardId: check.card.id,
            vin: check.vin, email: check.email, image: compressed, croppedImage: compressedCrop,
            note: note, autoDetectedResult: autoResult
        )
        check.screenshotIds.append(screenshot.id)
        onScreenshot?(screenshot)
    }

    private func performDoHPreflight(check: PPSRCheck, sessionId: String = "") async {
        guard let host = LoginWebSession.targetURL.host else { return }
        let provider = dohService.currentProvider
        check.logs.append(PPSRLogEntry(message: "DoH preflight: resolving \(host) via \(provider.name)", level: .info))
        logger.log("DoH preflight: resolving \(host) via \(provider.name)", category: .dns, level: .debug, sessionId: sessionId)
        if let result = await dohService.preflightResolve(hostname: host) {
            check.logs.append(PPSRLogEntry(message: "DoH resolved: \(result.ip) via \(result.provider) in \(result.latencyMs)ms", level: .success))
            logger.log("DoH resolved: \(result.ip) via \(result.provider)", category: .dns, level: .success, sessionId: sessionId, durationMs: result.latencyMs)
        } else {
            check.logs.append(PPSRLogEntry(message: "DoH preflight failed — falling back to system DNS", level: .warning))
            logger.log("DoH preflight FAILED — falling back to system DNS", category: .dns, level: .warning, sessionId: sessionId)
        }
    }

    private func extractRelevantSnippet(from content: String, around keyword: String) -> String {
        let lower = content.lowercased()
        guard let range = lower.range(of: keyword) else {
            return String(content.prefix(200))
        }
        let idx = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let start = max(0, idx - 50)
        let end = min(content.count, idx + 150)
        let startIdx = content.index(content.startIndex, offsetBy: start)
        let endIdx = content.index(content.startIndex, offsetBy: end)
        return String(content[startIdx..<endIdx])
    }
}
