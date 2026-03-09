import Foundation
import WebKit
import UIKit

@MainActor
class TrueDetectionService {
    static let shared = TrueDetectionService()

    private let logger = DebugLogger.shared

    struct TrueDetectionResult {
        var emailFilled: Bool = false
        var passwordFilled: Bool = false
        var submitTriggered: Bool = false
        var submitMethod: String = ""
        var terminalError: TerminalError?
        var attemptNumber: Int = 0
        var successValidated: Bool = false

        var overallSuccess: Bool {
            emailFilled && passwordFilled && submitTriggered
        }

        var summary: String {
            "TrueDetection[attempt:\(attemptNumber)] email:\(emailFilled) pass:\(passwordFilled) submit:\(submitTriggered) method:\(submitMethod) terminal:\(terminalError?.rawValue ?? "none")"
        }
    }

    nonisolated enum TerminalError: String, Sendable {
        case temporarilyDisabled = "temporarily_disabled"
        case accountDisabled = "account_disabled"
        case errorBanner = "error_banner"
    }

    struct TrueDetectionConfig {
        var hardPauseMs: Int = 4000
        var tripleClickDelayMs: Int = 1100
        var tripleClickCount: Int = 3
        var maxAttempts: Int = 4
        var postClickWaitMs: Int = 2500
        var cooldownMinutes: Int = 15
        var emailSelector: String = "#email"
        var passwordSelector: String = "#login-password"
        var submitSelector: String = "#login-submit"
        var successMarkers: [String] = ["balance", "wallet", "my account", "logout"]
        var terminalKeywords: [String] = ["temporarily disabled", "account is disabled"]
        var errorBannerSelectors: [String] = [".error-banner", ".alert-danger"]
    }

    private var cooldownAccounts: [String: Date] = [:]

    func isOnCooldown(account: String) -> Bool {
        guard let cooldownUntil = cooldownAccounts[account] else { return false }
        return Date() < cooldownUntil
    }

    func setCooldown(account: String, minutes: Int) {
        cooldownAccounts[account] = Date().addingTimeInterval(TimeInterval(minutes * 60))
    }

    func clearCooldown(account: String) {
        cooldownAccounts.removeValue(forKey: account)
    }

    func runFullTrueDetectionSequence(
        session: LoginSiteWebSession,
        username: String,
        password: String,
        config: TrueDetectionConfig = .init(),
        sessionId: String = "",
        onLog: ((String, PPSRLogEntry.Level) -> Void)? = nil
    ) async -> TrueDetectionResult {
        var finalResult = TrueDetectionResult()

        if isOnCooldown(account: username) {
            onLog?("TRUE DETECTION: Account '\(username)' is on cooldown — skipping", .warning)
            logger.log("TrueDetection: account on cooldown, skipping", category: .automation, level: .warning, sessionId: sessionId)
            finalResult.terminalError = .temporarilyDisabled
            return finalResult
        }

        for attempt in 1...config.maxAttempts {
            finalResult.attemptNumber = attempt
            onLog?("TRUE DETECTION: Attempt \(attempt)/\(config.maxAttempts)", .info)
            logger.log("TrueDetection: attempt \(attempt)/\(config.maxAttempts)", category: .automation, level: .info, sessionId: sessionId)

            let stepResult = await executeTrueDetectionStep(
                session: session,
                username: username,
                password: password,
                config: config,
                attempt: attempt,
                sessionId: sessionId,
                onLog: onLog
            )

            finalResult.emailFilled = stepResult.emailFilled
            finalResult.passwordFilled = stepResult.passwordFilled
            finalResult.submitTriggered = stepResult.submitTriggered
            finalResult.submitMethod = stepResult.submitMethod

            if let terminal = stepResult.terminalError {
                finalResult.terminalError = terminal
                onLog?("TRUE DETECTION: TERMINAL ERROR — \(terminal.rawValue) on attempt \(attempt)", .error)
                logger.log("TrueDetection: TERMINAL \(terminal.rawValue)", category: .automation, level: .critical, sessionId: sessionId)
                setCooldown(account: username, minutes: config.cooldownMinutes)
                return finalResult
            }

            if stepResult.submitTriggered {
                try? await Task.sleep(for: .milliseconds(config.postClickWaitMs))

                let validated = await validateSuccess(session: session, config: config, sessionId: sessionId, onLog: onLog)
                finalResult.successValidated = validated
                if validated {
                    onLog?("TRUE DETECTION: SUCCESS VALIDATED on attempt \(attempt)", .success)
                    logger.log("TrueDetection: SUCCESS on attempt \(attempt)", category: .automation, level: .success, sessionId: sessionId)
                    return finalResult
                }

                let terminalCheck = await checkTerminalErrors(session: session, config: config, sessionId: sessionId, onLog: onLog)
                if let terminal = terminalCheck {
                    finalResult.terminalError = terminal
                    setCooldown(account: username, minutes: config.cooldownMinutes)
                    return finalResult
                }

                onLog?("TRUE DETECTION: Attempt \(attempt) — submit triggered but no success markers found", .warning)
            }

            if attempt < config.maxAttempts {
                let backoff = 2000 * attempt
                onLog?("TRUE DETECTION: Waiting \(backoff)ms before retry...", .info)
                try? await Task.sleep(for: .milliseconds(backoff))
            }
        }

        onLog?("TRUE DETECTION: All \(config.maxAttempts) attempts exhausted", .error)
        return finalResult
    }

