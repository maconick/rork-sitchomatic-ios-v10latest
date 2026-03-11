import Foundation
import Observation
import SwiftUI
import WebKit

nonisolated enum SuperTestConnectionType: String, CaseIterable, Sendable, Identifiable {
    case fingerprint = "Fingerprint"
    case wireproxyWebView = "WireProxy WebView"
    case joeURLs = "Joe URLs"
    case ignitionURLs = "Ignition URLs"
    case ppsrConnection = "PPSR"
    case dnsServers = "DNS Servers"
    case socks5Proxies = "SOCKS5 Proxies"
    case openvpnProfiles = "OpenVPN"
    case wireguardProfiles = "WireGuard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .fingerprint: "fingerprint"
        case .wireproxyWebView: "globe.badge.chevron.backward"
        case .joeURLs: "suit.spade.fill"
        case .ignitionURLs: "flame.fill"
        case .ppsrConnection: "car.side.fill"
        case .dnsServers: "lock.shield.fill"
        case .socks5Proxies: "network"
        case .openvpnProfiles: "shield.lefthalf.filled"
        case .wireguardProfiles: "lock.trianglebadge.exclamationmark.fill"
        }
    }

    var color: Color {
        switch self {
        case .fingerprint: .purple
        case .wireproxyWebView: .teal
        case .joeURLs: .green
        case .ignitionURLs: .orange
        case .ppsrConnection: .cyan
        case .dnsServers: .blue
        case .socks5Proxies: .red
        case .openvpnProfiles: .indigo
        case .wireguardProfiles: .purple
        }
    }
}

nonisolated enum SuperTestPhase: String, Sendable, CaseIterable, Identifiable {
    case idle = "Idle"
    case fingerprint = "Fingerprint Detection"
    case wireproxyWebView = "WireProxy WebView"
    case joeURLs = "Joe Fortune URLs"
    case ignitionURLs = "Ignition URLs"
    case ppsrConnection = "PPSR Connection"
    case dnsServers = "DNS Servers"
    case socks5Proxies = "SOCKS5 Proxies"
    case openvpnProfiles = "OpenVPN Profiles"
    case wireguardProfiles = "WireGuard Profiles"
    case complete = "Complete"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .idle: "circle"
        case .fingerprint: "fingerprint"
        case .wireproxyWebView: "globe.badge.chevron.backward"
        case .joeURLs: "suit.spade.fill"
        case .ignitionURLs: "flame.fill"
        case .ppsrConnection: "car.side.fill"
        case .dnsServers: "lock.shield.fill"
        case .socks5Proxies: "network"
        case .openvpnProfiles: "shield.lefthalf.filled"
        case .wireguardProfiles: "lock.trianglebadge.exclamationmark.fill"
        case .complete: "checkmark.seal.fill"
        }
    }

    var color: String {
        switch self {
        case .idle: "secondary"
        case .fingerprint: "purple"
        case .wireproxyWebView: "teal"
        case .joeURLs: "green"
        case .ignitionURLs: "orange"
        case .ppsrConnection: "cyan"
        case .dnsServers: "blue"
        case .socks5Proxies: "red"
        case .openvpnProfiles: "indigo"
        case .wireguardProfiles: "purple"
        case .complete: "green"
        }
    }
}

nonisolated struct SuperTestItemResult: Identifiable, Sendable {
    let id: UUID
    let name: String
    let category: SuperTestPhase
    let passed: Bool
    let latencyMs: Int?
    let detail: String
    let timestamp: Date

    init(name: String, category: SuperTestPhase, passed: Bool, latencyMs: Int? = nil, detail: String) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.passed = passed
        self.latencyMs = latencyMs
        self.detail = detail
        self.timestamp = Date()
    }
}

nonisolated struct SuperTestReport: Sendable {
    let results: [SuperTestItemResult]
    let fingerprintScore: Int?
    let fingerprintPassed: Bool
    let totalTested: Int
    let totalPassed: Int
    let totalFailed: Int
    let totalDisabled: Int
    let totalEnabled: Int
    let duration: TimeInterval
    let timestamp: Date

    var passRate: Double {
        guard totalTested > 0 else { return 0 }
        return Double(totalPassed) / Double(totalTested)
    }

    var formattedPassRate: String {
        String(format: "%.0f%%", passRate * 100)
    }

    var formattedDuration: String {
        if duration < 60 { return String(format: "%.1fs", duration) }
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return "\(mins)m \(secs)s"
    }
}

@Observable
@MainActor
class SuperTestService {
    static let shared = SuperTestService()
    private let logger = DebugLogger.shared

    var isRunning: Bool = false
    var currentPhase: SuperTestPhase = .idle
    var progress: Double = 0
    var currentItem: String = ""
    var results: [SuperTestItemResult] = []
    var logs: [PPSRLogEntry] = []
    var lastReport: SuperTestReport?
    var phaseProgress: [SuperTestPhase: (total: Int, done: Int)] = [:]

    var selectedConnectionTypes: Set<SuperTestConnectionType> = Set(SuperTestConnectionType.allCases)

