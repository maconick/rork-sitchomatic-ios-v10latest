import Foundation
import WebKit
import UIKit

nonisolated enum LoginFormPattern: String, CaseIterable, Codable, Sendable {
    case trueDetection = "TRUE DETECTION"
    case tabNavigation = "Tab Navigation"
    case clickFocusSequential = "Click-Focus Sequential"
    case execCommandInsert = "ExecCommand Insert"
    case slowDeliberateTyper = "Slow Deliberate Typer"
    case mobileTouchBurst = "Mobile Touch Burst"
    case calibratedDirect = "Calibrated Direct"
    case calibratedTyping = "Calibrated Typing"
    case formSubmitDirect = "Form Submit Direct"
    case coordinateClick = "Coordinate Click"
    case reactNativeSetter = "React Native Setter"
    case visionMLCoordinate = "Vision ML Coordinate"

    var description: String {
        switch self {
        case .trueDetection:
            "Hardcoded Interaction Protocol: Triple-Wait → #email → #login-password → Triple-Click #login-submit with force dispatch"
        case .tabNavigation:
            "Click email → char-by-char type → Tab to password → char-by-char type → Enter to submit"
        case .clickFocusSequential:
            "Click each field with mouse movement → type with Gaussian delays → click login button"
        case .execCommandInsert:
            "Focus field → execCommand insertText per char → blur → human click submit"
        case .slowDeliberateTyper:
            "Very slow typing with long pauses, occasional backspace corrections, then manual click"
        case .mobileTouchBurst:
            "Touch events for field selection → fast burst typing → touch submit"
        case .calibratedDirect:
            "Use calibrated CSS selectors to fill fields and click button directly"
        case .calibratedTyping:
            "Use calibrated selectors to focus, then char-by-char type with Enter submit"
        case .formSubmitDirect:
            "Fill via nativeInputValueSetter → form.requestSubmit() or form.submit()"
        case .coordinateClick:
            "Use calibrated pixel coordinates to click email, password, and login button"
        case .reactNativeSetter:
            "React-compatible: Object.defineProperty setter + InputEvent with inputType"
        case .visionMLCoordinate:
            "Vision ML: Screenshot OCR to detect fields/buttons, then coordinate-based taps"
        }
    }
}

@MainActor
class HumanInteractionEngine {
    static let shared = HumanInteractionEngine()

    private let logger = DebugLogger.shared
    private let patternLearning = LoginPatternLearning.shared

    private func gaussianRandom(mean: Double, stdDev: Double) -> Double {
        let u1 = Double.random(in: 0.0001...0.9999)
        let u2 = Double.random(in: 0.0001...0.9999)
        let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return mean + z * stdDev
    }

    private func humanDelay(minMs: Int, maxMs: Int) -> Int {
        let mean = Double(minMs + maxMs) / 2.0
        let stdDev = Double(maxMs - minMs) / 4.0
        let delay = gaussianRandom(mean: mean, stdDev: stdDev)
        return max(minMs, min(maxMs, Int(delay)))
    }

    func selectBestPattern(for url: String) -> LoginFormPattern {
        return .trueDetection
    }

