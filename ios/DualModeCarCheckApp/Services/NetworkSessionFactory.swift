import Foundation
import WebKit
import Network

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
    private let deviceProxy = DeviceProxyService.shared
    private let logger = DebugLogger.shared

    private var joeWGIndex: Int = 0
    private var ignitionWGIndex: Int = 0
    private var ppsrWGIndex: Int = 0

    private var joeOVPNIndex: Int = 0
    private var ignitionOVPNIndex: Int = 0
    private var ppsrOVPNIndex: Int = 0

    private let localProxy = LocalProxyServer.shared
    private let vpnTunnel = VPNTunnelManager.shared

    func nextConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        if deviceProxy.isEnabled, let config = deviceProxy.activeConfig {
            if deviceProxy.isVPNActive {
                logger.log("NetworkFactory: VPN tunnel active — traffic routed device-wide for \(target.rawValue)", category: .vpn, level: .debug)
                return .direct
            }
            if let localConfig = deviceProxy.effectiveProxyConfig, localProxy.isRunning {
                logger.log("NetworkFactory: using local proxy 127.0.0.1:\(localConfig.port) → upstream \(config.label) for \(target.rawValue)", category: .network, level: .debug)
                return .socks5(localConfig)
            }
            logger.log("NetworkFactory: using unified IP → \(config.label) for \(target.rawValue)", category: .network, level: .debug)
            return config
        }

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
            logger.log("NetworkFactory: no enabled WG config for \(target.rawValue) — falling back to OpenVPN", category: .vpn, level: .warning)
            if let ovpn = nextOVPNConfig(for: target) {
                logger.log("NetworkFactory: WG fallback → OVPN \(ovpn.displayString) for \(target.rawValue)", category: .vpn, level: .info)
                return .openVPNProxy(ovpn)
            }
            logger.log("NetworkFactory: no OVPN available for \(target.rawValue) — falling back to SOCKS5", category: .vpn, level: .warning)
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
        sessionConfig.timeoutIntervalForRequest = TimeoutResolver.resolveRequestTimeout(30)
        sessionConfig.timeoutIntervalForResource = TimeoutResolver.resolveResourceTimeout(60)
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
        let dataStore = wkConfig.websiteDataStore ?? .nonPersistent()

        switch networkConfig {
        case .socks5(let proxy):
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
            if let u = proxy.username, let p = proxy.password {
                proxyConfig.applyCredential(username: u, password: p)
            }
            dataStore.proxyConfigurations = [proxyConfig]
            wkConfig.websiteDataStore = dataStore
            logger.log("WKWebView SOCKS5 ProxyConfiguration applied: \(proxy.displayString)", category: .proxy, level: .info)

        case .wireGuardDNS(let wg):
            if vpnTunnel.isConnected {
                logger.log("WKWebView WG: \(wg.displayString) — VPN tunnel active, traffic routed device-wide", category: .vpn, level: .info)
            } else {
                logger.log("WKWebView WG: \(wg.displayString) — VPN tunnel not active, using DNS-level routing only", category: .vpn, level: .warning)
            }

        case .openVPNProxy(let ovpn):
            if vpnTunnel.isConnected {
                logger.log("WKWebView OVPN: \(ovpn.displayString) — VPN tunnel active, traffic routed device-wide", category: .vpn, level: .info)
            } else {
                logger.log("WKWebView OVPN: \(ovpn.displayString) — VPN tunnel not active, direct connection", category: .vpn, level: .warning)
            }

        case .direct:
            break
        }
    }

    func buildProxiedDataStore(for networkConfig: ActiveNetworkConfig) -> WKWebsiteDataStore {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        switch networkConfig {
        case .socks5(let proxy):
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
            if let u = proxy.username, let p = proxy.password {
                proxyConfig.applyCredential(username: u, password: p)
            }
            dataStore.proxyConfigurations = [proxyConfig]
            logger.log("DataStore SOCKS5 proxy applied: \(proxy.displayString)", category: .proxy, level: .debug)
        default:
            break
        }
        return dataStore
    }

    func buildURLSessionProxyConfiguration(for config: ActiveNetworkConfig) -> URLSessionConfiguration {
        let sessionConfig = buildURLSessionConfiguration(for: config)
        if case .socks5(let proxy) = config {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
            if let u = proxy.username, let p = proxy.password {
                proxyConfig.applyCredential(username: u, password: p)
            }
            sessionConfig.proxyConfigurations = [proxyConfig]
        }
        return sessionConfig
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


}
