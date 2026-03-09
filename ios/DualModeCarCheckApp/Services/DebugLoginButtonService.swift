import Foundation
import UIKit
import WebKit

@MainActor
class DebugLoginButtonService {
    static let shared = DebugLoginButtonService()

    private let persistKey = "debug_login_button_configs_v1"
    private let logger = DebugLogger.shared
    private(set) var configs: [String: DebugLoginButtonConfig] = [:]

    var onAttemptUpdate: ((DebugClickAttempt) -> Void)?
    var onLog: ((String, PPSRLogEntry.Level) -> Void)?
    var isRunning: Bool = false
    var currentAttemptIndex: Int = 0
    var totalMethods: Int { allClickMethods.count }
    var shouldStop: Bool = false

    init() {
        load()
    }

    func configFor(url: String) -> DebugLoginButtonConfig? {
        let host = extractHost(from: url)
        if let exact = configs[host] { return exact }
        for (key, config) in configs {
            if host.contains(key) || key.contains(host) { return config }
        }
        return nil
    }

    func hasSuccessfulMethod(for url: String) -> Bool {
        configFor(url: url)?.successfulMethod != nil
    }

    func saveConfig(_ config: DebugLoginButtonConfig, forURL url: String) {
        let host = extractHost(from: url)
        configs[host] = config
        persist()
        logger.log("DebugLoginButton: saved config for \(host) — method: \(config.successfulMethod?.methodName ?? "none")", category: .automation, level: .success)
    }

    func deleteConfig(forURL url: String) {
        let host = extractHost(from: url)
        configs.removeValue(forKey: host)
        persist()
    }

    func cloneConfig(from sourceURL: String, to targetURLs: [String]) {
        guard let source = configFor(url: sourceURL) else { return }
        for target in targetURLs {
            let host = extractHost(from: target)
            var copy = source
            copy.id = UUID().uuidString
            copy.urlPattern = host
            copy.userConfirmed = false
            copy.testedAt = Date()
            configs[host] = copy
        }
        persist()
        onLog?("Cloned login button config from \(extractHost(from: sourceURL)) to \(targetURLs.count) URLs", .success)
    }

    func runFullDebugScan(
        session: LoginSiteWebSession,
        targetURL: URL,
        buttonLocation: DebugLoginButtonConfig.ButtonLocation?
    ) async -> [DebugClickAttempt] {
        isRunning = true
        shouldStop = false
        currentAttemptIndex = 0

        let urlString = targetURL.absoluteString
        let host = extractHost(from: urlString)
        var attempts: [DebugClickAttempt] = []

        let methods = allClickMethods
        let locationMethods = buttonLocation != nil ? locationBasedMethods(location: buttonLocation!) : []
        let allMethods = methods + locationMethods

        logger.log("DebugLoginButton: starting full scan with \(allMethods.count) methods for \(host)", category: .automation, level: .info)
        onLog?("Starting Debug Login Button scan: \(allMethods.count) methods to try", .info)

        let preContent = await session.getPageContent()
        let preURL = await session.getCurrentURL()

        for (index, method) in allMethods.enumerated() {
            if shouldStop { break }

            currentAttemptIndex = index
            var attempt = DebugClickAttempt(
                index: index,
                methodName: method.name,
                jsSnippet: String(method.js.prefix(200))
            )
            attempt.status = .running
            onAttemptUpdate?(attempt)

            logger.log("DebugLoginButton: [\(index + 1)/\(allMethods.count)] trying '\(method.name)'", category: .automation, level: .debug)

            let startTime = Date()

            await session.dismissCookieNotices()
            try? await Task.sleep(for: .milliseconds(100))

            let result = await session.executeJS(method.js)
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)

            attempt.durationMs = elapsed
            attempt.resultDetail = result ?? "nil"

            try? await Task.sleep(for: .milliseconds(500))

            let postContent = await session.getPageContent()
            let postURL = await session.getCurrentURL()
            let contentChanged = postContent != preContent
            let urlChanged = postURL != preURL

            let buttonStateChanged = await checkButtonStateChanged(session: session)

            let autoDetectedSuccess = contentChanged || urlChanged || buttonStateChanged ||
                (result != nil && (result!.contains("CLICKED") || result!.contains("OK") || result!.contains("CONFIRMED")))

            if autoDetectedSuccess {
                attempt.status = .success
                attempt.resultDetail += " | content_changed=\(contentChanged) url_changed=\(urlChanged) btn_state=\(buttonStateChanged)"

                logger.log("DebugLoginButton: AUTO-DETECTED SUCCESS with '\(method.name)' — \(attempt.resultDetail)", category: .automation, level: .success)
                onLog?("AUTO-DETECTED: '\(method.name)' appears to have worked!", .success)

                var config = configs[host] ?? DebugLoginButtonConfig(urlPattern: host)
                config.successfulMethod = DebugLoginButtonConfig.ClickMethodResult(
                    methodName: method.name,
                    methodIndex: index,
                    jsCode: method.js,
                    resultDetail: attempt.resultDetail,
                    responseTimeMs: elapsed
                )
                config.buttonLocation = buttonLocation
                config.totalAttempts = index + 1
                config.successfulAttemptIndex = index
                config.testedAt = Date()
                saveConfig(config, forURL: urlString)
            } else {
                attempt.status = .failed
                logger.log("DebugLoginButton: [\(index + 1)] '\(method.name)' — no effect detected", category: .automation, level: .trace)
            }

            attempts.append(attempt)
            onAttemptUpdate?(attempt)

            if autoDetectedSuccess {
                break
            }

            if index < allMethods.count - 1 {
                try? await Task.sleep(for: .milliseconds(300))

                if contentChanged || urlChanged {
                    logger.log("DebugLoginButton: page changed, reloading before next attempt", category: .automation, level: .debug)
                    let reloaded = await session.loadPage(timeout: 15)
                    if !reloaded { break }
                    try? await Task.sleep(for: .milliseconds(1000))
                }
            }
        }

