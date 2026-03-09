import Foundation
import WebKit

@MainActor
class WebViewPool {
    static let shared = WebViewPool()

    private var available: [WKWebView] = []
    private var inUse: Set<ObjectIdentifier> = []
    private let maxPoolSize: Int = 10
    private let logger = DebugLogger.shared

    var activeCount: Int { inUse.count }
    var availableCount: Int { available.count }
    var totalCount: Int { inUse.count + available.count }

    func acquire(stealthEnabled: Bool = false, viewportSize: CGSize = CGSize(width: 390, height: 844)) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
            wv.customUserAgent = profile.userAgent
            inUse.insert(ObjectIdentifier(wv))
            logger.log("WebViewPool: acquired stealth WKWebView (active:\(inUse.count) pool:\(available.count))", category: .webView, level: .trace)
            return wv
        }

        if let wv = available.popLast() {
            wv.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
            wv.configuration.userContentController.removeAllUserScripts()
            inUse.insert(ObjectIdentifier(wv))
            logger.log("WebViewPool: reused WKWebView (active:\(inUse.count) pool:\(available.count))", category: .webView, level: .trace)
            return wv
        }

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        inUse.insert(ObjectIdentifier(wv))
        logger.log("WebViewPool: created new WKWebView (active:\(inUse.count) pool:\(available.count))", category: .webView, level: .trace)
        return wv
    }

    func release(_ webView: WKWebView, wipeData: Bool = true) {
        let id = ObjectIdentifier(webView)
        inUse.remove(id)

        webView.stopLoading()

        if wipeData {
            webView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            webView.configuration.userContentController.removeAllUserScripts()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        }

        if available.count < maxPoolSize {
            available.append(webView)
            logger.log("WebViewPool: returned to pool (active:\(inUse.count) pool:\(available.count))", category: .webView, level: .trace)
        } else {
            webView.navigationDelegate = nil
            logger.log("WebViewPool: discarded (pool full) (active:\(inUse.count) pool:\(available.count))", category: .webView, level: .trace)
        }
    }

    func drainAll() {
        for wv in available {
            wv.stopLoading()
            wv.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
            wv.navigationDelegate = nil
        }
        available.removeAll()
        logger.log("WebViewPool: drained all (\(inUse.count) still in use)", category: .webView, level: .info)
    }
}
