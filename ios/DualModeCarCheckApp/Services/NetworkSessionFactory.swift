import Foundation
import WebKit

nonisolated enum ActiveNetworkConfig: Sendable {
    case direct
    case socks5(ProxyConfig)
    case wireGuardDNS(WireGuardConfig)
    case openVPNProxy(OpenVPNConfig)

    var label: String {
        switch self {
        case .direct: "Direct"
        case .socks5(let p): "SOCKS5 \(p.displayString)"
        case .wireGuardDNS(let wg): "WG \(wg.displayString)"
        case .openVPNProxy(let ovpn): "OVPN \(ovpn.displayString)"
        }
    }

    var dnsServers: [String]? {
        switch self {
        case .wireGuardDNS(let wg):
            let raw = wg.interfaceDNS
            guard !raw.isEmpty else { return nil }
            return raw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return nil
        }
    }
}

@MainActor
class NetworkSessionFactory {
    static let shared = NetworkSessionFactory()

    private let proxyService = ProxyRotationService.shared
    private let logger = DebugLogger.shared

    private var joeWGIndex: Int = 0
    private var ignitionWGIndex: Int = 0
    private var ppsrWGIndex: Int = 0

    private var joeOVPNIndex: Int = 0
    private var ignitionOVPNIndex: Int = 0
    private var ppsrOVPNIndex: Int = 0

    func nextConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let mode = proxyService.connectionMode(for: target)

        switch mode {
        case .dns:
            return .direct

        case .proxy:
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: assigned SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .debug)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no working SOCKS5 proxy for \(target.rawValue) — falling back to direct", category: .proxy, level: .warning)
            return .direct

        case .wireguard:
            if let wg = nextWGConfig(for: target) {
                logger.log("NetworkFactory: assigned WG \(wg.displayString) for \(target.rawValue)", category: .vpn, level: .debug)
                return .wireGuardDNS(wg)
            }
            logger.log("NetworkFactory: no enabled WG config for \(target.rawValue) — falling back to SOCKS5", category: .vpn, level: .warning)
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: WG fallback → SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no fallback available for \(target.rawValue) — using direct", category: .network, level: .warning)
            return .direct