        isRunning = false
        currentAttemptIndex = 0

        let successCount = attempts.filter { $0.status == .success || $0.status == .userConfirmed }.count
        logger.log("DebugLoginButton: scan complete — \(attempts.count) tried, \(successCount) detected success", category: .automation, level: successCount > 0 ? .success : .warning)
        onLog?("Debug scan complete: \(attempts.count) methods tried, \(successCount) possible successes", successCount > 0 ? .success : .warning)

        return attempts
    }

    func confirmUserSuccess(attempt: DebugClickAttempt, session: LoginSiteWebSession, targetURL: URL, buttonLocation: DebugLoginButtonConfig.ButtonLocation?) {
        let urlString = targetURL.absoluteString
        let host = extractHost(from: urlString)
        let method = allClickMethods.first { $0.name == attempt.methodName } ??
            (buttonLocation != nil ? locationBasedMethods(location: buttonLocation!).first { $0.name == attempt.methodName } : nil)

        var config = configs[host] ?? DebugLoginButtonConfig(urlPattern: host)
        config.successfulMethod = DebugLoginButtonConfig.ClickMethodResult(
            methodName: attempt.methodName,
            methodIndex: attempt.index,
            jsCode: method?.js ?? "",
            resultDetail: "USER CONFIRMED: \(attempt.resultDetail)",
            responseTimeMs: attempt.durationMs
        )
        config.buttonLocation = buttonLocation
        config.totalAttempts = attempt.index + 1
        config.successfulAttemptIndex = attempt.index
        config.userConfirmed = true
        config.testedAt = Date()
        saveConfig(config, forURL: urlString)

        logger.log("DebugLoginButton: USER CONFIRMED '\(attempt.methodName)' for \(host)", category: .automation, level: .success)
        onLog?("User confirmed: '\(attempt.methodName)' saved for \(host)", .success)
    }

    func replaySuccessfulMethod(session: LoginSiteWebSession, url: String) async -> (success: Bool, detail: String) {
        guard let config = configFor(url: url), let method = config.successfulMethod else {
            return (false, "No saved debug login button method for this URL")
        }

        logger.log("DebugLoginButton: replaying '\(method.methodName)' for \(extractHost(from: url))", category: .automation, level: .info)

        let result = await session.executeJS(method.jsCode)
        let success = result != nil && !result!.contains("NOT_FOUND") && !result!.contains("NO_ELEMENT")

        if success {
            logger.log("DebugLoginButton: replay SUCCESS — \(result ?? "")", category: .automation, level: .success)
        } else {
            logger.log("DebugLoginButton: replay FAILED — \(result ?? "nil")", category: .automation, level: .warning)
        }

        return (success, "DebugBtn replay '\(method.methodName)': \(result ?? "nil")")
    }

    func stop() {
        shouldStop = true
    }

    private func checkButtonStateChanged(session: LoginSiteWebSession) async -> Bool {
        let js = """
        (function(){
            var terms=['log in','login','sign in','signin','submit'];
            var btns=document.querySelectorAll('button,input[type="submit"],a,[role="button"]');
            for(var i=0;i<btns.length;i++){
                var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();
                var isLogin=false;
                for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)isLogin=true;}
                if(!isLogin&&btns[i].type!=='submit')continue;
                var style=window.getComputedStyle(btns[i]);
                var opacity=parseFloat(style.opacity);
                var disabled=btns[i].disabled;
                var hasSpinner=btns[i].querySelector('.spinner,.loading,[class*="spin"],[class*="load"]')!==null;
                var loading=btns[i].classList.toString().toLowerCase();
                if(opacity<0.85||disabled||hasSpinner||loading.indexOf('loading')!==-1||loading.indexOf('disabled')!==-1){
                    return'CHANGED:opacity='+opacity+',disabled='+disabled+',spinner='+hasSpinner;
                }
            }
            return'UNCHANGED';
        })()
        """
        let result = await session.executeJS(js)
        return result?.hasPrefix("CHANGED") == true
    }

    private struct ClickMethod {
        let name: String
        let js: String
    }

    private var allClickMethods: [ClickMethod] {
        [
            ClickMethod(name: "01_NativeClick_ExactText", js: buildExactTextClickJS(clickType: "native")),
            ClickMethod(name: "02_HumanTouchChain_ExactText", js: buildExactTextClickJS(clickType: "humanTouch")),
            ClickMethod(name: "03_PointerEvents_ExactText", js: buildExactTextClickJS(clickType: "pointer")),
            ClickMethod(name: "04_TouchEvents_ExactText", js: buildExactTextClickJS(clickType: "touch")),
            ClickMethod(name: "05_DispatchClick_ExactText", js: buildExactTextClickJS(clickType: "dispatch")),
            ClickMethod(name: "06_MousedownUp_ExactText", js: buildExactTextClickJS(clickType: "mousedownUp")),
            ClickMethod(name: "07_FocusThenEnter_ExactText", js: buildExactTextClickJS(clickType: "focusEnter")),
            ClickMethod(name: "08_FormRequestSubmit", js: formRequestSubmitJS),
            ClickMethod(name: "09_FormSubmit", js: formSubmitJS),
            ClickMethod(name: "10_EnterOnPassword", js: enterOnPasswordJS),
            ClickMethod(name: "11_EnterOnEmail", js: enterOnEmailJS),
            ClickMethod(name: "12_TabEnterFromPassword", js: tabEnterFromPasswordJS),
            ClickMethod(name: "13_SubmitButtonNativeClick", js: submitButtonNativeJS),
            ClickMethod(name: "14_SubmitButtonDispatchAll", js: submitButtonDispatchAllJS),
            ClickMethod(name: "15_AriaLabelClick", js: ariaLabelClickJS),
            ClickMethod(name: "16_DataAttributeClick", js: dataAttributeClickJS),
            ClickMethod(name: "17_ShadowDOMSearch", js: shadowDOMSearchJS),
            ClickMethod(name: "18_IframeSearch", js: iframeSearchJS),
            ClickMethod(name: "19_NearPasswordButtonClick", js: nearPasswordButtonJS),
            ClickMethod(name: "20_LastButtonInForm", js: lastButtonInFormJS),
            ClickMethod(name: "21_SpanDivRoleButton", js: spanDivRoleButtonJS),
            ClickMethod(name: "22_AnchorTagClick", js: anchorTagClickJS),
            ClickMethod(name: "23_ImageButtonClick", js: imageButtonClickJS),
            ClickMethod(name: "24_SVGButtonClick", js: svgButtonClickJS),
            ClickMethod(name: "25_CustomElementClick", js: customElementClickJS),
            ClickMethod(name: "26_FullEventChain_AllButtons", js: fullEventChainAllButtonsJS),
            ClickMethod(name: "27_SimulateTrustedClick", js: simulateTrustedClickJS),
            ClickMethod(name: "28_InputEventBurstOnButton", js: inputEventBurstJS),
            ClickMethod(name: "29_CreateClickOnDocument", js: createClickOnDocumentJS),
            ClickMethod(name: "30_RequestAnimationFrameClick", js: requestAnimationFrameClickJS),
            ClickMethod(name: "31_MutationObserverThenClick", js: mutationObserverClickJS),
            ClickMethod(name: "32_SetTimeoutClick", js: setTimeoutClickJS),
            ClickMethod(name: "33_DoubleClick", js: doubleClickJS),
            ClickMethod(name: "34_ContextMenuThenClick", js: contextMenuClickJS),
            ClickMethod(name: "35_RemoveDisabledThenClick", js: removeDisabledClickJS),
            ClickMethod(name: "36_OverridePreventDefault", js: overridePreventDefaultJS),
            ClickMethod(name: "37_CloneAndReplaceButton", js: cloneReplaceButtonJS),
            ClickMethod(name: "38_DirectHTMLFormAction", js: directFormActionJS),
            ClickMethod(name: "39_XHRFormPost", js: xhrFormPostJS),
            ClickMethod(name: "40_FetchFormPost", js: fetchFormPostJS),
        ]
    }

    private func locationBasedMethods(location: DebugLoginButtonConfig.ButtonLocation) -> [ClickMethod] {
        let cx = Int(location.absoluteX)
        let cy = Int(location.absoluteY)
        return [
            ClickMethod(name: "L01_CoordNativeClick", js: coordNativeClickJS(cx: cx, cy: cy)),
            ClickMethod(name: "L02_CoordHumanTouch", js: coordHumanTouchJS(cx: cx, cy: cy)),
            ClickMethod(name: "L03_CoordPointerEvents", js: coordPointerEventsJS(cx: cx, cy: cy)),
            ClickMethod(name: "L04_CoordTouchEvents", js: coordTouchEventsJS(cx: cx, cy: cy)),
            ClickMethod(name: "L05_CoordFullChain", js: coordFullChainJS(cx: cx, cy: cy)),
            ClickMethod(name: "L06_CoordFocusEnter", js: coordFocusEnterJS(cx: cx, cy: cy)),
            ClickMethod(name: "L07_CoordMousedownUpClick", js: coordMousedownUpClickJS(cx: cx, cy: cy)),
            ClickMethod(name: "L08_CoordDispatchAllEvents", js: coordDispatchAllJS(cx: cx, cy: cy)),
            ClickMethod(name: "L09_CoordRemoveListenerClick", js: coordRemoveListenerClickJS(cx: cx, cy: cy)),
            ClickMethod(name: "L10_CoordRAFClick", js: coordRAFClickJS(cx: cx, cy: cy)),
        ]
    }

    // MARK: - JS Generators

    private func buildExactTextClickJS(clickType: String) -> String {
        let clickCode: String
        switch clickType {
        case "native":
            clickCode = "el.click(); return 'CLICKED:'+el.tagName+':'+text;"
        case "humanTouch":
            clickCode = """
            var r=el.getBoundingClientRect();var cx=r.left+r.width*(0.3+Math.random()*0.4);var cy=r.top+r.height*(0.3+Math.random()*0.4);
            el.focus();
            el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse'}));
            el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:cx,clientY:cy}));
            el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.click();
            return 'HUMAN_CLICKED:'+el.tagName+':'+text;
            """
        case "pointer":
            clickCode = """
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0,buttons:1}));
            el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'touch',button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            return 'POINTER_CLICKED:'+el.tagName+':'+text;
            """
        case "touch":
            clickCode = """
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            try{var t=new Touch({identifier:Date.now(),target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY});
            el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));
            el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));}catch(e){}
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy}));
            el.click();
            return 'TOUCH_CLICKED:'+el.tagName+':'+text;
            """
        case "dispatch":
            clickCode = """
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
            return 'DISPATCH_CLICKED:'+el.tagName+':'+text;
            """
        case "mousedownUp":
            clickCode = """
            var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;
            el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));
            el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));
            return 'MOUSEDOWN_CLICKED:'+el.tagName+':'+text;
            """
        case "focusEnter":
            clickCode = """
            el.focus();
            el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
            return 'ENTER_CLICKED:'+el.tagName+':'+text;
            """
        default:
            clickCode = "el.click(); return 'CLICKED:'+el.tagName+':'+text;"
        }

        return """
        (function(){
            var terms=['log in','login','sign in','signin','submit','continue','next','go','enter'];
            var all=document.querySelectorAll('button,input[type="submit"],a,[role="button"],span,div,label');
            for(var i=0;i<all.length;i++){
                var el=all[i];
                var text=(el.textContent||el.value||'').replace(/[\\s]+/g,' ').toLowerCase().trim();
                if(text.length>50)continue;
                for(var t=0;t<terms.length;t++){
                    if(text===terms[t]||text.indexOf(terms[t])!==-1&&text.length<30){
                        try{el.scrollIntoView({behavior:'instant',block:'center'});
                        \(clickCode)
                        }catch(e){continue;}
                    }
                }
            }
            return 'NOT_FOUND';
        })()
        """
    }

    private var formRequestSubmitJS: String {
        "(function(){var forms=document.querySelectorAll('form');for(var i=0;i<forms.length;i++){if(forms[i].querySelector('input[type=\"password\"]')){try{forms[i].requestSubmit();return'REQUEST_SUBMIT_OK';}catch(e){try{forms[i].submit();return'SUBMIT_OK';}catch(e2){}}}}return'NOT_FOUND';})()"
    }

    private var formSubmitJS: String {
        "(function(){var forms=document.querySelectorAll('form');for(var i=0;i<forms.length;i++){if(forms[i].querySelector('input[type=\"password\"]')){try{forms[i].submit();return'FORM_SUBMIT_OK';}catch(e){}}}return'NOT_FOUND';})()"
    }

    private var enterOnPasswordJS: String {
        "(function(){var el=document.querySelector('input[type=\"password\"]');if(!el)return'NOT_FOUND';el.focus();el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));return'ENTER_ON_PASS_OK';})()"
    }

    private var enterOnEmailJS: String {
        "(function(){var el=document.querySelector('input[type=\"email\"],input[type=\"text\"],input[name=\"email\"],input[name=\"username\"]');if(!el)return'NOT_FOUND';el.focus();el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));return'ENTER_ON_EMAIL_OK';})()"
    }

    private var tabEnterFromPasswordJS: String {
        "(function(){var el=document.querySelector('input[type=\"password\"]');if(!el)return'NOT_FOUND';el.focus();el.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Tab',code:'Tab',keyCode:9,which:9,bubbles:true}));var next=document.activeElement;if(next&&next!==el){next.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));next.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));next.click();return'TAB_ENTER_OK:'+next.tagName;}return'TAB_NO_FOCUS_CHANGE';})()"
    }

    private var submitButtonNativeJS: String {
        "(function(){var el=document.querySelector('button[type=\"submit\"],input[type=\"submit\"]');if(!el)return'NOT_FOUND';el.scrollIntoView({behavior:'instant',block:'center'});el.click();return'SUBMIT_BTN_NATIVE:'+el.tagName+':'+(el.textContent||el.value||'').substring(0,20);})()"
    }

    private var submitButtonDispatchAllJS: String {
        "(function(){var el=document.querySelector('button[type=\"submit\"],input[type=\"submit\"]');if(!el)return'NOT_FOUND';var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;el.focus();el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.click();return'SUBMIT_DISPATCH:'+el.tagName;})()"
    }

    private var ariaLabelClickJS: String {
        "(function(){var sels=['[aria-label*=\"Log In\"]','[aria-label*=\"Login\"]','[aria-label*=\"Sign In\"]','[aria-label*=\"log in\"]','[aria-label*=\"login\"]','[aria-label*=\"sign in\"]','[aria-label*=\"submit\"]'];for(var i=0;i<sels.length;i++){try{var el=document.querySelector(sels[i]);if(el){el.scrollIntoView({behavior:'instant',block:'center'});el.click();return'ARIA_CLICKED:'+sels[i]+':'+el.tagName;}}catch(e){}}return'NOT_FOUND';})()"
    }

    private var dataAttributeClickJS: String {
        "(function(){var sels=['[data-action=\"login\"]','[data-action=\"signin\"]','[data-action=\"submit\"]','[data-type=\"login\"]','[data-type=\"submit\"]','[data-testid*=\"login\"]','[data-testid*=\"submit\"]','[data-qa*=\"login\"]','[data-qa*=\"submit\"]','[data-cy*=\"login\"]','[data-cy*=\"submit\"]'];for(var i=0;i<sels.length;i++){try{var el=document.querySelector(sels[i]);if(el){el.scrollIntoView({behavior:'instant',block:'center'});el.click();return'DATA_CLICKED:'+sels[i]+':'+el.tagName;}}catch(e){}}return'NOT_FOUND';})()"
    }

    private var shadowDOMSearchJS: String {
        "(function(){function searchShadow(root,depth){if(depth>5)return null;var all=root.querySelectorAll('*');for(var i=0;i<all.length;i++){if(all[i].shadowRoot){var terms=['log in','login','sign in'];var els=all[i].shadowRoot.querySelectorAll('button,a,[role=\"button\"]');for(var j=0;j<els.length;j++){var text=(els[j].textContent||'').toLowerCase().trim();for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30){els[j].click();return'SHADOW_CLICKED:'+els[j].tagName+':'+text;}}}var deeper=searchShadow(all[i].shadowRoot,depth+1);if(deeper)return deeper;}}return null;}var result=searchShadow(document,0);return result||'NOT_FOUND';})()"
    }

    private var iframeSearchJS: String {
        "(function(){try{var iframes=document.querySelectorAll('iframe');for(var i=0;i<iframes.length;i++){try{var doc=iframes[i].contentDocument||iframes[i].contentWindow.document;var terms=['log in','login','sign in'];var els=doc.querySelectorAll('button,a,[role=\"button\"],input[type=\"submit\"]');for(var j=0;j<els.length;j++){var text=(els[j].textContent||els[j].value||'').toLowerCase().trim();for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30){els[j].click();return'IFRAME_CLICKED:'+els[j].tagName+':'+text;}}}}catch(e){}}}catch(e){}return'NOT_FOUND';})()"
    }

    private var nearPasswordButtonJS: String {
        "(function(){var pass=document.querySelector('input[type=\"password\"]');if(!pass)return'NOT_FOUND';var parent=pass.parentElement;for(var d=0;d<8&&parent;d++){var btns=parent.querySelectorAll('button,[role=\"button\"],a.btn,input[type=\"submit\"]');for(var b=0;b<btns.length;b++){if(btns[b].tagName==='INPUT'&&btns[b].type==='password')continue;var text=(btns[b].textContent||btns[b].value||'').trim();if(text.length<40){btns[b].scrollIntoView({behavior:'instant',block:'center'});btns[b].click();return'NEAR_PASS_CLICKED:d='+d+':'+btns[b].tagName+':'+text.substring(0,20);}}parent=parent.parentElement;}return'NOT_FOUND';})()"
    }

    private var lastButtonInFormJS: String {
        "(function(){var forms=document.querySelectorAll('form');for(var i=0;i<forms.length;i++){if(forms[i].querySelector('input[type=\"password\"]')){var btns=forms[i].querySelectorAll('button,[role=\"button\"],input[type=\"submit\"]');if(btns.length>0){var last=btns[btns.length-1];last.scrollIntoView({behavior:'instant',block:'center'});last.click();return'LAST_BTN_FORM:'+last.tagName+':'+(last.textContent||last.value||'').substring(0,20);}}}return'NOT_FOUND';})()"
    }

    private var spanDivRoleButtonJS: String {
        "(function(){var terms=['log in','login','sign in','signin','submit'];var els=document.querySelectorAll('span[role=\"button\"],div[role=\"button\"],label[role=\"button\"]');for(var i=0;i<els.length;i++){var text=(els[i].textContent||'').toLowerCase().trim();for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30){els[i].scrollIntoView({behavior:'instant',block:'center'});els[i].click();return'SPAN_DIV_CLICKED:'+els[i].tagName+':'+text;}}}return'NOT_FOUND';})()"
    }

    private var anchorTagClickJS: String {
        "(function(){var terms=['log in','login','sign in','signin','submit'];var els=document.querySelectorAll('a');for(var i=0;i<els.length;i++){var text=(els[i].textContent||'').toLowerCase().trim();for(var t=0;t<terms.length;t++){if(text===terms[t]||text.indexOf(terms[t])!==-1&&text.length<20){els[i].scrollIntoView({behavior:'instant',block:'center'});els[i].click();return'ANCHOR_CLICKED:'+text;}}}return'NOT_FOUND';})()"
    }

    private var imageButtonClickJS: String {
        "(function(){var els=document.querySelectorAll('input[type=\"image\"],button img,a img');for(var i=0;i<els.length;i++){var el=els[i].tagName==='IMG'?els[i].parentElement:els[i];if(el){var alt=(el.alt||el.title||el.getAttribute('aria-label')||'').toLowerCase();if(alt.indexOf('login')!==-1||alt.indexOf('sign in')!==-1||alt.indexOf('submit')!==-1){el.click();return'IMG_BTN_CLICKED:'+alt.substring(0,20);}}}return'NOT_FOUND';})()"
    }

    private var svgButtonClickJS: String {
        "(function(){var btns=document.querySelectorAll('button,a,[role=\"button\"]');for(var i=0;i<btns.length;i++){if(btns[i].querySelector('svg')){var text=(btns[i].textContent||btns[i].getAttribute('aria-label')||'').toLowerCase().trim();var terms=['log in','login','sign in','submit'];for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1){btns[i].click();return'SVG_BTN_CLICKED:'+text.substring(0,20);}}}}return'NOT_FOUND';})()"
    }

    private var customElementClickJS: String {
        "(function(){var all=document.querySelectorAll('*');for(var i=0;i<all.length;i++){if(all[i].tagName.indexOf('-')!==-1){var text=(all[i].textContent||'').toLowerCase().trim();var terms=['log in','login','sign in','submit'];for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30){all[i].click();return'CUSTOM_EL_CLICKED:'+all[i].tagName+':'+text.substring(0,20);}}}}return'NOT_FOUND';})()"
    }

    private var fullEventChainAllButtonsJS: String {
        "(function(){var terms=['log in','login','sign in','signin','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;el.focus();['pointerover','pointerenter','pointermove','pointerdown'].forEach(function(e){el.dispatchEvent(new PointerEvent(e,{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0,buttons:1}));});['mouseover','mouseenter','mousemove','mousedown'].forEach(function(e){el.dispatchEvent(new MouseEvent(e,{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0,buttons:e==='mousedown'?1:0}));});el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.click();return'FULL_CHAIN_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var simulateTrustedClickJS: String {
        "(function(){var terms=['log in','login','sign in','signin','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];el.scrollIntoView({behavior:'instant',block:'center'});var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;var evt=new MouseEvent('click',{bubbles:true,cancelable:true,view:window,detail:1,screenX:cx,screenY:cy,clientX:cx,clientY:cy,ctrlKey:false,altKey:false,shiftKey:false,metaKey:false,button:0,relatedTarget:null});el.dispatchEvent(evt);return'TRUSTED_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var inputEventBurstJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];el.focus();el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));el.click();el.dispatchEvent(new Event('submit',{bubbles:true}));return'INPUT_BURST_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var createClickOnDocumentJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];var r=el.getBoundingClientRect();var cx=r.left+r.width/2;var cy=r.top+r.height/2;document.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:cx,clientY:cy,button:0}));el.click();return'DOC_CLICK:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var requestAnimationFrameClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];requestAnimationFrame(function(){el.click();});return'RAF_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var mutationObserverClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];var observer=new MutationObserver(function(){observer.disconnect();});observer.observe(el,{attributes:true});el.click();return'MUTATION_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var setTimeoutClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];setTimeout(function(){el.click();},0);return'TIMEOUT_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var doubleClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];el.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true}));el.click();return'DBLCLICK_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var contextMenuClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];el.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));el.click();return'CTX_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var removeDisabledClickJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];el.disabled=false;el.removeAttribute('disabled');el.style.pointerEvents='auto';el.style.opacity='1';el.click();return'UNDISABLED_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var overridePreventDefaultJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];var clone=el.cloneNode(true);el.parentNode.replaceChild(clone,el);clone.click();return'OVERRIDE_CLICKED:'+clone.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var cloneReplaceButtonJS: String {
        "(function(){var terms=['log in','login','sign in','submit'];var btns=document.querySelectorAll('button,input[type=\"submit\"],[role=\"button\"]');for(var i=0;i<btns.length;i++){var text=(btns[i].textContent||btns[i].value||'').toLowerCase().trim();var match=false;for(var t=0;t<terms.length;t++){if(text.indexOf(terms[t])!==-1&&text.length<30)match=true;}if(!match)continue;var el=btns[i];var form=el.closest('form');if(form){try{form.requestSubmit();}catch(e){form.submit();}return'CLONE_FORM_SUBMIT:'+el.tagName+':'+text;}el.click();return'CLONE_CLICKED:'+el.tagName+':'+text;}return'NOT_FOUND';})()"
    }

    private var directFormActionJS: String {
        "(function(){var forms=document.querySelectorAll('form');for(var i=0;i<forms.length;i++){if(forms[i].querySelector('input[type=\"password\"]')){var action=forms[i].action||window.location.href;var method=(forms[i].method||'POST').toUpperCase();return'FORM_ACTION:'+method+':'+action;}}return'NOT_FOUND';})()"
    }

    private var xhrFormPostJS: String {
        """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(!forms[i].querySelector('input[type="password"]'))continue;
                var fd=new FormData(forms[i]);
                var action=forms[i].action||window.location.href;
                var xhr=new XMLHttpRequest();
                xhr.open('POST',action,true);
                xhr.withCredentials=true;
                xhr.onload=function(){document.open();document.write(xhr.responseText);document.close();};
                xhr.send(fd);
                return'XHR_POST_SENT:'+action;
            }
            return'NOT_FOUND';
        })()
        """
    }

    private var fetchFormPostJS: String {
        """
        (function(){
            var forms=document.querySelectorAll('form');
            for(var i=0;i<forms.length;i++){
                if(!forms[i].querySelector('input[type="password"]'))continue;
                var fd=new FormData(forms[i]);
                var action=forms[i].action||window.location.href;
                fetch(action,{method:'POST',body:fd,credentials:'same-origin',redirect:'follow'}).then(function(r){return r.text();}).then(function(t){document.open();document.write(t);document.close();});
                return'FETCH_POST_SENT:'+action;
            }
            return'NOT_FOUND';
        })()
        """
    }

    // MARK: - Coordinate-Based Methods

    private func coordNativeClickJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.click();return'COORD_NATIVE:'+el.tagName+':'+(el.textContent||'').substring(0,20);})()"
    }

    private func coordHumanTouchJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.focus();el.dispatchEvent(new PointerEvent('pointerover',{bubbles:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse'}));el.dispatchEvent(new MouseEvent('mouseover',{bubbles:true,clientX:\(cx),clientY:\(cy)}));el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.click();return'COORD_HUMAN:'+el.tagName;})()"
    }

    private func coordPointerEventsJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'touch',button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'touch',button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));return'COORD_POINTER:'+el.tagName;})()"
    }

    private func coordTouchEventsJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';try{var t=new Touch({identifier:Date.now(),target:el,clientX:\(cx),clientY:\(cy),pageX:\(cx)+window.scrollX,pageY:\(cy)+window.scrollY});el.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,cancelable:true,touches:[t],targetTouches:[t],changedTouches:[t]}));el.dispatchEvent(new TouchEvent('touchend',{bubbles:true,cancelable:true,touches:[],targetTouches:[],changedTouches:[t]}));}catch(e){}el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));el.click();return'COORD_TOUCH:'+el.tagName;})()"
    }

    private func coordFullChainJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.focus();['pointerover','pointerenter','pointermove','pointerdown'].forEach(function(e){el.dispatchEvent(new PointerEvent(e,{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));});['mouseover','mouseenter','mousemove','mousedown'].forEach(function(e){el.dispatchEvent(new MouseEvent(e,{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));});el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.click();return'COORD_FULL:'+el.tagName;})()"
    }

    private func coordFocusEnterJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.focus();el.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keypress',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));el.dispatchEvent(new KeyboardEvent('keyup',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));return'COORD_ENTER:'+el.tagName;})()"
    }

    private func coordMousedownUpClickJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));return'COORD_MDU:'+el.tagName;})()"
    }

    private func coordDispatchAllJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';el.disabled=false;el.removeAttribute('disabled');el.style.pointerEvents='auto';var r=el.getBoundingClientRect();el.focus();el.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0,buttons:1}));el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0,buttons:1}));el.dispatchEvent(new PointerEvent('pointerup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),pointerId:1,pointerType:'mouse',button:0}));el.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy),button:0}));el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window,detail:1,screenX:\(cx),screenY:\(cy),clientX:\(cx),clientY:\(cy),button:0}));try{el.click();}catch(e){}var form=el.closest('form');if(form){try{form.requestSubmit();}catch(e){try{form.submit();}catch(e2){}}}return'COORD_ALL:'+el.tagName;})()"
    }

    private func coordRemoveListenerClickJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';var clone=el.cloneNode(true);el.parentNode.replaceChild(clone,el);clone.click();return'COORD_CLONE:'+clone.tagName;})()"
    }

    private func coordRAFClickJS(cx: Int, cy: Int) -> String {
        "(function(){var el=document.elementFromPoint(\(cx),\(cy));if(!el)return'NO_ELEMENT';requestAnimationFrame(function(){el.click();el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:\(cx),clientY:\(cy)}));});return'COORD_RAF:'+el.tagName;})()"
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([String: DebugLoginButtonConfig].self, from: data) else { return }
        configs = decoded
    }

    private func extractHost(from url: String) -> String {
        URL(string: url)?.host ?? url
    }
}