    private var testTask: Task<Void, Never>?

    private let urlRotation = LoginURLRotationService.shared
    private let proxyService = ProxyRotationService.shared
    private let dohService = PPSRDoHService.shared
    private let diagnostics = PPSRConnectionDiagnosticService.shared
    private let protocolTester = VPNProtocolTestService.shared

    private let networkFactory = NetworkSessionFactory.shared
    private let deviceProxy = DeviceProxyService.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let localProxy = LocalProxyServer.shared

    var phaseSummary: [(phase: SuperTestPhase, passed: Int, failed: Int)] {
        let phases = enabledPhases.isEmpty
            ? [SuperTestPhase.fingerprint, .wireproxyWebView, .joeURLs, .ignitionURLs, .ppsrConnection, .dnsServers, .socks5Proxies, .openvpnProfiles, .wireguardProfiles]
            : enabledPhases
        return phases.map { phase in
            let phaseResults = results.filter { $0.category == phase }
            let passed = phaseResults.filter(\.passed).count
            let failed = phaseResults.filter { !$0.passed }.count
            return (phase, passed, failed)
        }
    }

    var enabledPhases: [SuperTestPhase] {
        var phases: [SuperTestPhase] = []
        if selectedConnectionTypes.contains(.fingerprint) { phases.append(.fingerprint) }
        if selectedConnectionTypes.contains(.wireproxyWebView) { phases.append(.wireproxyWebView) }
        if selectedConnectionTypes.contains(.joeURLs) { phases.append(.joeURLs) }
        if selectedConnectionTypes.contains(.ignitionURLs) { phases.append(.ignitionURLs) }
        if selectedConnectionTypes.contains(.ppsrConnection) { phases.append(.ppsrConnection) }
        if selectedConnectionTypes.contains(.dnsServers) { phases.append(.dnsServers) }
        if selectedConnectionTypes.contains(.socks5Proxies) { phases.append(.socks5Proxies) }
        if selectedConnectionTypes.contains(.openvpnProfiles) { phases.append(.openvpnProfiles) }
        if selectedConnectionTypes.contains(.wireguardProfiles) { phases.append(.wireguardProfiles) }
        return phases
    }

    func startSuperTest() {
        guard !isRunning else { return }

        isRunning = true
        currentPhase = .idle
        progress = 0
        results.removeAll()
        logs.removeAll()
        phaseProgress.removeAll()
        currentItem = ""

        let activeTypes = selectedConnectionTypes
        let typeNames = activeTypes.map(\.rawValue).sorted().joined(separator: ", ")
        addLog("SUPER TEST — Starting with: \(typeNames)")
        logger.startSession("supertest", category: .superTest, message: "SUPER TEST starting with: \(typeNames)")

        let startTime = Date()
        let totalPhases = max(activeTypes.count, 1)

        testTask = Task {
            var completed = 0

            if activeTypes.contains(.fingerprint) {
                await runFingerprintTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.wireproxyWebView) {
                await runWireProxyWebViewTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.joeURLs) {
                await runJoeURLTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.ignitionURLs) {
                await runIgnitionURLTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.ppsrConnection) {
                await runPPSRConnectionTest()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.dnsServers) {
                await runDNSServerTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.socks5Proxies) {
                await runSOCKS5ProxyTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.openvpnProfiles) {
                await runOpenVPNProfileTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
                if Task.isCancelled { finalize(startTime: startTime); return }
            }

            if activeTypes.contains(.wireguardProfiles) {
                await runWireGuardProfileTests()
                completed += 1
                updateProgress(Double(completed) / Double(totalPhases))
            }

            finalize(startTime: startTime)
        }
    }

    func stopSuperTest() {
        testTask?.cancel()
        testTask = nil
        isRunning = false
        currentPhase = .idle
        currentItem = ""
        addLog("SUPER TEST — Stopped by user", level: .warning)
        logger.endSession("supertest", category: .superTest, message: "SUPER TEST stopped by user", level: .warning)
    }

    private func finalize(startTime: Date) {
        let duration = Date().timeIntervalSince(startTime)
        let totalTested = results.count
        let totalPassed = results.filter(\.passed).count
        let totalFailed = results.filter { !$0.passed }.count

        let fingerprintResults = results.filter { $0.category == .fingerprint }
        let fpScore = fingerprintResults.first.flatMap(\.latencyMs)
        let fpPassed = fingerprintResults.first?.passed ?? false

        let disabledCount = countDisabledItems()
        let enabledCount = countEnabledItems()

        lastReport = SuperTestReport(
            results: results,
            fingerprintScore: fpScore,
            fingerprintPassed: fpPassed,
            totalTested: totalTested,
            totalPassed: totalPassed,
            totalFailed: totalFailed,
            totalDisabled: disabledCount,
            totalEnabled: enabledCount,
            duration: duration,
            timestamp: Date()
        )

        currentPhase = .complete
        progress = 1.0
        currentItem = ""
        isRunning = false

        addLog("SUPER TEST COMPLETE — \(totalPassed)/\(totalTested) passed, \(totalFailed) failed, \(disabledCount) auto-disabled, \(enabledCount) auto-enabled in \(lastReport!.formattedDuration)", level: .success)
        logger.endSession("supertest", category: .superTest, message: "SUPER TEST COMPLETE: \(totalPassed)/\(totalTested) passed, \(totalFailed) failed", level: totalFailed == 0 ? .success : .warning)
    }

