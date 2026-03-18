import Foundation
import WebKit
import UIKit

@MainActor
class BPointWebSession: NSObject {
    private(set) var webView: WKWebView?
    private var pageLoadContinuation: CheckedContinuation<Bool, Never>?
    private var isPageLoaded: Bool = false
    private var loadTimeoutTask: Task<Void, Never>?
    var stealthEnabled: Bool = false
    var lastNavigationError: String?
    var lastHTTPStatusCode: Int?
    var networkConfig: ActiveNetworkConfig = .direct
    private var isProtectedRouteBlocked: Bool = false
    private var stealthProfile: PPSRStealthService.SessionProfile?
    var onFingerprintLog: ((String, PPSRLogEntry.Level) -> Void)?
    private let logger = DebugLogger.shared

    static let targetURL = URL(string: "https://www.bpoint.com.au/payments/DepartmentOfFinance")!

    func setUp() {
        logger.log("BPointWebSession: setUp (stealth=\(stealthEnabled), network=\(networkConfig.label))", category: .webView, level: .debug)
        if webView != nil { tearDown() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = NetworkSessionFactory.shared.configureWKWebView(config: config, networkConfig: networkConfig, target: .ppsr)
        isProtectedRouteBlocked = networkConfig.requiresProtectedRoute && !proxyApplied
        if isProtectedRouteBlocked {
            lastNavigationError = "Protected BPoint route blocked — no proxy path available"
            logger.log("BPointWebSession: BLOCKED — no proxy available", category: .network, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            self.stealthProfile = profile
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: profile.viewport.width, height: profile.viewport.height), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = profile.userAgent
            self.webView = wv
        } else {
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            self.webView = wv
        }
    }

    func tearDown() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        if let wv = webView {
            wv.stopLoading()
            wv.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            wv.configuration.userContentController.removeAllUserScripts()
            wv.navigationDelegate = nil
        }
        webView = nil
        isPageLoaded = false
        isProtectedRouteBlocked = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil
        if let cont = pageLoadContinuation {
            pageLoadContinuation = nil
            cont.resume(returning: false)
        }
    }