    private func executeTrueDetectionStep(
        session: LoginSiteWebSession,
        username: String,
        password: String,
        config: TrueDetectionConfig,
        attempt: Int,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> TrueDetectionResult {
        var result = TrueDetectionResult()
        result.attemptNumber = attempt

        let domReady = await waitForDOMComplete(session: session, timeout: 10, sessionId: sessionId)
        if !domReady {
            onLog?("TRUE DETECTION: DOM not ready after 10s", .warning)
        }

        onLog?("TRUE DETECTION: Hard pause \(config.hardPauseMs)ms before interaction...", .info)
        logger.log("TrueDetection: hard pause \(config.hardPauseMs)ms", category: .automation, level: .trace, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(config.hardPauseMs))

        let emailResult = await fillHardcodedField(
            session: session,
            selector: config.emailSelector,
            value: username,
            fieldName: "email",
            sessionId: sessionId,
            onLog: onLog
        )
        result.emailFilled = emailResult
        if !emailResult {
            onLog?("TRUE DETECTION: Email fill FAILED on \(config.emailSelector)", .error)
            return result
        }
        onLog?("TRUE DETECTION: Email filled via \(config.emailSelector)", .success)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 300...600)))

        let passwordResult = await fillHardcodedField(
            session: session,
            selector: config.passwordSelector,
            value: password,
            fieldName: "password",
            sessionId: sessionId,
            onLog: onLog
        )
        result.passwordFilled = passwordResult
        if !passwordResult {
            onLog?("TRUE DETECTION: Password fill FAILED on \(config.passwordSelector)", .error)
            return result
        }
        onLog?("TRUE DETECTION: Password filled via \(config.passwordSelector)", .success)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 300...600)))

        let submitResult = await tripleClickSubmit(
            session: session,
            selector: config.submitSelector,
            clickCount: config.tripleClickCount,
            delayMs: config.tripleClickDelayMs,
            sessionId: sessionId,
            onLog: onLog
        )
        result.submitTriggered = submitResult.success
        result.submitMethod = submitResult.method

        return result
    }

    private func waitForDOMComplete(session: LoginSiteWebSession, timeout: TimeInterval, sessionId: String) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let ready = await session.executeJS("document.readyState")
            if ready == "complete" {
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    private func fillHardcodedField(
        session: LoginSiteWebSession,
        selector: String,
        value: String,
        fieldName: String,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedSelector = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let js = """
        (function() {
            var el = document.querySelector('\(escapedSelector)');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeSetter && nativeSetter.set) {
                nativeSetter.set.call(el, '');
            } else {
                el.value = '';
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (nativeSetter && nativeSetter.set) {
                nativeSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """

        let result = await session.executeJS(js)
        logger.log("TrueDetection: fill \(fieldName) via \(selector) → \(result ?? "nil")", category: .automation, level: result == "OK" ? .success : .warning, sessionId: sessionId)

        if result == "OK" || result == "VALUE_MISMATCH" {
            return true
        }
        return false
    }

    private func tripleClickSubmit(
        session: LoginSiteWebSession,
        selector: String,
        clickCount: Int,
        delayMs: Int,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> (success: Bool, method: String) {
        let escapedSelector = selector
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let checkJS = """
        (function() {
            var btn = document.querySelector('\(escapedSelector)');
            if (!btn) return 'NOT_FOUND';
            return 'FOUND:' + (btn.textContent || '').trim().substring(0, 30);
        })();
        """
        let checkResult = await session.executeJS(checkJS)
        guard let checkResult, checkResult.hasPrefix("FOUND") else {
            onLog?("TRUE DETECTION: Submit button NOT_FOUND at \(selector)", .error)
            logger.log("TrueDetection: submit button NOT_FOUND at \(selector)", category: .automation, level: .error, sessionId: sessionId)
            return (false, "NOT_FOUND")
        }

        onLog?("TRUE DETECTION: Starting triple-click on \(selector) (\(clickCount) clicks, \(delayMs)ms apart)", .info)

        for i in 0..<clickCount {
            let clickJS = """
            (function() {
                var btn = document.querySelector('\(escapedSelector)');
                if (!btn) return 'NOT_FOUND';
                btn.scrollIntoView({behavior: 'instant', block: 'center'});
                var rect = btn.getBoundingClientRect();
                var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
                var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);

                btn.dispatchEvent(new PointerEvent('pointerdown', {
                    bubbles: true, cancelable: true, view: window,
                    clientX: cx, clientY: cy, pointerId: 1, pointerType: 'mouse',
                    button: 0, buttons: 1
                }));
                btn.dispatchEvent(new MouseEvent('mousedown', {
                    bubbles: true, cancelable: true, view: window,
                    clientX: cx, clientY: cy, button: 0, buttons: 1
                }));
                btn.dispatchEvent(new PointerEvent('pointerup', {
                    bubbles: true, cancelable: true, view: window,
                    clientX: cx, clientY: cy, pointerId: 1, pointerType: 'mouse', button: 0
                }));
                btn.dispatchEvent(new MouseEvent('mouseup', {
                    bubbles: true, cancelable: true, view: window,
                    clientX: cx, clientY: cy, button: 0
                }));
                btn.dispatchEvent(new MouseEvent('click', {
                    bubbles: true, cancelable: true, view: window,
                    clientX: cx, clientY: cy, button: 0
                }));
                btn.click();
                return 'CLICKED_' + \(i);
            })();
            """
            let clickResult = await session.executeJS(clickJS)
            onLog?("TRUE DETECTION: Click \(i + 1)/\(clickCount) → \(clickResult ?? "nil")", .info)
            logger.log("TrueDetection: triple-click \(i + 1)/\(clickCount) → \(clickResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)

            if i < clickCount - 1 {
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }

        return (true, "TRIPLE_CLICK_\(selector)")
    }

    func validateSuccess(
        session: LoginSiteWebSession,
        config: TrueDetectionConfig,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> Bool {
        let pageContent = await session.getPageContent()
        let contentLower = pageContent.lowercased()

        for marker in config.successMarkers {
            if contentLower.contains(marker.lowercased()) {
                onLog?("TRUE DETECTION: Success marker found — '\(marker)'", .success)
                logger.log("TrueDetection: success marker '\(marker)' found", category: .evaluation, level: .success, sessionId: sessionId)
                return true
            }
        }

        let currentURL = await session.getCurrentURL()
        let urlLower = currentURL.lowercased()
        if !urlLower.contains("/login") && !urlLower.contains("/signin") {
            let redirectMarkers = ["dashboard", "lobby", "cashier", "account", "home"]
            for marker in redirectMarkers {
                if urlLower.contains(marker) {
                    onLog?("TRUE DETECTION: Redirect to '\(marker)' page detected", .success)
                    return true
                }
            }
        }

        onLog?("TRUE DETECTION: No success markers found in page content", .warning)
        return false
    }

    private func checkTerminalErrors(
        session: LoginSiteWebSession,
        config: TrueDetectionConfig,
        sessionId: String,
        onLog: ((String, PPSRLogEntry.Level) -> Void)?
    ) async -> TerminalError? {
        let pageContent = await session.getPageContent()
        let contentLower = pageContent.lowercased()

        for keyword in config.terminalKeywords {
            if contentLower.contains(keyword.lowercased()) {
                onLog?("TRUE DETECTION: TERMINAL keyword detected — '\(keyword)'", .error)
                logger.log("TrueDetection: TERMINAL keyword '\(keyword)'", category: .evaluation, level: .critical, sessionId: sessionId)
                if keyword.contains("temporarily") {
                    return .temporarilyDisabled
                }
                return .accountDisabled
            }
        }

        for bannerSelector in config.errorBannerSelectors {
            let escaped = bannerSelector.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.querySelector('\(escaped)');
                if (!el) return 'NOT_FOUND';
                var text = (el.textContent || '').trim();
                var visible = el.offsetParent !== null || el.offsetHeight > 0;
                if (!visible) return 'NOT_VISIBLE';
                return 'BANNER:' + text.substring(0, 200);
            })();
            """
            let result = await session.executeJS(js)
            if let result, result.hasPrefix("BANNER:") {
                let bannerText = String(result.dropFirst(7))
                onLog?("TRUE DETECTION: Error banner detected — '\(bannerText)'", .error)
                logger.log("TrueDetection: error banner '\(bannerText)'", category: .evaluation, level: .critical, sessionId: sessionId)
                return .errorBanner
            }
        }

        return nil
    }

    func captureErrorBannerCrop(
        session: LoginSiteWebSession,
        config: TrueDetectionConfig
    ) async -> UIImage? {
        guard let fullScreenshot = await session.captureScreenshot() else { return nil }
        guard let webView = session.webView else { return fullScreenshot }

        for bannerSelector in config.errorBannerSelectors {
            let escaped = bannerSelector.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.querySelector('\(escaped)');
                if (!el || el.offsetParent === null) return null;
                var rect = el.getBoundingClientRect();
                return JSON.stringify({x: rect.left, y: rect.top, w: rect.width, h: rect.height});
            })();
            """
            if let result = await session.executeJS(js),
               let data = result.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
               let x = json["x"], let y = json["y"], let w = json["w"], let h = json["h"],
               w > 10, h > 10 {

                let viewSize = webView.bounds.size
                guard let cgImage = fullScreenshot.cgImage else { return fullScreenshot }
                let imageW = CGFloat(cgImage.width)
                let imageH = CGFloat(cgImage.height)
                let scaleX = imageW / viewSize.width
                let scaleY = imageH / viewSize.height

                let padding: CGFloat = 10
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
        }

        return fullScreenshot
    }
}