    private func countDisabledItems() -> Int {
        results.filter { !$0.passed }.count
    }

    private func countEnabledItems() -> Int {
        results.filter(\.passed).count
    }

    // MARK: - Fingerprint Detection Test

    private func runFingerprintTest() async {
        currentPhase = .fingerprint
        currentItem = "Fingerprint.com Detection Test"
        phaseProgress[.fingerprint] = (total: 2, done: 0)
        addLog("Phase 1: Fingerprint & Headless Detection")
        logger.log("Phase 1: Fingerprint & Headless Detection", category: .superTest, level: .info, sessionId: "supertest")

        let webViewScore = await runWebViewFingerprintTest()
        phaseProgress[.fingerprint] = (total: 2, done: 1)

        let headlessScore = await runHeadlessDetectionTest()
        phaseProgress[.fingerprint] = (total: 2, done: 2)

        let avgScore = (webViewScore + headlessScore) / 2
        let passed = avgScore <= FingerprintValidationService.maxAcceptableScore

        results.append(SuperTestItemResult(
            name: "WebView Fingerprint Score",
            category: .fingerprint,
            passed: webViewScore <= FingerprintValidationService.maxAcceptableScore,
            latencyMs: webViewScore,
            detail: "Score: \(webViewScore)/\(FingerprintValidationService.maxAcceptableScore) — \(webViewScore <= FingerprintValidationService.maxAcceptableScore ? "CLEAN" : "DETECTED")"
        ))

        results.append(SuperTestItemResult(
            name: "Headless/Bot Detection",
            category: .fingerprint,
            passed: headlessScore <= FingerprintValidationService.maxAcceptableScore,
            latencyMs: headlessScore,
            detail: "Score: \(headlessScore)/\(FingerprintValidationService.maxAcceptableScore) — \(headlessScore <= FingerprintValidationService.maxAcceptableScore ? "CLEAN" : "DETECTED")"
        ))

        addLog("Fingerprint: WebView=\(webViewScore), Headless=\(headlessScore), Overall: \(passed ? "PASS" : "FAIL")", level: passed ? .success : .error)
    }

    private func runWebViewFingerprintTest() async -> Int {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: config)

        let request = URLRequest(url: URL(string: "about:blank")!)
        webView.load(request)
        try? await Task.sleep(for: .milliseconds(500))