    func loadPage(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else {
            lastNavigationError = "WebView not initialized"
            return false
        }
        guard !isProtectedRouteBlocked else {
            logger.log("BPointWebSession: loadPage blocked — protected route", category: .network, level: .error)
            return false
        }
        logger.startTimer(key: "bpointWebSession_load")
        isPageLoaded = false
        lastNavigationError = nil
        lastHTTPStatusCode = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: Self.targetURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        webView.load(request)

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pageLoadContinuation = continuation
            self.loadTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if self.pageLoadContinuation != nil {
                    self.pageLoadContinuation = nil
                    self.lastNavigationError = self.lastNavigationError ?? "Page load timed out after \(Int(timeout))s"
                    continuation.resume(returning: false)
                }
            }
        }

        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        let loadMs = logger.stopTimer(key: "bpointWebSession_load")
        if loaded {
            logger.log("BPointWebSession: page loaded in \(loadMs ?? 0)ms", category: .webView, level: .success, durationMs: loadMs)
            if stealthEnabled, let profile = stealthProfile {
                _ = await executeJS(PPSRStealthService.shared.fingerprintJS())
                _ = try? await Task.sleep(for: .milliseconds(1500))
            }
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
        } else {
            logger.log("BPointWebSession: page load FAILED — \(lastNavigationError ?? "unknown")", category: .webView, level: .error, durationMs: loadMs)
        }
        return loaded
    }

    func loadURL(_ url: URL, timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolvePageLoadTimeout(timeout)
        guard let webView else { return false }
        isPageLoaded = false
        lastNavigationError = nil

        if let existingCont = pageLoadContinuation {
            pageLoadContinuation = nil
            existingCont.resume(returning: false)
        }

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        webView.load(request)

        let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.pageLoadContinuation = continuation
            self.loadTimeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if self.pageLoadContinuation != nil {
                    self.pageLoadContinuation = nil
                    continuation.resume(returning: false)
                }
            }
        }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil

        if loaded {
            await waitForDOMReady(timeout: TimeoutResolver.resolveAutomationTimeout(10))
        }
        return loaded
    }

    private func waitForDOMReady(timeout: TimeInterval) async {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let ready = await executeJS("document.readyState") ?? ""
            if ready == "complete" || ready == "interactive" {
                try? await Task.sleep(for: .milliseconds(500))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private let findFieldJS = """
    function findField(strategies) {
        for (var i = 0; i < strategies.length; i++) {
            var s = strategies[i];
            var el = null;
            try {
                if (s.type === 'id') {
                    el = document.getElementById(s.value);
                } else if (s.type === 'name') {
                    var els = document.getElementsByName(s.value);
                    if (els.length > 0) el = els[0];
                } else if (s.type === 'placeholder') {
                    el = document.querySelector('input[placeholder*="' + s.value + '"]');
                    if (!el) el = document.querySelector('textarea[placeholder*="' + s.value + '"]');
                } else if (s.type === 'label') {
                    var labels = document.querySelectorAll('label');
                    for (var j = 0; j < labels.length; j++) {
                        var txt = (labels[j].textContent || '').trim().toLowerCase();
                        if (txt.indexOf(s.value.toLowerCase()) !== -1) {
                            var forId = labels[j].getAttribute('for');
                            if (forId) { el = document.getElementById(forId); }
                            else { el = labels[j].querySelector('input, textarea, select'); }
                            if (el) break;
                        }
                    }
                } else if (s.type === 'css') {
                    el = document.querySelector(s.value);
                } else if (s.type === 'ariaLabel') {
                    el = document.querySelector('[aria-label*="' + s.value + '"]');
                }
            } catch(e) {}
            if (el && !el.disabled && el.offsetParent !== null) return el;
            if (el && !el.disabled) return el;
        }
        return null;
    }
    """

    private func fillFieldJS(strategies: String, value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.value = '';
            var nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            if (nativeInputValueSetter && nativeInputValueSetter.set) {
                nativeInputValueSetter.set.call(el, '\(escaped)');
            } else {
                el.value = '\(escaped)';
            }
            el.dispatchEvent(new Event('focus', {bubbles: true}));
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            el.dispatchEvent(new Event('blur', {bubbles: true}));
            if (el.value === '\(escaped)') return 'OK';
            el.value = '\(escaped)';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return el.value === '\(escaped)' ? 'OK' : 'VALUE_MISMATCH';
        })();
        """
    }

    func fillReferenceNumber(_ ref: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"BillerCode"},{"type":"id","value":"billerCode"},
            {"type":"id","value":"Reference1"},{"type":"id","value":"reference1"},
            {"type":"name","value":"BillerCode"},{"type":"name","value":"Reference1"},
            {"type":"placeholder","value":"Reference"},{"type":"placeholder","value":"reference"},
            {"type":"label","value":"reference"},{"type":"label","value":"Reference Number"},
            {"type":"css","value":"input[type='text']:first-of-type"},
            {"type":"css","value":"input.form-control:first-of-type"},
            {"type":"css","value":"#Crn1"},{"type":"id","value":"Crn1"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: ref))
        return classifyFillResult(result, fieldName: "Reference Number")
    }

    func fillAmount(_ amount: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"Amount"},{"type":"id","value":"amount"},
            {"type":"id","value":"PaymentAmount"},{"type":"id","value":"paymentAmount"},
            {"type":"name","value":"Amount"},{"type":"name","value":"PaymentAmount"},
            {"type":"placeholder","value":"Amount"},{"type":"placeholder","value":"0.00"},
            {"type":"label","value":"amount"},{"type":"label","value":"Amount"},
            {"type":"css","value":"input[type='text']:nth-of-type(2)"},
            {"type":"css","value":"input.form-control:last-of-type"},
            {"type":"css","value":"#Amount"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: amount))
        return classifyFillResult(result, fieldName: "Amount")
    }

    func clickCardBrandLogo(isVisa: Bool) async -> (success: Bool, detail: String) {
        let brandName = isVisa ? "visa" : "mastercard"
        let altBrandName = isVisa ? "visa" : "master"
        let js = """
        (function() {
            var strategies = [
                function() {
                    var imgs = document.querySelectorAll('img');
                    for (var i = 0; i < imgs.length; i++) {
                        var src = (imgs[i].src || '').toLowerCase();
                        var alt = (imgs[i].alt || '').toLowerCase();
                        var title = (imgs[i].title || '').toLowerCase();
                        if (src.indexOf('\(brandName)') !== -1 || alt.indexOf('\(brandName)') !== -1 || title.indexOf('\(brandName)') !== -1 ||
                            src.indexOf('\(altBrandName)') !== -1 || alt.indexOf('\(altBrandName)') !== -1) {
                            var parent = imgs[i].parentElement;
                            if (parent && (parent.tagName === 'A' || parent.tagName === 'BUTTON' || parent.onclick || parent.getAttribute('role') === 'button')) {
                                parent.click();
                                return 'CLICKED_PARENT';
                            }
                            imgs[i].click();
                            return 'CLICKED_IMG';
                        }
                    }
                    return null;
                },
                function() {
                    var links = document.querySelectorAll('a, button, [role="button"], label, div[onclick]');
                    for (var i = 0; i < links.length; i++) {
                        var text = (links[i].textContent || '').toLowerCase().trim();
                        var cls = (links[i].className || '').toLowerCase();
                        var id = (links[i].id || '').toLowerCase();
                        if (text.indexOf('\(brandName)') !== -1 || cls.indexOf('\(brandName)') !== -1 || id.indexOf('\(brandName)') !== -1 ||
                            text.indexOf('\(altBrandName)') !== -1 || cls.indexOf('\(altBrandName)') !== -1) {
                            links[i].click();
                            return 'CLICKED_LINK';
                        }
                    }
                    return null;
                },
                function() {
                    var radios = document.querySelectorAll('input[type="radio"]');
                    for (var i = 0; i < radios.length; i++) {
                        var lbl = radios[i].closest('label') || document.querySelector('label[for="' + radios[i].id + '"]');
                        var labelText = lbl ? (lbl.textContent || '').toLowerCase() : '';
                        var val = (radios[i].value || '').toLowerCase();
                        var name = (radios[i].name || '').toLowerCase();
                        if (val.indexOf('\(brandName)') !== -1 || labelText.indexOf('\(brandName)') !== -1 ||
                            val.indexOf('\(altBrandName)') !== -1 || labelText.indexOf('\(altBrandName)') !== -1) {
                            radios[i].checked = true;
                            radios[i].click();
                            radios[i].dispatchEvent(new Event('change', {bubbles: true}));
                            return 'CLICKED_RADIO';
                        }
                    }
                    return null;
                }
            ];
            for (var i = 0; i < strategies.length; i++) {
                var result = strategies[i]();
                if (result) return result;
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if let result, result != "NOT_FOUND" {
            return (true, "\(isVisa ? "Visa" : "Mastercard") logo clicked via: \(result)")
        }
        return (false, "\(isVisa ? "Visa" : "Mastercard") logo not found")
    }

    func fillCardNumber(_ number: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"CardNumber"},{"type":"id","value":"cardNumber"},{"type":"id","value":"card-number"},
            {"type":"name","value":"CardNumber"},{"type":"name","value":"cardNumber"},{"type":"name","value":"card_number"},
            {"type":"placeholder","value":"Card Number"},{"type":"placeholder","value":"card number"},
            {"type":"label","value":"card number"},{"type":"ariaLabel","value":"card number"},
            {"type":"css","value":"input[autocomplete='cc-number']"},
            {"type":"css","value":"input[inputmode='numeric']"},
            {"type":"css","value":"#CardNumber"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: number))
        return classifyFillResult(result, fieldName: "Card Number")
    }

    func fillExpiry(_ expiry: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryDate"},{"type":"id","value":"expiry"},{"type":"id","value":"Expiry"},
            {"type":"name","value":"ExpiryDate"},{"type":"name","value":"expiry"},
            {"type":"placeholder","value":"MM/YY"},{"type":"placeholder","value":"Expiry"},
            {"type":"label","value":"expiry"},{"type":"label","value":"Expiry Date"},
            {"type":"css","value":"input[autocomplete='cc-exp']"},
            {"type":"css","value":"#ExpiryDate"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: expiry))
        return classifyFillResult(result, fieldName: "Expiry")
    }

    func fillExpMonth(_ month: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryMonth"},{"type":"id","value":"expMonth"},{"type":"id","value":"exp-month"},
            {"type":"name","value":"ExpiryMonth"},{"type":"name","value":"expMonth"},
            {"type":"placeholder","value":"MM"},{"type":"label","value":"month"},
            {"type":"css","value":"input[autocomplete='cc-exp-month']"},
            {"type":"css","value":"select[autocomplete='cc-exp-month']"},
            {"type":"css","value":"#ExpiryMonth"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: month))
        if result == "OK" || result == "VALUE_MISMATCH" { return (true, "Exp Month filled") }
        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: month))
        if selectResult == "OK" { return (true, "Exp Month filled via select") }
        return (false, "Exp Month fill failed: \(result ?? "nil")")
    }

    func fillExpYear(_ year: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"ExpiryYear"},{"type":"id","value":"expYear"},{"type":"id","value":"exp-year"},
            {"type":"name","value":"ExpiryYear"},{"type":"name","value":"expYear"},
            {"type":"placeholder","value":"YY"},{"type":"label","value":"year"},
            {"type":"css","value":"input[autocomplete='cc-exp-year']"},
            {"type":"css","value":"select[autocomplete='cc-exp-year']"},
            {"type":"css","value":"#ExpiryYear"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: year))
        if result == "OK" || result == "VALUE_MISMATCH" { return (true, "Exp Year filled") }
        let selectResult = await executeJS(fillSelectJS(strategies: strategies, value: year))
        if selectResult == "OK" { return (true, "Exp Year filled via select") }
        return (false, "Exp Year fill failed: \(result ?? "nil")")
    }

    func fillCVV(_ cvv: String) async -> (success: Bool, detail: String) {
        let strategies = """
        [
            {"type":"id","value":"Cvn"},{"type":"id","value":"cvv"},{"type":"id","value":"cvc"},{"type":"id","value":"SecurityCode"},
            {"type":"name","value":"Cvn"},{"type":"name","value":"cvv"},{"type":"name","value":"cvc"},
            {"type":"placeholder","value":"CVV"},{"type":"placeholder","value":"CVC"},{"type":"placeholder","value":"CVN"},
            {"type":"label","value":"CVV"},{"type":"label","value":"CVC"},{"type":"label","value":"security code"},
            {"type":"css","value":"input[autocomplete='cc-csc']"},
            {"type":"css","value":"#Cvn"}
        ]
        """
        let result = await executeJS(fillFieldJS(strategies: strategies, value: cvv))
        return classifyFillResult(result, fieldName: "CVV")
    }

    func clickSubmitPayment() async -> (success: Bool, detail: String) {
        let js = """
        (function() {
            var strategies = [
                function() {
                    var btns = document.querySelectorAll('button, input[type="submit"], a.btn, [role="button"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('pay now') !== -1 || text.indexOf('submit payment') !== -1 || text.indexOf('make payment') !== -1 || text.indexOf('proceed') !== -1) {
                            btns[i].click();
                            return 'CLICKED_PAY';
                        }
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                    for (var i = 0; i < btns.length; i++) {
                        var text = (btns[i].textContent || btns[i].value || '').toLowerCase().trim();
                        if (text.indexOf('pay') !== -1 || text.indexOf('submit') !== -1) {
                            btns[i].click();
                            return 'CLICKED_SUBMIT';
                        }
                    }
                    return null;
                },
                function() {
                    var btns = document.querySelectorAll('button[type="submit"], input[type="submit"]');
                    if (btns.length > 0) { btns[btns.length - 1].click(); return 'CLICKED_LAST_SUBMIT'; }
                    return null;
                },
                function() {
                    var forms = document.querySelectorAll('form');
                    if (forms.length > 0) { forms[forms.length - 1].submit(); return 'FORM_SUBMITTED'; }
                    return null;
                }
            ];
            for (var i = 0; i < strategies.length; i++) {
                var result = strategies[i]();
                if (result) return result;
            }
            return 'NOT_FOUND';
        })();
        """
        let result = await executeJS(js)
        if let result, result != "NOT_FOUND" {
            return (true, "Payment submit clicked: \(result)")
        }
        return (false, "Submit payment button not found")
    }

    private func fillSelectJS(strategies: String, value: String) -> String {
        return """
        (function() {
            \(findFieldJS)
            var el = findField(\(strategies));
            if (!el || el.tagName !== 'SELECT') return 'NOT_SELECT';
            var opts = el.options;
            for (var i = 0; i < opts.length; i++) {
                if (opts[i].value === '\(value)' || opts[i].textContent.trim() === '\(value)') {
                    el.selectedIndex = i;
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return 'OK';
                }
            }
            return 'OPTION_NOT_FOUND';
        })();
        """
    }

    func getPageContent() async -> String {
        await executeJS("document.body ? document.body.innerText.substring(0, 3000) : ''") ?? ""
    }

    func getPageTitle() async -> String {
        await executeJS("document.title") ?? "Unknown"
    }

    func getCurrentURL() async -> String {
        webView?.url?.absoluteString ?? "N/A"
    }

    func waitForNavigation(timeout: TimeInterval = 90) async -> Bool {
        let timeout = TimeoutResolver.resolveAutomationTimeout(timeout)
        let start = Date()
        let originalURL = webView?.url?.absoluteString ?? ""
        let originalBody = await executeJS("document.body ? document.body.innerText.substring(0, 200) : ''") ?? ""

        while Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(750))
            let currentURL = webView?.url?.absoluteString ?? ""
            if currentURL != originalURL && !currentURL.isEmpty {
                try? await Task.sleep(for: .milliseconds(1500))
                return true
            }
            let bodyText = await executeJS("document.body ? document.body.innerText.substring(0, 500) : ''") ?? ""
            if bodyText != originalBody && bodyText.count > 50 {
                let bodyLower = bodyText.lowercased()
                let indicators = ["payment", "receipt", "success", "approved", "declined", "error", "fail", "card number", "cvv"]
                for indicator in indicators {
                    if bodyLower.contains(indicator) {
                        try? await Task.sleep(for: .milliseconds(1000))
                        return true
                    }
                }
            }
        }
        return false
    }

    func captureScreenshot() async -> UIImage? {
        guard let webView else { return nil }
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        if webView.url == nil && !webView.isLoading { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        do { return try await webView.takeSnapshot(configuration: config) }
        catch { return nil }
    }

    func captureScreenshotWithCrop(cropRect: CGRect?) async -> (full: UIImage?, cropped: UIImage?) {
        guard let fullImage = await captureScreenshot() else { return (nil, nil) }
        guard let cropRect, cropRect != .zero else { return (fullImage, nil) }
        let scale = fullImage.scale
        let scaledRect = CGRect(x: cropRect.origin.x * scale, y: cropRect.origin.y * scale, width: cropRect.size.width * scale, height: cropRect.size.height * scale)
        if let cgImage = fullImage.cgImage?.cropping(to: scaledRect) {
            let cropped = UIImage(cgImage: cgImage, scale: scale, orientation: fullImage.imageOrientation)
            return (fullImage, cropped)
        }
        return (fullImage, nil)
    }

    func dumpPageStructure() async -> String {
        let js = """
        (function() {
            var info = {};
            info.title = document.title;
            info.url = window.location.href;
            info.readyState = document.readyState;
            var inputs = document.querySelectorAll('input, select, textarea');
            info.inputCount = inputs.length;
            info.inputs = [];
            for (var i = 0; i < Math.min(inputs.length, 20); i++) {
                var inp = inputs[i];
                info.inputs.push({tag: inp.tagName, type: inp.type || '', id: inp.id || '', name: inp.name || '', placeholder: inp.placeholder || ''});
            }
            var buttons = document.querySelectorAll('button, input[type="submit"], [role="button"]');
            info.buttonCount = buttons.length;
            info.iframeCount = document.querySelectorAll('iframe').length;
            var bodyText = (document.body ? document.body.innerText : '').substring(0, 500);
            info.bodyPreview = bodyText;
            return JSON.stringify(info);
        })();
        """
        return await executeJS(js) ?? "{}"
    }

    private func classifyFillResult(_ result: String?, fieldName: String) -> (success: Bool, detail: String) {
        switch result {
        case "OK": return (true, "\(fieldName) filled successfully")
        case "VALUE_MISMATCH": return (true, "\(fieldName) filled but value verification mismatch")
        case "NOT_FOUND": return (false, "\(fieldName) selector NOT_FOUND")
        case nil: return (false, "\(fieldName) JS execution returned nil")
        default: return (false, "\(fieldName) unexpected result: '\(result ?? "")'")
        }
    }

    func executeJS(_ js: String) async -> String? {
        guard let webView else { return nil }
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return "\(num)" }
            return nil
        } catch {
            logger.logError("BPointWebSession: JS eval failed", error: error, category: .webView, metadata: ["jsPrefix": String(js.prefix(60))])
            return nil
        }
    }
}

extension BPointWebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isPageLoaded = true
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: true)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = error.localizedDescription
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.lastNavigationError = error.localizedDescription
            if let cont = self.pageLoadContinuation {
                self.pageLoadContinuation = nil
                cont.resume(returning: false)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            Task { @MainActor in self.lastHTTPStatusCode = httpResponse.statusCode }
        }
        decisionHandler(.allow)
    }
}