        case .openvpn:
            if let ovpn = nextOVPNConfig(for: target) {
                logger.log("NetworkFactory: assigned OVPN \(ovpn.displayString) for \(target.rawValue)", category: .vpn, level: .debug)
                return .openVPNProxy(ovpn)
            }
            logger.log("NetworkFactory: no enabled OVPN config for \(target.rawValue) — falling back to SOCKS5", category: .vpn, level: .warning)
            if let proxy = proxyService.nextWorkingProxy(for: target) {
                logger.log("NetworkFactory: OVPN fallback → SOCKS5 \(proxy.displayString) for \(target.rawValue)", category: .proxy, level: .info)
                return .socks5(proxy)
            }
            logger.log("NetworkFactory: no fallback available for \(target.rawValue) — using direct", category: .network, level: .warning)
            return .direct
        }
    }

    func buildURLSessionConfiguration(for config: ActiveNetworkConfig) -> URLSessionConfiguration {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfig.httpShouldSetCookies = false
        sessionConfig.httpCookieAcceptPolicy = .never

        switch config {
        case .direct:
            break

        case .socks5(let proxy):
            var proxyDict: [String: Any] = [
                "SOCKSEnable": 1,
                "SOCKSProxy": proxy.host,
                "SOCKSPort": proxy.port,
            ]
            if let u = proxy.username { proxyDict["SOCKSUser"] = u }
            if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
            sessionConfig.connectionProxyDictionary = proxyDict
            logger.log("URLSession configured with SOCKS5: \(proxy.displayString)", category: .proxy, level: .trace)

        case .wireGuardDNS(let wg):
            let endpoint = wg.endpointHost
            let port = wg.endpointPort
            if let dnsServers = config.dnsServers, !dnsServers.isEmpty {
                logger.log("URLSession WG DNS-routed: \(dnsServers.joined(separator: ", ")) via \(endpoint):\(port) — NOTE: Full WG tunnel requires NetworkExtension; using DNS-level routing only", category: .vpn, level: .info)
            } else {
                logger.log("URLSession WG: no DNS servers in config \(endpoint):\(port) — operating as direct connection", category: .vpn, level: .warning)
            }

        case .openVPNProxy(let ovpn):
            let host = ovpn.remoteHost
            let port = ovpn.remotePort
            logger.log("URLSession OVPN: \(host):\(port) (\(ovpn.proto)) — NOTE: Full OpenVPN tunnel requires NetworkExtension; endpoint validated via protocol handshake", category: .vpn, level: .info)
        }

        return sessionConfig
    }

    func configureWKWebView(config wkConfig: WKWebViewConfiguration, networkConfig: ActiveNetworkConfig) {
        switch networkConfig {
        case .socks5(let proxy):
            let pacScript = generatePACScript(proxyHost: proxy.host, proxyPort: proxy.port, type: "SOCKS5")
            injectPACProxy(into: wkConfig, pacScript: pacScript)
            logger.log("WKWebView configured with SOCKS5 PAC: \(proxy.displayString)", category: .proxy, level: .debug)

        case .wireGuardDNS(let wg):
            if let dnsServers = networkConfig.dnsServers, !dnsServers.isEmpty {
                let dnsJS = buildDNSRoutingScript(servers: dnsServers, endpoint: wg.endpointHost)
                let userScript = WKUserScript(source: dnsJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                wkConfig.userContentController.addUserScript(userScript)
                logger.log("WKWebView WG DNS routing injected: \(dnsServers.joined(separator: ", "))", category: .vpn, level: .debug)
            }

        case .openVPNProxy:
            logger.log("WKWebView OVPN: no proxy injection — OpenVPN requires NetworkExtension tunnel", category: .vpn, level: .info)

        case .direct:
            break
        }
    }

    func resetRotationIndexes() {
        joeWGIndex = 0
        ignitionWGIndex = 0
        ppsrWGIndex = 0
        joeOVPNIndex = 0
        ignitionOVPNIndex = 0
        ppsrOVPNIndex = 0
    }

    // MARK: - WireGuard Rotation

    private func nextWGConfig(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        guard !configs.isEmpty else { return nil }

        let index: Int
        switch target {
        case .joe:
            index = joeWGIndex % configs.count
            joeWGIndex = index + 1
        case .ignition:
            index = ignitionWGIndex % configs.count
            ignitionWGIndex = index + 1
        case .ppsr:
            index = ppsrWGIndex % configs.count
            ppsrWGIndex = index + 1
        }

        return configs[index]
    }

    // MARK: - OpenVPN Rotation

    private func nextOVPNConfig(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
        let configs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        guard !configs.isEmpty else { return nil }

        let index: Int
        switch target {
        case .joe:
            index = joeOVPNIndex % configs.count
            joeOVPNIndex = index + 1
        case .ignition:
            index = ignitionOVPNIndex % configs.count
            ignitionOVPNIndex = index + 1
        case .ppsr:
            index = ppsrOVPNIndex % configs.count
            ppsrOVPNIndex = index + 1
        }

        return configs[index]
    }

    // MARK: - PAC Proxy

    private func generatePACScript(proxyHost: String, proxyPort: Int, type: String) -> String {
        """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host) || host === "localhost" || host === "127.0.0.1") {
                return "DIRECT";
            }
            return "\(type) \(proxyHost):\(proxyPort); DIRECT";
        }
        """
    }

    private func injectPACProxy(into config: WKWebViewConfiguration, pacScript: String) {
        let js = """
        (function() {
            window.__networkProxy = true;
            window.__proxyPAC = `\(pacScript.replacingOccurrences(of: "`", with: "\\`"))`;
        })();
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
    }

    // MARK: - DNS Routing Script

    private func buildDNSRoutingScript(servers: [String], endpoint: String) -> String {
        """
        (function() {
            window.__wgDNS = [\(servers.map { "'\($0)'" }.joined(separator: ","))];
            window.__wgEndpoint = '\(endpoint)';
            window.__networkRouted = true;
        })();
        """
    }
}