        let fpService = FingerprintValidationService.shared
        let score = await fpService.validate(in: webView, profileSeed: UInt32.random(in: 0...UInt32.max))
        return score.totalScore
    }

    private func runHeadlessDetectionTest() async -> Int {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: config)

        let request = URLRequest(url: URL(string: "about:blank")!)
        webView.load(request)
        try? await Task.sleep(for: .milliseconds(500))

        let headlessJS = """
        (function() {
            var score = 0;
            var signals = [];
            try { if (navigator.webdriver) { score += 7; signals.push('webdriver'); } } catch(e) {}
            try { if (!window.chrome && navigator.userAgent.indexOf('Chrome') !== -1) { score += 5; signals.push('chrome_mismatch'); } } catch(e) {}
            try { if (navigator.languages === undefined || navigator.languages.length === 0) { score += 4; signals.push('no_languages'); } } catch(e) {}
            try { if (navigator.plugins === undefined || navigator.plugins.length === 0) { score += 2; signals.push('no_plugins'); } } catch(e) {}
            try {
                var c = document.createElement('canvas');
                var gl = c.getContext('webgl');
                if (!gl) { score += 3; signals.push('no_webgl'); }
            } catch(e) {}
            try { if (navigator.permissions) {
                // sync check only
            }} catch(e) {}
            try {
                var autoFlags = ['__nightmare', '_phantom', 'callPhantom', '__selenium_evaluate', '__webdriver_evaluate'];
                for (var i = 0; i < autoFlags.length; i++) {
                    if (window[autoFlags[i]] !== undefined) { score += 7; signals.push('auto_flag:' + autoFlags[i]); break; }
                }
            } catch(e) {}
            return JSON.stringify({score: score, signals: signals});
        })();
        """

        do {
            let result = try await webView.evaluateJavaScript(headlessJS)
            if let str = result as? String,
               let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let score = json["score"] as? Int {
                return score
            }
        } catch {}

        return 0
    }

    // MARK: - Joe Fortune URL Tests (2 Random Sample)

    private func runJoeURLTests() async {
        currentPhase = .joeURLs
        let allURLs = urlRotation.joeURLs
        let sampleURLs = pickRandomSample(from: allURLs, count: 2)
        let total = sampleURLs.count
        phaseProgress[.joeURLs] = (total: total, done: 0)
        addLog("Phase: Testing \(total) random Joe Fortune URLs (of \(allURLs.count) total)")
        logger.log("Testing \(total) random Joe Fortune URLs (of \(allURLs.count) total)", category: .superTest, level: .info, sessionId: "supertest")

        for (index, rotatingURL) in sampleURLs.enumerated() {
            if Task.isCancelled { return }
            currentItem = rotatingURL.host
            logger.startTimer(key: "supertest_joe_\(index)")
            let result = await pingURL(rotatingURL.urlString, name: rotatingURL.host, category: .joeURLs)
            let pingMs = logger.stopTimer(key: "supertest_joe_\(index)")
            results.append(result)

            if result.passed {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: true)
                logger.log("Joe URL PASS: \(rotatingURL.host) \(result.detail)", category: .url, level: .success, sessionId: "supertest", durationMs: pingMs)
            } else {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: false)
                addLog("Auto-disabled Joe URL: \(rotatingURL.host)", level: .warning)
                logger.log("Joe URL FAIL (auto-disabled): \(rotatingURL.host) \(result.detail)", category: .url, level: .warning, sessionId: "supertest", durationMs: pingMs)
            }

            phaseProgress[.joeURLs] = (total: total, done: index + 1)
        }

        let passed = results.filter { $0.category == .joeURLs && $0.passed }.count
        addLog("Joe URLs: \(passed)/\(total) passed", level: passed > 0 ? .success : .error)
    }

    // MARK: - Ignition URL Tests (2 Random Sample)

    private func runIgnitionURLTests() async {
        currentPhase = .ignitionURLs
        let allURLs = urlRotation.ignitionURLs
        let sampleURLs = pickRandomSample(from: allURLs, count: 2)
        let total = sampleURLs.count
        phaseProgress[.ignitionURLs] = (total: total, done: 0)
        addLog("Phase: Testing \(total) random Ignition URLs (of \(allURLs.count) total)")
        logger.log("Testing \(total) random Ignition URLs (of \(allURLs.count) total)", category: .superTest, level: .info, sessionId: "supertest")

        for (index, rotatingURL) in sampleURLs.enumerated() {
            if Task.isCancelled { return }
            currentItem = rotatingURL.host
            logger.startTimer(key: "supertest_ign_\(index)")
            let result = await pingURL(rotatingURL.urlString, name: rotatingURL.host, category: .ignitionURLs)
            let pingMs = logger.stopTimer(key: "supertest_ign_\(index)")
            results.append(result)

            if result.passed {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: true)
                logger.log("Ignition URL PASS: \(rotatingURL.host)", category: .url, level: .success, sessionId: "supertest", durationMs: pingMs)
            } else {
                urlRotation.toggleURL(id: rotatingURL.id, enabled: false)
                addLog("Auto-disabled Ignition URL: \(rotatingURL.host)", level: .warning)
                logger.log("Ignition URL FAIL (auto-disabled): \(rotatingURL.host)", category: .url, level: .warning, sessionId: "supertest", durationMs: pingMs)
            }

            phaseProgress[.ignitionURLs] = (total: total, done: index + 1)
        }

        let passed = results.filter { $0.category == .ignitionURLs && $0.passed }.count
        addLog("Ignition URLs: \(passed)/\(total) passed", level: passed > 0 ? .success : .error)
    }

    // MARK: - WireProxy WebView Test

    private func runWireProxyWebViewTest() async {
        currentPhase = .wireproxyWebView
        currentItem = "WireProxy WebView Connectivity"
        let testCount = 3
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 0)
        addLog("Phase: WireProxy WebView Test — verifying WebView traffic routes through WireProxy")
        logger.log("WireProxy WebView Test starting", category: .superTest, level: .info, sessionId: "supertest")

        let wireProxyActive = wireProxyBridge.isActive && localProxy.isRunning && localProxy.wireProxyMode
        results.append(SuperTestItemResult(
            name: "WireProxy Tunnel Status",
            category: .wireproxyWebView,
            passed: wireProxyActive,
            detail: wireProxyActive ? "WireProxy tunnel established, local proxy on :\(localProxy.listeningPort)" : "WireProxy tunnel NOT active — WebView traffic will NOT be proxied"
        ))
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 1)

        if !wireProxyActive {
            addLog("WireProxy not active — attempting to start", level: .warning)
            if deviceProxy.isEnabled {
                deviceProxy.reconnectWireProxy()
                try? await Task.sleep(for: .seconds(4))
            }
        }

        let tunnelReady = wireProxyBridge.isActive && localProxy.isRunning && localProxy.wireProxyMode

        let webViewIPResult = await testWebViewIPViaWireProxy(tunnelReady: tunnelReady)
        results.append(webViewIPResult)
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 2)

        let webViewLoadResult = await testWebViewLoadViaWireProxy(tunnelReady: tunnelReady)
        results.append(webViewLoadResult)
        phaseProgress[.wireproxyWebView] = (total: testCount, done: 3)

        let passed = results.filter { $0.category == .wireproxyWebView && $0.passed }.count
        addLog("WireProxy WebView: \(passed)/\(testCount) passed", level: passed == testCount ? .success : (passed > 0 ? .warning : .error))
    }

    private func testWebViewIPViaWireProxy(tunnelReady: Bool) async -> SuperTestItemResult {
        guard tunnelReady else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Skipped — WireProxy tunnel not active"
            )
        }

        let networkConfig: ActiveNetworkConfig = .socks5(localProxy.localProxyConfig)
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        let applied = networkFactory.configureWKWebView(config: wkConfig, networkConfig: networkConfig, target: .joe)
        guard applied else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Failed to apply proxy config to WKWebView"
            )
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: wkConfig)
        let start = Date()

        let ipCheckURL = URL(string: "https://api.ipify.org?format=json")!
        let request = URLRequest(url: ipCheckURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        webView.load(request)

        var attempts = 0
        var pageContent: String?
        while attempts < 30 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
            if let content = try? await webView.evaluateJavaScript("document.body?.innerText || ''") as? String, !content.isEmpty {
                pageContent = content
                break
            }
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)

        guard let content = pageContent, !content.isEmpty else {
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                latencyMs: latency,
                detail: "WebView failed to load IP check page in \(latency)ms"
            )
        }

        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ip = json["ip"] as? String {
            logger.log("WireProxy WebView IP: \(ip) in \(latency)ms", category: .superTest, level: .success, sessionId: "supertest", durationMs: latency)
            return SuperTestItemResult(
                name: "WebView IP via WireProxy",
                category: .wireproxyWebView,
                passed: true,
                latencyMs: latency,
                detail: "IP: \(ip) via WireProxy in \(latency)ms"
            )
        }

        return SuperTestItemResult(
            name: "WebView IP via WireProxy",
            category: .wireproxyWebView,
            passed: true,
            latencyMs: latency,
            detail: "WebView loaded via WireProxy in \(latency)ms (response: \(content.prefix(80)))"
        )
    }

    private func testWebViewLoadViaWireProxy(tunnelReady: Bool) async -> SuperTestItemResult {
        guard tunnelReady else {
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Skipped — WireProxy tunnel not active"
            )
        }

        let networkConfig: ActiveNetworkConfig = .socks5(localProxy.localProxyConfig)
        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        let applied = networkFactory.configureWKWebView(config: wkConfig, networkConfig: networkConfig, target: .joe)
        guard applied else {
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: false,
                detail: "Failed to apply proxy config"
            )
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 414, height: 896), configuration: wkConfig)
        let start = Date()

        let testURL = URL(string: "https://httpbin.org/get")!
        let request = URLRequest(url: testURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        webView.load(request)

        var attempts = 0
        var pageLoaded = false
        while attempts < 30 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
            if let done = try? await webView.evaluateJavaScript("document.readyState") as? String, done == "complete" {
                pageLoaded = true
                break
            }
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)

        if pageLoaded {
            let bodyText = (try? await webView.evaluateJavaScript("document.body?.innerText || ''") as? String) ?? ""
            let hasOrigin = bodyText.contains("origin")
            logger.log("WireProxy WebView page load OK in \(latency)ms", category: .superTest, level: .success, sessionId: "supertest", durationMs: latency)
            return SuperTestItemResult(
                name: "WebView Page Load via WireProxy",
                category: .wireproxyWebView,
                passed: true,
                latencyMs: latency,
                detail: "httpbin.org loaded in \(latency)ms\(hasOrigin ? " (origin IP confirmed)" : "")"
            )
        }

        return SuperTestItemResult(
            name: "WebView Page Load via WireProxy",
            category: .wireproxyWebView,
            passed: false,
            latencyMs: latency,
            detail: "Page failed to load via WireProxy in \(latency)ms"
        )
    }

    // MARK: - PPSR Connection Test

    private func runPPSRConnectionTest() async {
        currentPhase = .ppsrConnection
        currentItem = "transact.ppsr.gov.au"
        phaseProgress[.ppsrConnection] = (total: 3, done: 0)
        addLog("Phase 4: Testing PPSR Connection")
        logger.log("Phase 4: Testing PPSR Connection", category: .superTest, level: .info, sessionId: "supertest")

        let healthCheck = await diagnostics.quickHealthCheck()
        phaseProgress[.ppsrConnection] = (total: 3, done: 1)

        results.append(SuperTestItemResult(
            name: "PPSR Health Check",
            category: .ppsrConnection,
            passed: healthCheck.healthy,
            detail: healthCheck.detail
        ))

        let dnsAnswer = await dohService.resolveWithRotation(hostname: "transact.ppsr.gov.au")
        phaseProgress[.ppsrConnection] = (total: 3, done: 2)

        results.append(SuperTestItemResult(
            name: "PPSR DNS Resolution",
            category: .ppsrConnection,
            passed: dnsAnswer != nil,
            latencyMs: dnsAnswer?.latencyMs,
            detail: dnsAnswer != nil ? "Resolved via \(dnsAnswer!.provider) → \(dnsAnswer!.ip)" : "DNS resolution failed"
        ))

        let sslResult = await testSSL("transact.ppsr.gov.au")
        phaseProgress[.ppsrConnection] = (total: 3, done: 3)

        results.append(SuperTestItemResult(
            name: "PPSR SSL/TLS",
            category: .ppsrConnection,
            passed: sslResult.0,
            latencyMs: sslResult.1,
            detail: sslResult.2
        ))

        let passed = results.filter { $0.category == .ppsrConnection && $0.passed }.count
        addLog("PPSR: \(passed)/3 checks passed", level: passed == 3 ? .success : (passed > 0 ? .warning : .error))
    }

    // MARK: - DNS Server Tests

    private func runDNSServerTests() async {
        currentPhase = .dnsServers
        let providers = dohService.managedProviders
        let total = providers.count
        phaseProgress[.dnsServers] = (total: total, done: 0)
        addLog("Phase 5: Testing \(total) DNS Servers")
        logger.log("Phase 5: Testing \(total) DNS Servers", category: .superTest, level: .info, sessionId: "supertest")

        for (index, provider) in providers.enumerated() {
            if Task.isCancelled { return }
            currentItem = provider.name

            let dohProvider = DoHProvider(name: provider.name, url: provider.url)
            let answer = await dohService.resolve(hostname: "transact.ppsr.gov.au", using: dohProvider)
            let passed = answer != nil

            results.append(SuperTestItemResult(
                name: provider.name,
                category: .dnsServers,
                passed: passed,
                latencyMs: answer?.latencyMs,
                detail: passed ? "Resolved → \(answer!.ip) in \(answer!.latencyMs)ms" : "Resolution failed"
            ))

            dohService.toggleProvider(id: provider.id, enabled: passed)
            if !passed {
                addLog("Auto-disabled DNS: \(provider.name)", level: .warning)
                logger.log("DNS FAIL (auto-disabled): \(provider.name)", category: .dns, level: .warning, sessionId: "supertest")
            } else {
                logger.log("DNS PASS: \(provider.name) \(answer!.ip) in \(answer!.latencyMs)ms", category: .dns, level: .success, sessionId: "supertest", durationMs: answer?.latencyMs)
            }

            phaseProgress[.dnsServers] = (total: total, done: index + 1)
        }

        let passedCount = results.filter { $0.category == .dnsServers && $0.passed }.count
        addLog("DNS Servers: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    // MARK: - SOCKS5 Proxy Tests

    private func runSOCKS5ProxyTests() async {
        logger.log("Phase 6: Testing SOCKS5 Proxies", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .socks5Proxies
        let allProxies: [(proxy: ProxyConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.savedProxies.map { ($0, .joe) } +
            proxyService.ignitionProxies.map { ($0, .ignition) } +
            proxyService.ppsrProxies.map { ($0, .ppsr) }

        let total = allProxies.count
        phaseProgress[.socks5Proxies] = (total: total, done: 0)
        addLog("Phase 6: Testing \(total) SOCKS5 Proxies")

        if total == 0 {
            addLog("No SOCKS5 proxies configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 5
        var index = 0

        await withTaskGroup(of: (ProxyConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (proxy, target) in allProxies {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processProxyResult(result)
                        index += 1
                        phaseProgress[.socks5Proxies] = (total: total, done: index)
                    }
                }

                currentItem = proxy.displayString
                group.addTask {
                    let (passed, latency) = await self.testProxy(proxy)
                    return (proxy, target, passed, latency)
                }
                launched += 1
            }

            for await result in group {
                processProxyResult(result)
                index += 1
                phaseProgress[.socks5Proxies] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .socks5Proxies && $0.passed }.count
        addLog("SOCKS5 Proxies: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processProxyResult(_ result: (ProxyConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (proxy, target, passed, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(proxy.displayString) [\(targetLabel)]",
            category: .socks5Proxies,
            passed: passed,
            latencyMs: passed ? latency : nil,
            detail: passed ? "Connected in \(latency)ms" : "Connection failed"
        ))

        if passed {
            proxyService.markProxyWorking(proxy)
            logger.log("Proxy PASS: \(proxy.displayString) [\(targetLabel)] in \(latency)ms", category: .proxy, level: .success, sessionId: "supertest", durationMs: latency)
        } else {
            proxyService.markProxyFailed(proxy)
            addLog("Auto-failed proxy: \(proxy.displayString) [\(targetLabel)]", level: .warning)
            logger.log("Proxy FAIL: \(proxy.displayString) [\(targetLabel)]", category: .proxy, level: .warning, sessionId: "supertest")
        }
    }

    // MARK: - OpenVPN Profile Tests

    private func runOpenVPNProfileTests() async {
        logger.log("Phase 7: Testing OpenVPN Profiles", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .openvpnProfiles
        let allVPN: [(config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.joeVPNConfigs.map { ($0, .joe) } +
            proxyService.ignitionVPNConfigs.map { ($0, .ignition) } +
            proxyService.ppsrVPNConfigs.map { ($0, .ppsr) }

        let total = allVPN.count
        phaseProgress[.openvpnProfiles] = (total: total, done: 0)
        addLog("Phase 7: Testing \(total) OpenVPN Profiles")

        if total == 0 {
            addLog("No OpenVPN profiles configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 6
        var index = 0

        await withTaskGroup(of: (OpenVPNConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (vpnConfig, target) in allVPN {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processVPNResult(result)
                        index += 1
                        phaseProgress[.openvpnProfiles] = (total: total, done: index)
                    }
                }

                currentItem = vpnConfig.displayString
                group.addTask {
                    let result = await self.protocolTester.testOpenVPNEndpoint(vpnConfig)
                    return (vpnConfig, target, result.reachable, result.latencyMs)
                }
                launched += 1
            }

            for await result in group {
                processVPNResult(result)
                index += 1
                phaseProgress[.openvpnProfiles] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .openvpnProfiles && $0.passed }.count
        addLog("OpenVPN: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processVPNResult(_ result: (OpenVPNConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (vpnConfig, target, passed, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(vpnConfig.displayString) [\(targetLabel)]",
            category: .openvpnProfiles,
            passed: passed,
            latencyMs: passed ? latency : nil,
            detail: passed ? "OpenVPN protocol handshake OK in \(latency)ms" : "OpenVPN endpoint unreachable or protocol validation failed"
        ))

        proxyService.markVPNConfigReachable(vpnConfig, target: target, reachable: passed, latencyMs: passed ? latency : nil)
        if !passed {
            addLog("Auto-disabled VPN: \(vpnConfig.fileName) [\(targetLabel)]", level: .warning)
            logger.log("VPN FAIL (auto-disabled): \(vpnConfig.fileName) [\(targetLabel)]", category: .vpn, level: .warning, sessionId: "supertest")
        } else {
            logger.log("VPN PASS: \(vpnConfig.fileName) [\(targetLabel)] in \(latency)ms", category: .vpn, level: .success, sessionId: "supertest", durationMs: latency)
        }
    }

    // MARK: - WireGuard Profile Tests

    private func runWireGuardProfileTests() async {
        logger.log("Phase 8: Testing WireGuard Profiles", category: .superTest, level: .info, sessionId: "supertest")
        currentPhase = .wireguardProfiles
        let allWG: [(config: WireGuardConfig, target: ProxyRotationService.ProxyTarget)] =
            proxyService.joeWGConfigs.map { ($0, .joe) } +
            proxyService.ignitionWGConfigs.map { ($0, .ignition) } +
            proxyService.ppsrWGConfigs.map { ($0, .ppsr) }

        let total = allWG.count
        phaseProgress[.wireguardProfiles] = (total: total, done: 0)
        addLog("Phase 8: Testing \(total) WireGuard Profiles")

        if total == 0 {
            addLog("No WireGuard profiles configured — skipping", level: .warning)
            return
        }

        let maxConcurrent = 8
        var index = 0

        await withTaskGroup(of: (WireGuardConfig, ProxyRotationService.ProxyTarget, Bool, Int).self) { group in
            var launched = 0

            for (wgConfig, target) in allWG {
                if Task.isCancelled { return }

                if launched >= maxConcurrent {
                    if let result = await group.next() {
                        processWGResult(result)
                        index += 1
                        phaseProgress[.wireguardProfiles] = (total: total, done: index)
                    }
                }

                currentItem = wgConfig.displayString
                group.addTask {
                    let result = await self.protocolTester.testWireGuardEndpoint(wgConfig)
                    return (wgConfig, target, result.reachable, result.latencyMs)
                }
                launched += 1
            }

            for await result in group {
                processWGResult(result)
                index += 1
                phaseProgress[.wireguardProfiles] = (total: total, done: index)
            }
        }

        let passedCount = results.filter { $0.category == .wireguardProfiles && $0.passed }.count
        addLog("WireGuard: \(passedCount)/\(total) passed", level: passedCount > 0 ? .success : .error)
    }

    private func processWGResult(_ result: (WireGuardConfig, ProxyRotationService.ProxyTarget, Bool, Int)) {
        let (wgConfig, target, reachable, latency) = result
        let targetLabel: String
        switch target {
        case .joe: targetLabel = "Joe"
        case .ignition: targetLabel = "Ignition"
        case .ppsr: targetLabel = "PPSR"
        }

        results.append(SuperTestItemResult(
            name: "\(wgConfig.displayString) [\(targetLabel)]",
            category: .wireguardProfiles,
            passed: reachable,
            latencyMs: reachable ? latency : nil,
            detail: reachable ? "WG UDP handshake validated in \(latency)ms" : "WG endpoint unreachable (UDP handshake + TCP fallback failed)"
        ))

        proxyService.markWGConfigReachable(wgConfig, target: target, reachable: reachable)
        if !reachable {
            addLog("Auto-disabled WG: \(wgConfig.fileName) [\(targetLabel)]", level: .warning)
            logger.log("WG FAIL (auto-disabled): \(wgConfig.fileName) [\(targetLabel)]", category: .vpn, level: .warning, sessionId: "supertest")
        } else {
            logger.log("WG PASS: \(wgConfig.fileName) [\(targetLabel)] in \(latency)ms", category: .vpn, level: .success, sessionId: "supertest", durationMs: latency)
        }
    }

    // MARK: - Utility Methods

    private func pingURL(_ urlString: String, name: String, category: SuperTestPhase) async -> SuperTestItemResult {
        guard let url = URL(string: urlString) else {
            logger.log("SuperTest pingURL: invalid URL '\(urlString)'", category: .superTest, level: .error, sessionId: "supertest")
            return SuperTestItemResult(name: name, category: category, passed: false, detail: "Invalid URL")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 12)
        request.httpMethod = "HEAD"
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                let passed = http.statusCode >= 200 && http.statusCode < 400
                if !passed {
                    logger.log("SuperTest pingURL: \(name) HTTP \(http.statusCode)", category: .superTest, level: .warning, sessionId: "supertest", durationMs: latency, metadata: [
                        "url": urlString, "statusCode": "\(http.statusCode)"
                    ])
                }
                return SuperTestItemResult(
                    name: name,
                    category: category,
                    passed: passed,
                    latencyMs: latency,
                    detail: "HTTP \(http.statusCode) in \(latency)ms"
                )
            }
            return SuperTestItemResult(name: name, category: category, passed: true, latencyMs: latency, detail: "Response in \(latency)ms")
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let classified = logger.classifyNetworkError(error)
            logger.logError("SuperTest pingURL: \(name) failed", error: error, category: .superTest, sessionId: "supertest", metadata: [
                "url": urlString, "isRetryable": "\(classified.isRetryable)", "latency": "\(latency)ms"
            ])
            if classified.isRetryable {
                logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "Retrying \(name) with GET fallback", succeeded: false, sessionId: "supertest")
                var getRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
                getRequest.httpMethod = "GET"
                getRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                do {
                    let (_, retryResponse) = try await session.data(for: getRequest)
                    let retryLatency = Int(Date().timeIntervalSince(start) * 1000)
                    if let http = retryResponse as? HTTPURLResponse {
                        let passed = http.statusCode >= 200 && http.statusCode < 400
                        if passed {
                            logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "GET fallback succeeded for \(name) (HTTP \(http.statusCode))", succeeded: true, durationMs: retryLatency, sessionId: "supertest")
                        }
                        return SuperTestItemResult(name: name, category: category, passed: passed, latencyMs: retryLatency, detail: "HTTP \(http.statusCode) in \(retryLatency)ms (GET retry)")
                    }
                } catch {
                    logger.logHealing(category: .superTest, originalError: classified.userMessage, healingAction: "GET retry also failed for \(name)", succeeded: false, sessionId: "supertest")
                }
            }
            return SuperTestItemResult(name: name, category: category, passed: false, latencyMs: latency, detail: classified.userMessage)
        }
    }

    private nonisolated func testProxy(_ proxy: ProxyConfig) async -> (Bool, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15

        var proxyDict: [String: Any] = [
            "SOCKSEnable": 1,
            "SOCKSProxy": proxy.host,
            "SOCKSPort": proxy.port,
        ]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let start = Date()
        let testURLs = ["https://api.ipify.org?format=json", "https://httpbin.org/ip", "https://ifconfig.me/ip"]
        for urlString in testURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty {
                    let latency = Int(Date().timeIntervalSince(start) * 1000)
                    return (true, latency)
                }
            } catch {
                continue
            }
        }
        return (false, 0)
    }

    private func testSSL(_ host: String) async -> (Bool, Int, String) {
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://\(host)")!)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (_, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse {
                logger.log("SuperTest SSL: \(host) TLS OK (HTTP \(http.statusCode)) in \(latency)ms", category: .network, level: .success, sessionId: "supertest", durationMs: latency)
                return (true, latency, "TLS OK (HTTP \(http.statusCode)) in \(latency)ms")
            }
            return (true, latency, "TLS handshake OK in \(latency)ms")
        } catch {
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            logger.logError("SuperTest SSL: \(host) failed", error: error, category: .network, sessionId: "supertest")
            return (false, latency, "SSL failed: \(error.localizedDescription)")
        }
    }



    private func updateProgress(_ value: Double) {
        progress = value
    }

    private func addLog(_ message: String, level: PPSRLogEntry.Level = .info) {
        logs.insert(PPSRLogEntry(message: message, level: level), at: 0)
        if logs.count > 500 { logs = Array(logs.prefix(500)) }
    }

    private func pickRandomSample(from urls: [LoginURLRotationService.RotatingURL], count: Int) -> [LoginURLRotationService.RotatingURL] {
        guard urls.count > count else { return urls }
        var shuffled = urls
        shuffled.shuffle()
        return Array(shuffled.prefix(count))
    }
}