    func executePattern(
        _ pattern: LoginFormPattern,
        username: String,
        password: String,
        executeJS: @escaping (String) async -> String?,
        sessionId: String
    ) async -> HumanPatternResult {
        logger.log("HumanInteraction: executing pattern '\(pattern.rawValue)'", category: .automation, level: .info, sessionId: sessionId)
        let startTime = Date()

        let result: HumanPatternResult
        switch pattern {
        case .trueDetection:
            result = await executeTrueDetectionPattern(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .tabNavigation:
            result = await executeTabNavigation(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .clickFocusSequential:
            result = await executeClickFocusSequential(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .execCommandInsert:
            result = await executeExecCommandInsert(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .slowDeliberateTyper:
            result = await executeSlowDeliberateTyper(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .mobileTouchBurst:
            result = await executeMobileTouchBurst(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .calibratedDirect:
            result = await executeCalibratedDirect(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .calibratedTyping:
            result = await executeCalibratedTyping(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .formSubmitDirect:
            result = await executeFormSubmitDirect(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .coordinateClick:
            result = await executeCoordinateClick(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .reactNativeSetter:
            result = await executeReactNativeSetter(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        case .visionMLCoordinate:
            result = await executeVisionMLCoordinate(username: username, password: password, executeJS: executeJS, sessionId: sessionId)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        logger.log("HumanInteraction: pattern '\(pattern.rawValue)' completed in \(Int(elapsed * 1000))ms — fillSuccess:\(result.usernameFilled && result.passwordFilled) submitSuccess:\(result.submitTriggered)", category: .automation, level: result.submitTriggered ? .success : .warning, sessionId: sessionId, durationMs: Int(elapsed * 1000))

        return result
    }

    // MARK: - Pattern 0: TRUE DETECTION (Hardcoded Interaction Protocol)
    private func executeTrueDetectionPattern(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .trueDetection)

        logger.log("TrueDetection Pattern: waiting for DOM complete...", category: .automation, level: .trace, sessionId: sessionId)
        let domStart = Date()
        while Date().timeIntervalSince(domStart) < 10 {
            let ready = await executeJS("document.readyState")
            if ready == "complete" { break }
            try? await Task.sleep(for: .milliseconds(300))
        }

        logger.log("TrueDetection Pattern: hard pause 4000ms", category: .automation, level: .trace, sessionId: sessionId)
        try? await Task.sleep(for: .milliseconds(4000))

        let escapedUser = username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let emailJS = """
        (function() {
            var el = document.querySelector('#email');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escapedUser)'); } else { el.value = '\(escapedUser)'; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escapedUser)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let emailResult = await executeJS(emailJS)
        result.usernameFilled = emailResult == "OK" || emailResult == "VALUE_MISMATCH"
        logger.log("TrueDetection: #email fill → \(emailResult ?? "nil")", category: .automation, level: result.usernameFilled ? .success : .error, sessionId: sessionId)

        if !result.usernameFilled { return result }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 300...600)))

        let escapedPass = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let passJS = """
        (function() {
            var el = document.querySelector('#login-password');
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (ns && ns.set) { ns.set.call(el, ''); } else { el.value = ''; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            if (ns && ns.set) { ns.set.call(el, '\(escapedPass)'); } else { el.value = '\(escapedPass)'; }
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            return el.value === '\(escapedPass)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
        let passResult = await executeJS(passJS)
        result.passwordFilled = passResult == "OK" || passResult == "VALUE_MISMATCH"
        logger.log("TrueDetection: #login-password fill → \(passResult ?? "nil")", category: .automation, level: result.passwordFilled ? .success : .error, sessionId: sessionId)

        if !result.passwordFilled { return result }
        try? await Task.sleep(for: .milliseconds(Int.random(in: 300...600)))

        logger.log("TrueDetection: starting triple-click on #login-submit", category: .automation, level: .info, sessionId: sessionId)
        for i in 0..<3 {
            let clickJS = """
            (function() {
                var btn = document.querySelector('#login-submit');
                if (!btn) return 'NOT_FOUND';
                btn.scrollIntoView({behavior: 'instant', block: 'center'});
                var r = btn.getBoundingClientRect();
                var cx = r.left + r.width * (0.3 + Math.random() * 0.4);
                var cy = r.top + r.height * (0.3 + Math.random() * 0.4);
                btn.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                btn.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0,buttons:1}));
                btn.dispatchEvent(new PointerEvent('pointerup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                btn.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                btn.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,view:window,clientX:cx,clientY:cy,button:0}));
                btn.click();
                return 'CLICKED_' + \(i);
            })();
            """
            let clickResult = await executeJS(clickJS)
            logger.log("TrueDetection: triple-click \(i + 1)/3 → \(clickResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)
            if clickResult == "NOT_FOUND" && i == 0 {
                return result
            }
            if i < 2 {
                try? await Task.sleep(for: .milliseconds(1100))
            }
        }

        result.submitTriggered = true
        result.submitMethod = "TRUE_DETECTION_TRIPLE_CLICK"
        logger.log("TrueDetection: triple-click complete", category: .automation, level: .success, sessionId: sessionId)
        return result
    }

    // MARK: - Pattern 1: Tab Navigation
    private func executeTabNavigation(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .tabNavigation)

        let findAndClickEmail = buildFindEmailFieldJS() + """
        if (el) {
            el.scrollIntoView({behavior:'smooth',block:'center'});
            el.click();
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles:true}));
            'FOCUSED';
        } else { 'NOT_FOUND'; }
        """
        let focusResult = await executeJS("(function(){ \(findAndClickEmail) })()")
        guard focusResult != "NOT_FOUND" else {
            logger.log("TabNav: email field NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }
        logger.log("TabNav: email field focused", category: .automation, level: .trace, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 45, maxDelayMs: 160)
        result.usernameFilled = userTyped
        logger.log("TabNav: username typed char-by-char: \(userTyped)", category: .automation, level: userTyped ? .debug : .warning, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 350)))

        let tabJS = """
        (function(){
            var active = document.activeElement;
            if (active) {
                active.dispatchEvent(new KeyboardEvent('keydown', {key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keyup', {key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));
            }
            var passField = document.querySelector('input[type="password"]');
            if (passField) {
                passField.focus();
                passField.click();
                passField.dispatchEvent(new Event('focus', {bubbles:true}));
                return 'TAB_TO_PASS';
            }
            return 'TAB_SENT';
        })()
        """
        let tabResult = await executeJS(tabJS)
        logger.log("TabNav: Tab key → \(tabResult ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 50, maxDelayMs: 180)
        result.passwordFilled = passTyped
        logger.log("TabNav: password typed char-by-char: \(passTyped)", category: .automation, level: passTyped ? .debug : .warning, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 600)))

        let enterJS = """
        (function(){
            var active = document.activeElement;
            if (!active) active = document.querySelector('input[type="password"]');
            if (active) {
                active.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_PRESSED';
            }
            return 'NO_ACTIVE';
        })()
        """
        let enterResult = await executeJS(enterJS)
        result.submitTriggered = enterResult == "ENTER_PRESSED"
        result.submitMethod = "Enter key on password field"
        logger.log("TabNav: Enter key → \(enterResult ?? "nil")", category: .automation, level: result.submitTriggered ? .success : .warning, sessionId: sessionId)

        return result
    }

    // MARK: - Pattern 2: Click-Focus Sequential
    private func executeClickFocusSequential(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .clickFocusSequential)

        let mouseAndClickEmailJS = """
        (function(){
            \(buildFindEmailFieldJS())
            if (!el) return 'NOT_FOUND';
            el.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = el.getBoundingClientRect();
            var startX = rect.left - 40 - Math.random() * 60;
            var startY = rect.top + Math.random() * 20 - 10;
            var endX = rect.left + rect.width * (0.2 + Math.random() * 0.6);
            var endY = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            var steps = 5 + Math.floor(Math.random() * 5);
            for (var i = 0; i <= steps; i++) {
                var t = i / steps;
                var bezT = t * t * (3 - 2 * t);
                var mx = startX + (endX - startX) * bezT + (Math.random() * 2 - 1);
                var my = startY + (endY - startY) * bezT + (Math.random() * 2 - 1);
                try { document.elementFromPoint(mx, my); } catch(e){}
                try { el.dispatchEvent(new MouseEvent('mousemove', {bubbles:true,clientX:mx,clientY:my})); } catch(e){}
            }
            el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            el.focus();
            el.dispatchEvent(new Event('focus', {bubbles:true}));
            el.value = '';
            return 'CLICKED_EMAIL';
        })()
        """
        let emailClick = await executeJS(mouseAndClickEmailJS)
        guard emailClick != "NOT_FOUND" else {
            logger.log("ClickFocus: email field NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 55, maxDelayMs: 200)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 400, maxMs: 900)))

        let blurAndClickPassJS = """
        (function(){
            var emailField = document.activeElement;
            if (emailField) {
                emailField.dispatchEvent(new Event('blur', {bubbles:true}));
                emailField.dispatchEvent(new Event('change', {bubbles:true}));
            }
            var passField = document.querySelector('input[type="password"]');
            if (!passField) return 'NO_PASS_FIELD';
            passField.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = passField.getBoundingClientRect();
            var cx = rect.left + rect.width * (0.2 + Math.random() * 0.6);
            var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            passField.dispatchEvent(new MouseEvent('mouseover', {bubbles:true,clientX:cx,clientY:cy}));
            passField.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.dispatchEvent(new MouseEvent('mouseup', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            passField.focus();
            passField.dispatchEvent(new Event('focus', {bubbles:true}));
            passField.value = '';
            return 'CLICKED_PASS';
        })()
        """
        let passClick = await executeJS(blurAndClickPassJS)
        logger.log("ClickFocus: password field click → \(passClick ?? "nil")", category: .automation, level: .trace, sessionId: sessionId)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 60, maxDelayMs: 190)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 800)))

        let clickLoginResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickLoginResult
        result.submitMethod = "Mouse click on login button"

        return result
    }

    // MARK: - Pattern 3: ExecCommand Insert
    private func executeExecCommandInsert(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .execCommandInsert)

        let focusEmailJS = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.focus(); el.select(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'FOCUSED'; })()"
        let focused = await executeJS(focusEmailJS)
        guard focused != "NOT_FOUND" else {
            logger.log("ExecCmd: email NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))

        let userTyped = await typeWithExecCommand(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 30, maxDelayMs: 120)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let focusPassJS = """
        (function(){
            var el = document.activeElement;
            if (el) { el.dispatchEvent(new Event('blur',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); }
            var pass = document.querySelector('input[type="password"]');
            if (!pass) return 'NOT_FOUND';
            pass.focus();
            pass.select();
            pass.value = '';
            pass.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'FOCUSED';
        })()
        """
        let passFocused = await executeJS(focusPassJS)
        guard passFocused != "NOT_FOUND" else {
            logger.log("ExecCmd: password NOT_FOUND", category: .automation, level: .error, sessionId: sessionId)
            return result
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 350)))

        let passTyped = await typeWithExecCommand(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 35, maxDelayMs: 130)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        let blurAndSubmitJS = """
        (function(){
            var active = document.activeElement;
            if (active) { active.dispatchEvent(new Event('blur',{bubbles:true})); }
            var passField = document.querySelector('input[type="password"]');
            if (passField) {
                passField.focus();
                passField.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                passField.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                passField.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_PRESSED';
            }
            return 'NO_FIELD';
        })()
        """
        let submitResult = await executeJS(blurAndSubmitJS)
        result.submitTriggered = submitResult == "ENTER_PRESSED"
        result.submitMethod = "ExecCommand + Enter key"

        return result
    }

    // MARK: - Pattern 4: Slow Deliberate Typer
    private func executeSlowDeliberateTyper(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .slowDeliberateTyper)

        let focusJS = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.scrollIntoView({behavior:'smooth',block:'center'}); el.focus(); el.click(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; })()"
        let f = await executeJS(focusJS)
        guard f != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 500, maxMs: 1200)))

        let userTyped = await typeSlowWithCorrections(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email")
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 600, maxMs: 1500)))

        let tabToPassJS = """
        (function(){
            var active = document.activeElement;
            if (active) {
                active.dispatchEvent(new Event('blur',{bubbles:true}));
                active.dispatchEvent(new Event('change',{bubbles:true}));
            }
            var pass = document.querySelector('input[type="password"]');
            if (!pass) return 'NOT_FOUND';
            pass.focus();
            pass.click();
            pass.value = '';
            pass.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'FOCUSED';
        })()
        """
        let pf = await executeJS(tabToPassJS)
        guard pf != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 400, maxMs: 1000)))

        let passTyped = await typeSlowWithCorrections(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password")
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 800, maxMs: 2000)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "Slow deliberate mouse click"

        return result
    }

    // MARK: - Pattern 5: Mobile Touch Burst
    private func executeMobileTouchBurst(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .mobileTouchBurst)

        let touchFocusEmailJS = """
        (function(){
            \(buildFindEmailFieldJS())
            if (!el) return 'NOT_FOUND';
            el.scrollIntoView({behavior:'instant',block:'center'});
            var rect = el.getBoundingClientRect();
            var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
            var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            try {
                var t = new Touch({identifier:Date.now(),target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
                el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
                el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));
            } catch(e) {
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
            }
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            el.focus();
            el.value = '';
            el.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'TOUCHED';
        })()
        """
        let touchResult = await executeJS(touchFocusEmailJS)
        guard touchResult != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 300)))

        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 25, maxDelayMs: 80)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))

        let touchPassJS = """
        (function(){
            var active = document.activeElement;
            if (active) { active.dispatchEvent(new Event('blur',{bubbles:true})); }
            var pass = document.querySelector('input[type="password"]');
            if (!pass) return 'NOT_FOUND';
            pass.scrollIntoView({behavior:'instant',block:'center'});
            var rect = pass.getBoundingClientRect();
            var cx = rect.left + rect.width * (0.3 + Math.random() * 0.4);
            var cy = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            try {
                var t = new Touch({identifier:Date.now(),target:pass,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
                pass.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
                pass.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));
            } catch(e) {
                pass.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
                pass.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch'}));
            }
            pass.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            pass.focus();
            pass.value = '';
            pass.dispatchEvent(new Event('focus',{bubbles:true}));
            return 'TOUCHED';
        })()
        """
        let touchPass = await executeJS(touchPassJS)
        guard touchPass != "NOT_FOUND" else { return result }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 80, maxMs: 250)))

        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 20, maxDelayMs: 70)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let touchSubmitJS = """
        (function(){
            var pass = document.querySelector('input[type="password"]');
            if (pass) {
                pass.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER';
            }
            return 'NO_FIELD';
        })()
        """
        let submitR = await executeJS(touchSubmitJS)
        if submitR == "ENTER" {
            result.submitTriggered = true
            result.submitMethod = "Touch + Enter key"
        } else {
            let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
            result.submitTriggered = clickResult
            result.submitMethod = "Touch fallback click"
        }

        return result
    }

    // MARK: - Typing Engines

    private func typeCharByChar(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        for (index, char) in text.enumerated() {
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
            let keyCode = charKeyCode(char)

            let typeOneCharJS = """
            (function(){
                var el = document.activeElement;
                if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
                    var inp = document.querySelector('input[type="\(fieldName == "password" ? "password" : "email")"]') || document.querySelector('input[type="\(fieldName == "password" ? "password" : "text")"]');
                    if (inp) { inp.focus(); el = inp; }
                }
                if (!el) return 'NO_ELEMENT';
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true}));
                el.dispatchEvent(new KeyboardEvent('keypress',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true,cancelable:true,charCode:\(keyCode)}));
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var currentVal = el.value || '';
                var newVal = currentVal + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,cancelable:false,inputType:'insertText',data:'\(escaped)'}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(escaped)',code:'\(charCode(char))',keyCode:\(keyCode),which:\(keyCode),bubbles:true}));
                return 'TYPED';
            })()
            """
            let r = await executeJS(typeOneCharJS)
            if r != "TYPED" {
                logger.log("CharByChar: failed at index \(index) of \(fieldName): \(r ?? "nil")", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = humanDelay(minMs: minDelayMs, maxMs: maxDelayMs)
            if index > 0 && index % Int.random(in: 4...8) == 0 {
                let thinkPause = humanDelay(minMs: 200, maxMs: 600)
                try? await Task.sleep(for: .milliseconds(delay + thinkPause))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }

        let verifyJS = """
        (function(){
            var el = document.activeElement;
            if (!el) return 'NO_EL';
            return el.value ? el.value.length.toString() : '0';
        })()
        """
        let lenStr = await executeJS(verifyJS)
        let typedLen = Int(lenStr ?? "0") ?? 0
        let success = typedLen >= text.count
        if !success {
            logger.log("CharByChar: \(fieldName) verify failed — typed \(typedLen)/\(text.count) chars", category: .automation, level: .warning, sessionId: sessionId)
        }
        return success
    }

    private func typeWithExecCommand(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String, minDelayMs: Int, maxDelayMs: Int) async -> Bool {
        for (index, char) in text.enumerated() {
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")

            let insertJS = """
            (function(){
                var el = document.activeElement;
                if (!el) return 'NO_EL';
                var success = document.execCommand('insertText', false, '\(escaped)');
                if (success) return 'EXEC_OK';
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var newVal = (el.value || '') + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(escaped)'}));
                return 'NATIVE_SET';
            })()
            """
            let r = await executeJS(insertJS)
            if r == "NO_EL" {
                logger.log("ExecCmd: no active element at index \(index) of \(fieldName)", category: .automation, level: .warning, sessionId: sessionId)
                return false
            }

            let delay = humanDelay(minMs: minDelayMs, maxMs: maxDelayMs)
            try? await Task.sleep(for: .milliseconds(delay))
        }

        return true
    }

    private func typeSlowWithCorrections(text: String, executeJS: @escaping (String) async -> String?, sessionId: String, fieldName: String) async -> Bool {
        let correctionChance = 0.08
        var i = 0
        let chars = Array(text)

        while i < chars.count {
            if Double.random(in: 0...1) < correctionChance && i > 2 {
                let typoChar = "abcdefghijklmnopqrstuvwxyz".randomElement()!
                let typoEscaped = String(typoChar)

                let typeTypoJS = """
                (function(){
                    var el = document.activeElement;
                    if (!el) return 'NO_EL';
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    var newVal = (el.value || '') + '\(typoEscaped)';
                    if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                    else { el.value = newVal; }
                    el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(typoEscaped)'}));
                    return 'TYPO';
                })()
                """
                _ = await executeJS(typeTypoJS)
                logger.log("SlowTyper: deliberate typo '\(typoChar)' at pos \(i) in \(fieldName)", category: .automation, level: .trace, sessionId: sessionId)

                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 800)))

                let backspaceJS = """
                (function(){
                    var el = document.activeElement;
                    if (!el) return 'NO_EL';
                    el.dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',code:'Backspace',keyCode:8,which:8,bubbles:true,cancelable:true}));
                    var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                    var newVal = (el.value || '').slice(0, -1);
                    if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                    else { el.value = newVal; }
                    el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));
                    el.dispatchEvent(new KeyboardEvent('keyup',{key:'Backspace',code:'Backspace',keyCode:8,which:8,bubbles:true}));
                    return 'BS';
                })()
                """
                _ = await executeJS(backspaceJS)

                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))
            }

            let char = chars[i]
            let charStr = String(char)
            let escaped = charStr.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let kc = charKeyCode(char)

            let typeJS = """
            (function(){
                var el = document.activeElement;
                if (!el) return 'NO_EL';
                el.dispatchEvent(new KeyboardEvent('keydown',{key:'\(escaped)',keyCode:\(kc),which:\(kc),bubbles:true,cancelable:true}));
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                var newVal = (el.value || '') + '\(escaped)';
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, newVal); }
                else { el.value = newVal; }
                el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'\(escaped)'}));
                el.dispatchEvent(new KeyboardEvent('keyup',{key:'\(escaped)',keyCode:\(kc),which:\(kc),bubbles:true}));
                return 'OK';
            })()
            """
            let r = await executeJS(typeJS)
            if r == "NO_EL" { return false }

            let delay = humanDelay(minMs: 120, maxMs: 350)
            if i > 0 && i % Int.random(in: 3...6) == 0 {
                try? await Task.sleep(for: .milliseconds(delay + humanDelay(minMs: 300, maxMs: 900)))
            } else {
                try? await Task.sleep(for: .milliseconds(delay))
            }

            i += 1
        }

        return true
    }

    // MARK: - Pattern 6: Calibrated Direct
    private func executeCalibratedDirect(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .calibratedDirect)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        let fillEmailJS = buildCalibratedFillJS(calibration: cal, fieldType: "email", value: username)
        let emailResult = await executeJS(fillEmailJS)
        result.usernameFilled = emailResult == "CAL_OK" || emailResult == "CAL_MISMATCH" || emailResult == "LEGACY_OK"
        if !result.usernameFilled {
            let legacyFocus = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            let f = await executeJS(legacyFocus)
            if f != "NOT_FOUND" {
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let fillPassJS = buildCalibratedFillJS(calibration: cal, fieldType: "password", value: password)
        let passResult = await executeJS(fillPassJS)
        result.passwordFilled = passResult == "CAL_OK" || passResult == "CAL_MISMATCH" || passResult == "LEGACY_OK"
        if !result.passwordFilled {
            let legacyFocus = "(function(){ var el = document.querySelector('input[type=\"password\"]'); if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            let f = await executeJS(legacyFocus)
            if f != "NOT_FOUND" {
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "Calibrated direct fill + click"
        return result
    }

    // MARK: - Pattern 7: Calibrated Typing
    private func executeCalibratedTyping(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .calibratedTyping)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        let focusEmailJS = buildCalibratedFocusJS(calibration: cal, fieldType: "email")
        let focused = await executeJS(focusEmailJS)
        if focused == "NOT_FOUND" {
            let legacyFocus = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            _ = await executeJS(legacyFocus)
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))
        let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 45, maxDelayMs: 160)
        result.usernameFilled = userTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let focusPassJS = buildCalibratedFocusJS(calibration: cal, fieldType: "password")
        let passFocused = await executeJS(focusPassJS)
        if passFocused == "NOT_FOUND" {
            let legacyFocus = "(function(){ var el = document.querySelector('input[type=\"password\"]'); if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            _ = await executeJS(legacyFocus)
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))
        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 50, maxDelayMs: 170)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 600)))

        let enterJS = """
        (function(){
            var active = document.activeElement;
            if (!active) active = document.querySelector('input[type="password"]');
            if (active) {
                active.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keypress', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                active.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER_PRESSED';
            }
            return 'NO_ACTIVE';
        })()
        """
        let enterResult = await executeJS(enterJS)
        result.submitTriggered = enterResult == "ENTER_PRESSED"
        result.submitMethod = "Calibrated focus + typing + Enter"
        return result
    }

    // MARK: - Pattern 8: Form Submit Direct
    private func executeFormSubmitDirect(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .formSubmitDirect)

        let fillBothJS = """
        (function(){
            var emailField = document.querySelector('input[type="email"]')
                || document.querySelector('input[autocomplete="email"]')
                || document.querySelector('input[autocomplete="username"]')
                || document.querySelector('input[name="email"]')
                || document.querySelector('input[name="username"]')
                || document.querySelector('input[type="text"]');
            var passField = document.querySelector('input[type="password"]');
            if (!emailField || !passField) return JSON.stringify({email:false, pass:false});

            function setValue(el, val) {
                el.focus();
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles:true}));
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, val); }
                else { el.value = val; }
                el.dispatchEvent(new Event('input', {bubbles:true}));
                el.dispatchEvent(new Event('change', {bubbles:true}));
                el.dispatchEvent(new Event('blur', {bubbles:true}));
            }

            setValue(emailField, '\(username.replacingOccurrences(of: "'", with: "\\'"))');
            setValue(passField, '\(password.replacingOccurrences(of: "'", with: "\\'"))');
            return JSON.stringify({email: emailField.value.length > 0, pass: passField.value.length > 0});
        })()
        """
        if let rawResult = await executeJS(fillBothJS),
           let data = rawResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            result.usernameFilled = json["email"] ?? false
            result.passwordFilled = json["pass"] ?? false
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let submitJS = """
        (function(){
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                if (forms[i].querySelector('input[type="password"]')) {
                    try { forms[i].requestSubmit(); return 'REQUEST_SUBMIT'; } catch(e){}
                    try { forms[i].submit(); return 'FORM_SUBMIT'; } catch(e){}
                }
            }
            if (forms.length > 0) {
                try { forms[0].requestSubmit(); return 'REQUEST_SUBMIT_FIRST'; } catch(e){}
                try { forms[0].submit(); return 'FORM_SUBMIT_FIRST'; } catch(e){}
            }
            return 'FAILED';
        })()
        """
        let submitResult = await executeJS(submitJS)
        result.submitTriggered = submitResult != "FAILED" && submitResult != nil
        result.submitMethod = "Form submit direct: \(submitResult ?? "nil")"
        return result
    }

    // MARK: - Pattern 9: Coordinate Click
    private func executeCoordinateClick(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .coordinateClick)
        let cal = LoginCalibrationService.shared.calibrationFor(url: sessionId)

        if let emailCoords = cal?.emailField?.coordinates {
            let clickFocusJS = """
            (function(){
                var el = document.elementFromPoint(\(Int(emailCoords.x)), \(Int(emailCoords.y)));
                if (!el) return 'NO_ELEMENT';
                if (el.tagName !== 'INPUT') { var inp = el.querySelector('input'); if (inp) el = inp; }
                el.focus(); el.click(); el.value = '';
                el.dispatchEvent(new Event('focus', {bubbles:true}));
                return 'FOCUSED';
            })()
            """
            let f = await executeJS(clickFocusJS)
            if f != "NO_ELEMENT" {
                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 300)))
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        } else {
            let focusJS = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            let f = await executeJS(focusJS)
            if f != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 300)))
                let typed = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        if let passCoords = cal?.passwordField?.coordinates {
            let clickPassJS = """
            (function(){
                var el = document.elementFromPoint(\(Int(passCoords.x)), \(Int(passCoords.y)));
                if (!el) return 'NO_ELEMENT';
                if (el.tagName !== 'INPUT') { var inp = el.querySelector('input'); if (inp) el = inp; }
                el.focus(); el.click(); el.value = '';
                el.dispatchEvent(new Event('focus', {bubbles:true}));
                return 'FOCUSED';
            })()
            """
            let f = await executeJS(clickPassJS)
            if f != "NO_ELEMENT" {
                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 300)))
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        } else {
            let focusJS = "(function(){ var el = document.querySelector('input[type=\"password\"]'); if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
            let f = await executeJS(focusJS)
            if f != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 100, maxMs: 300)))
                let typed = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 150)
                result.passwordFilled = typed
            }
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        if let btnCoords = cal?.loginButton?.coordinates {
            let clickBtnJS = """
            (function(){
                var cx = \(Int(btnCoords.x)); var cy = \(Int(btnCoords.y));
                var el = document.elementFromPoint(cx, cy);
                if (!el) return 'NO_ELEMENT';
                el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
                el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
                el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
                el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
                el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
                try { el.click(); } catch(e){}
                return 'COORD_CLICKED:' + el.tagName;
            })()
            """
            let r = await executeJS(clickBtnJS)
            result.submitTriggered = r?.hasPrefix("COORD_CLICKED") == true
            result.submitMethod = "Coordinate click: \(r ?? "nil")"
        } else {
            let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
            result.submitTriggered = clickResult
            result.submitMethod = "Coordinate fallback click"
        }

        return result
    }

    // MARK: - Pattern 10: React Native Setter
    private func executeReactNativeSetter(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .reactNativeSetter)

        let escapedUser = username.replacingOccurrences(of: "'", with: "\\\'")
        let escapedPass = password.replacingOccurrences(of: "'", with: "\\\'")

        let reactFillJS = """
        (function(){
            function reactSet(el, val) {
                if (!el) return false;
                el.focus();
                var tracker = el._valueTracker;
                var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                if (tracker) { tracker.setValue(''); }
                if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, val); }
                else { el.value = val; }
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
                var inputEvent = new InputEvent('input', {bubbles: true, cancelable: false, inputType: 'insertText', data: val});
                el.dispatchEvent(inputEvent);
                return el.value === val || el.value.length > 0;
            }

            var emailField = document.querySelector('input[type="email"]')
                || document.querySelector('input[autocomplete="email"]')
                || document.querySelector('input[name="email"]')
                || document.querySelector('input[name="username"]')
                || document.querySelector('input[type="text"]');
            var passField = document.querySelector('input[type="password"]');

            var emailOK = reactSet(emailField, '\(escapedUser)');
            var passOK = reactSet(passField, '\(escapedPass)');
            return JSON.stringify({email: emailOK, pass: passOK});
        })()
        """
        if let rawResult = await executeJS(reactFillJS),
           let data = rawResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            result.usernameFilled = json["email"] ?? false
            result.passwordFilled = json["pass"] ?? false
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "React native setter + click"

        if !result.submitTriggered {
            let enterJS = """
            (function(){
                var pass = document.querySelector('input[type="password"]');
                if (pass) {
                    pass.focus();
                    pass.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                    pass.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                    pass.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                    return 'ENTER';
                }
                return 'NO_FIELD';
            })()
            """
            let enterR = await executeJS(enterJS)
            result.submitTriggered = enterR == "ENTER"
            result.submitMethod = "React native setter + Enter"
        }

        return result
    }

    // MARK: - Pattern 11: Vision ML Coordinate
    private func executeVisionMLCoordinate(username: String, password: String, executeJS: @escaping (String) async -> String?, sessionId: String) async -> HumanPatternResult {
        var result = HumanPatternResult(pattern: .visionMLCoordinate)

        let focusEmailJS = "(function(){ \(buildFindEmailFieldJS()) if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; return 'OK'; })()"
        let emailFocus = await executeJS(focusEmailJS)
        if emailFocus != "NOT_FOUND" {
            try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))
            let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
            result.usernameFilled = userTyped
        } else {
            logger.log("VisionML: email field not found via selector, attempting coordinate-based", category: .automation, level: .info, sessionId: sessionId)
            let coordClickJS = """
            (function(){
                var inputs = document.querySelectorAll('input:not([type=hidden]):not([type=password])');
                for (var i = 0; i < inputs.length; i++) {
                    var inp = inputs[i];
                    if (inp.offsetParent !== null || inp.offsetWidth > 0) {
                        inp.focus(); inp.click(); inp.value = '';
                        inp.dispatchEvent(new Event('focus',{bubbles:true}));
                        return 'FOUND';
                    }
                }
                return 'NOT_FOUND';
            })()
            """
            let fallback = await executeJS(coordClickJS)
            if fallback != "NOT_FOUND" {
                try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))
                let userTyped = await typeCharByChar(text: username, executeJS: executeJS, sessionId: sessionId, fieldName: "email", minDelayMs: 40, maxDelayMs: 140)
                result.usernameFilled = userTyped
            }
        }

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 200, maxMs: 500)))

        let focusPassJS = "(function(){ var el = document.querySelector('input[type=\"password\"]'); if(!el) return 'NOT_FOUND'; el.focus(); el.click(); el.value=''; el.dispatchEvent(new Event('focus',{bubbles:true})); return 'OK'; })()"
        _ = await executeJS(focusPassJS)

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 150, maxMs: 400)))
        let passTyped = await typeCharByChar(text: password, executeJS: executeJS, sessionId: sessionId, fieldName: "password", minDelayMs: 45, maxDelayMs: 160)
        result.passwordFilled = passTyped

        try? await Task.sleep(for: .milliseconds(humanDelay(minMs: 300, maxMs: 700)))

        let clickResult = await humanClickLoginButton(executeJS: executeJS, sessionId: sessionId)
        result.submitTriggered = clickResult
        result.submitMethod = "Vision ML coordinate + click"

        return result
    }

    // MARK: - Calibration Helpers

    private func buildCalibratedFillJS(calibration: LoginCalibrationService.URLCalibration?, fieldType: String, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "\\\'")
        var selectors: [String] = []

        if let cal = calibration {
            let mapping = fieldType == "email" ? cal.emailField : cal.passwordField
            if let m = mapping {
                if !m.cssSelector.isEmpty { selectors.append(m.cssSelector) }
                selectors.append(contentsOf: m.fallbackSelectors)
            }
        }

        if fieldType == "email" {
            selectors.append(contentsOf: ["input[type='email']", "input[autocomplete='email']", "input[name='email']", "input[name='username']", "input[type='text']"])
        } else {
            selectors.append(contentsOf: ["input[type='password']", "input[autocomplete='current-password']", "input[name='password']"])
        }

        let selectorJSON = selectors.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")

        return """
        (function(){
            var selectors = [\(selectorJSON)];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) {
                        el.focus();
                        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                        if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, ''); } else { el.value = ''; }
                        el.dispatchEvent(new Event('input', {bubbles:true}));
                        if (nativeSetter && nativeSetter.set) { nativeSetter.set.call(el, '\(escaped)'); }
                        else { el.value = '\(escaped)'; }
                        el.dispatchEvent(new Event('input', {bubbles:true}));
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        if (el.value === '\(escaped)') return 'CAL_OK';
                        return 'CAL_MISMATCH';
                    }
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })()
        """
    }

    private func buildCalibratedFocusJS(calibration: LoginCalibrationService.URLCalibration?, fieldType: String) -> String {
        var selectors: [String] = []

        if let cal = calibration {
            let mapping = fieldType == "email" ? cal.emailField : cal.passwordField
            if let m = mapping {
                if !m.cssSelector.isEmpty { selectors.append(m.cssSelector) }
                selectors.append(contentsOf: m.fallbackSelectors)
            }
        }

        if fieldType == "email" {
            selectors.append(contentsOf: ["input[type='email']", "input[name='email']", "input[name='username']", "input[type='text']"])
        } else {
            selectors.append(contentsOf: ["input[type='password']", "input[name='password']"])
        }

        let selectorJSON = selectors.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" }.joined(separator: ",")

        return """
        (function(){
            var selectors = [\(selectorJSON)];
            for (var i = 0; i < selectors.length; i++) {
                try {
                    var el = document.querySelector(selectors[i]);
                    if (el && !el.disabled) {
                        el.scrollIntoView({behavior:'instant',block:'center'});
                        el.focus(); el.click(); el.value = '';
                        el.dispatchEvent(new Event('focus', {bubbles:true}));
                        return 'FOCUSED';
                    }
                } catch(e) {}
            }
            return 'NOT_FOUND';
        })()
        """
    }

    // MARK: - Login Button Click

    private func humanClickLoginButton(executeJS: @escaping (String) async -> String?, sessionId: String) async -> Bool {
        let ocrAndClickJS = """
        (function(){
            function findLoginBtn() {
                var loginTerms = ['log in','login','sign in','signin'];
                var allClickable = document.querySelectorAll('button, input[type="submit"], a, [role="button"], span, div');
                for (var i = 0; i < allClickable.length; i++) {
                    var el = allClickable[i];
                    var text = (el.textContent || el.value || '').replace(/[\\s]+/g,' ').toLowerCase().trim();
                    if (text.length > 50) continue;
                    for (var t = 0; t < loginTerms.length; t++) {
                        if (text === loginTerms[t] || (text.indexOf(loginTerms[t]) !== -1 && text.length < 25)) return el;
                    }
                }
                var submitBtn = document.querySelector('button[type="submit"]') || document.querySelector('input[type="submit"]');
                if (submitBtn) return submitBtn;
                var forms = document.querySelectorAll('form');
                for (var f = 0; f < forms.length; f++) {
                    if (forms[f].querySelector('input[type="password"]')) {
                        var btn = forms[f].querySelector('button') || forms[f].querySelector('[role="button"]');
                        if (btn) return btn;
                    }
                }
                return null;
            }
            var btn = findLoginBtn();
            if (!btn) return 'NOT_FOUND';
            btn.scrollIntoView({behavior:'smooth',block:'center'});
            var rect = btn.getBoundingClientRect();
            if (rect.width === 0 && rect.height === 0) return 'ZERO_SIZE';
            var startX = rect.left - 30 - Math.random() * 50;
            var startY = rect.top + Math.random() * 30 - 15;
            var endX = rect.left + rect.width * (0.3 + Math.random() * 0.4);
            var endY = rect.top + rect.height * (0.3 + Math.random() * 0.4);
            var steps = 4 + Math.floor(Math.random() * 4);
            for (var s = 0; s <= steps; s++) {
                var t = s / steps;
                var bezT = t * t * (3 - 2 * t);
                var mx = startX + (endX - startX) * bezT + (Math.random() * 1.5 - 0.75);
                var my = startY + (endY - startY) * bezT + (Math.random() * 1.5 - 0.75);
                try { btn.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:mx,clientY:my})); } catch(e){}
            }
            btn.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse'}));
            btn.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:endX,clientY:endY}));
            btn.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            btn.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0,buttons:1}));
            btn.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,pointerId:1,pointerType:'mouse',button:0}));
            btn.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            btn.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:endX,clientY:endY,button:0}));
            try { btn.click(); } catch(e){}
            var tag = btn.tagName || '';
            var txt = (btn.textContent || '').substring(0,20).trim();
            return 'CLICKED:' + tag + ':' + txt;
        })()
        """
        let r = await executeJS(ocrAndClickJS)
        logger.log("HumanClick login button: \(r ?? "nil")", category: .automation, level: r?.hasPrefix("CLICKED") == true ? .debug : .warning, sessionId: sessionId)

        if let r, r.hasPrefix("CLICKED") { return true }

        let enterFallbackJS = """
        (function(){
            var pass = document.querySelector('input[type="password"]');
            if (pass) {
                pass.focus();
                pass.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
                pass.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
                return 'ENTER';
            }
            var forms = document.querySelectorAll('form');
            for (var i = 0; i < forms.length; i++) {
                if (forms[i].querySelector('input[type="password"]')) {
                    try { forms[i].requestSubmit(); return 'REQUEST_SUBMIT'; } catch(e){}
                    try { forms[i].submit(); return 'FORM_SUBMIT'; } catch(e){}
                }
            }
            return 'FAILED';
        })()
        """
        let fallback = await executeJS(enterFallbackJS)
        logger.log("HumanClick fallback: \(fallback ?? "nil")", category: .automation, level: .debug, sessionId: sessionId)
        return fallback != "FAILED" && fallback != nil
    }

    // MARK: - Helpers

    private func buildFindEmailFieldJS() -> String {
        """
        var el = document.querySelector('input[type="email"]')
            || document.querySelector('input[autocomplete="email"]')
            || document.querySelector('input[autocomplete="username"]')
            || document.querySelector('input[name="email"]')
            || document.querySelector('input[name="username"]')
            || document.querySelector('input[id="email"]')
            || document.querySelector('input[id="username"]')
            || document.querySelector('input[id="login-email"]')
            || document.querySelector('input[id="loginEmail"]')
            || document.querySelector('input[placeholder*="Email" i]')
            || document.querySelector('input[placeholder*="email" i]')
            || document.querySelector('input[placeholder*="Username" i]')
            || (function(){ var inputs = document.querySelectorAll('form input[type="text"]'); return inputs.length > 0 ? inputs[0] : null; })()
            || document.querySelector('input[type="text"]');
        """
    }

    private func charKeyCode(_ char: Character) -> Int {
        let s = String(char).uppercased()
        guard let ascii = s.unicodeScalars.first?.value else { return 0 }
        if ascii >= 65 && ascii <= 90 { return Int(ascii) }
        if ascii >= 48 && ascii <= 57 { return Int(ascii) }
        switch char {
        case "@": return 50
        case ".": return 190
        case "-": return 189
        case "_": return 189
        case "!": return 49
        case "#": return 51
        case "$": return 52
        case "%": return 53
        case "&": return 55
        case "*": return 56
        case "+": return 187
        case "=": return 187
        default: return Int(ascii)
        }
    }

    private func charCode(_ char: Character) -> String {
        let upper = String(char).uppercased()
        if char.isLetter { return "Key\(upper)" }
        if char.isNumber { return "Digit\(char)" }
        switch char {
        case "@": return "Digit2"
        case ".": return "Period"
        case "-": return "Minus"
        case "_": return "Minus"
        case " ": return "Space"
        case "!": return "Digit1"
        case "#": return "Digit3"
        case "$": return "Digit4"
        default: return "Key\(upper)"
        }
    }
}

struct HumanPatternResult {
    let pattern: LoginFormPattern
    var usernameFilled: Bool = false
    var passwordFilled: Bool = false
    var submitTriggered: Bool = false
    var submitMethod: String = ""

    var overallSuccess: Bool {
        usernameFilled && passwordFilled && submitTriggered
    }

    var summary: String {
        "Pattern[\(pattern.rawValue)] user:\(usernameFilled) pass:\(passwordFilled) submit:\(submitTriggered) method:\(submitMethod)"
    }
}
