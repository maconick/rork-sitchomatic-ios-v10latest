import Foundation
import WebKit

@MainActor
class WebViewPool {
    static let shared = WebViewPool()

    private var inUseCount: Int = 0
    private let logger = DebugLogger.shared
    private(set) var processTerminationCount: Int = 0
    private let networkFactory = NetworkSessionFactory.shared
    private var preWarmedViews: [WKWebView] = []
    private let maxPreWarmed: Int = 3
    private(set) var preWarmCount: Int = 0

    var activeCount: Int { inUseCount }
    var preWarmedCount: Int { preWarmedViews.count }

    func preWarm(count: Int = 2, stealthEnabled: Bool = true, networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) {
        let toCreate = min(count, maxPreWarmed - preWarmedViews.count)
        guard toCreate > 0 else { return }

        for _ in 0..<toCreate {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.preferences.javaScriptCanOpenWindowsAutomatically = true
            config.defaultWebpagePreferences.allowsContentJavaScript = true

            let _ = networkFactory.configureWKWebView(config: config, networkConfig: networkConfig, target: target)

            let wv: WKWebView
            if stealthEnabled {
                let stealth = PPSRStealthService.shared
                let profile = stealth.nextProfile()
                let userScript = stealth.createStealthUserScript(profile: profile)
                config.userContentController.addUserScript(userScript)
                wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
                wv.customUserAgent = profile.userAgent
            } else {
                wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)), configuration: config)
                wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            }
            preWarmedViews.append(wv)
        }
        preWarmCount += toCreate
        logger.log("WebViewPool: pre-warmed \(toCreate) WebViews (pool: \(preWarmedViews.count))", category: .webView, level: .info)
    }

    func acquirePreWarmed() -> WKWebView? {
        guard !preWarmedViews.isEmpty else { return nil }
        let wv = preWarmedViews.removeFirst()
        inUseCount += 1
        logger.log("WebViewPool: acquired pre-warmed WebView (remaining: \(preWarmedViews.count), active: \(inUseCount))", category: .webView, level: .trace)
        return wv
    }

    func drainPreWarmed() {
        for wv in preWarmedViews {
            wv.stopLoading()
            wv.configuration.userContentController.removeAllUserScripts()
        }
        let count = preWarmedViews.count
        preWarmedViews.removeAll()
        if count > 0 {
            logger.log("WebViewPool: drained \(count) pre-warmed WebViews", category: .webView, level: .debug)
        }
    }

    func acquire(stealthEnabled: Bool = false, viewportSize: CGSize = CGSize(width: 390, height: 844), networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) async -> WKWebView {
        var effectiveConfig = networkConfig
        if case .socks5 = networkFactory.resolveEffectiveConfigPublic(networkConfig) {
            effectiveConfig = await networkFactory.preflightProxyCheck(for: networkConfig, target: target)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = networkFactory.configureWKWebView(config: config, networkConfig: effectiveConfig, target: target)
        if !proxyApplied {
            logger.log("WebViewPool: BLOCKED — no proxy available for \(target.rawValue), WebView created but may use real IP", category: .webView, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
            wv.customUserAgent = profile.userAgent
            inUseCount += 1
            logger.log("WebViewPool: acquired stealth WKWebView network=\(effectiveConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
            return wv
        }

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        inUseCount += 1
        logger.log("WebViewPool: created WKWebView network=\(effectiveConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
        return wv
    }

    func acquireSync(stealthEnabled: Bool = false, viewportSize: CGSize = CGSize(width: 390, height: 844), networkConfig: ActiveNetworkConfig = .direct, target: ProxyRotationService.ProxyTarget = .joe) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let proxyApplied = networkFactory.configureWKWebView(config: config, networkConfig: networkConfig, target: target)
        if !proxyApplied {
            logger.log("WebViewPool: BLOCKED — no proxy available for \(target.rawValue), WebView created but may use real IP", category: .webView, level: .error)
        }

        if stealthEnabled {
            let stealth = PPSRStealthService.shared
            let profile = stealth.nextProfile()
            let userScript = stealth.createStealthUserScript(profile: profile)
            config.userContentController.addUserScript(userScript)

            let wv = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: profile.viewport.width, height: profile.viewport.height)), configuration: config)
            wv.customUserAgent = profile.userAgent
            inUseCount += 1
            logger.log("WebViewPool: acquired stealth WKWebView network=\(networkConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
            return wv
        }

        let wv = WKWebView(frame: CGRect(origin: .zero, size: viewportSize), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        inUseCount += 1
        logger.log("WebViewPool: created WKWebView network=\(networkConfig.label) (active:\(inUseCount))", category: .webView, level: .trace)
        return wv
    }

    func release(_ webView: WKWebView, wipeData: Bool = true) {
        guard inUseCount > 0 else {
            logger.log("WebViewPool: release called but inUseCount already 0 — possible double-release", category: .webView, level: .warning)
            return
        }
        inUseCount -= 1

        webView.stopLoading()

        if wipeData {
            let dataStore = webView.configuration.websiteDataStore
            dataStore.proxyConfigurations = []
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) { }
            webView.configuration.userContentController.removeAllUserScripts()
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        }

        webView.navigationDelegate = nil
        logger.log("WebViewPool: released (active:\(inUseCount))", category: .webView, level: .trace)
    }

    func handleMemoryPressure() {
        let drained = preWarmedViews.count
        drainPreWarmed()
        if drained > 0 {
            logger.log("WebViewPool: memory pressure — drained \(drained) pre-warmed views (\(inUseCount) active)", category: .webView, level: .warning)
        } else {
            logger.log("WebViewPool: memory pressure noted (\(inUseCount) active, 0 pre-warmed)", category: .webView, level: .warning)
        }
    }

    func reportProcessTermination() {
        processTerminationCount += 1
        logger.log("WebViewPool: WebKit content process terminated (total: \(processTerminationCount))", category: .webView, level: .error)
        AppAlertManager.shared.pushWarning(
            source: .webView,
            title: "WebView Crash",
            message: "A WebKit content process was terminated. The session will be retried automatically."
        )
    }
}
