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
    private let wireProxyBridge = WireProxyBridge.shared

    func nextConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        if vpnTunnel.isConnected {
            logger.log("NetworkFactory: device-wide VPN tunnel active — all traffic routed via VPN for \(target.rawValue)", category: .vpn, level: .debug)
            return .direct
        }

        if deviceProxy.isEnabled, let config = deviceProxy.activeConfig {
            if deviceProxy.isWireProxyActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: WireProxy tunnel active → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
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
            if vpnTunnel.isConnected {
                logger.log("NetworkFactory: VPN tunnel connected device-wide for WG mode \(target.rawValue)", category: .vpn, level: .debug)
                return .direct
            }
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                logger.log("NetworkFactory: WireProxy active → 127.0.0.1:\(localConfig.port) for \(target.rawValue)", category: .vpn, level: .debug)
                return .socks5(localConfig)
            }
            if let wg = nextWGConfig(for: target) {
                logger.log("NetworkFactory: assigned WG \(wg.displayString) for \(target.rawValue) — triggering VPN tunnel connect", category: .vpn, level: .debug)
                Task {
                    await vpnTunnel.configureAndConnect(with: wg)
                }
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
            if vpnTunnel.isConnected {
                logger.log("URLSession WG: device-wide VPN active via \(wg.displayString) — traffic routed through tunnel", category: .vpn, level: .info)
            } else if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                var proxyDict: [String: Any] = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": localConfig.host,
                    "SOCKSPort": localConfig.port,
                ]
                if let u = localConfig.username { proxyDict["SOCKSUser"] = u }
                if let p = localConfig.password { proxyDict["SOCKSPassword"] = p }
                sessionConfig.connectionProxyDictionary = proxyDict
                logger.log("URLSession WG: routed via WireProxy local proxy 127.0.0.1:\(localConfig.port)", category: .vpn, level: .info)
            } else {
                logger.log("URLSession WG: \(wg.displayString) — no active tunnel, triggering VPN connect and falling back to SOCKS5", category: .vpn, level: .warning)
                Task {
                    await vpnTunnel.configureAndConnect(with: wg)
                }
                if let fallbackProxy = proxyService.nextWorkingProxy(for: .joe) {
                    var proxyDict: [String: Any] = [
                        "SOCKSEnable": 1,
                        "SOCKSProxy": fallbackProxy.host,
                        "SOCKSPort": fallbackProxy.port,
                    ]
                    if let u = fallbackProxy.username { proxyDict["SOCKSUser"] = u }
                    if let p = fallbackProxy.password { proxyDict["SOCKSPassword"] = p }
                    sessionConfig.connectionProxyDictionary = proxyDict
                    logger.log("URLSession WG: SOCKS5 fallback \(fallbackProxy.displayString) while VPN connecting", category: .proxy, level: .info)
                } else {
                    logger.log("URLSession WG: no SOCKS5 fallback available — traffic will use real IP until VPN connects", category: .vpn, level: .error)
                }
            }

        case .openVPNProxy(let ovpn):
            if vpnTunnel.isConnected {
                logger.log("URLSession OVPN: device-wide VPN active — traffic routed through tunnel for \(ovpn.displayString)", category: .vpn, level: .info)
            } else {
                logger.log("URLSession OVPN: \(ovpn.remoteHost):\(ovpn.remotePort) (\(ovpn.proto)) — no active tunnel, falling back to SOCKS5", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: .joe) {
                    var proxyDict: [String: Any] = [
                        "SOCKSEnable": 1,
                        "SOCKSProxy": fallbackProxy.host,
                        "SOCKSPort": fallbackProxy.port,
                    ]
                    if let u = fallbackProxy.username { proxyDict["SOCKSUser"] = u }
                    if let p = fallbackProxy.password { proxyDict["SOCKSPassword"] = p }
                    sessionConfig.connectionProxyDictionary = proxyDict
                    logger.log("URLSession OVPN: SOCKS5 fallback \(fallbackProxy.displayString) while no VPN tunnel", category: .proxy, level: .info)
                } else {
                    logger.log("URLSession OVPN: no SOCKS5 fallback available — traffic will use real IP", category: .vpn, level: .error)
                }
            }
        }

        return sessionConfig
    }

    func configureWKWebView(config wkConfig: WKWebViewConfiguration, networkConfig: ActiveNetworkConfig) {
        let dataStore = wkConfig.websiteDataStore

        let resolvedConfig = resolveEffectiveConfig(networkConfig)

        switch resolvedConfig {
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
            logger.log("WKWebView SOCKS5 ProxyConfiguration applied: \(proxy.displayString) (original: \(networkConfig.label))", category: .proxy, level: .info)

        case .wireGuardDNS(let wg):
            if vpnTunnel.isConnected {
                logger.log("WKWebView WG: \(wg.displayString) — device-wide VPN tunnel active, all WebView traffic routed via tunnel", category: .vpn, level: .info)
            } else if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                let localConfig = localProxy.localProxyConfig
                let endpoint = NWEndpoint.hostPort(
                    host: NWEndpoint.Host(localConfig.host),
                    port: NWEndpoint.Port(integerLiteral: UInt16(localConfig.port))
                )
                let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
                dataStore.proxyConfigurations = [proxyConfig]
                wkConfig.websiteDataStore = dataStore
                logger.log("WKWebView WG: \(wg.displayString) — routed via WireProxy local proxy 127.0.0.1:\(localConfig.port)", category: .vpn, level: .info)
            } else {
                logger.log("WKWebView WG: \(wg.displayString) — no tunnel active, triggering device-wide VPN connect", category: .vpn, level: .warning)
                Task {
                    await vpnTunnel.configureAndConnect(with: wg)
                }
            }

        case .openVPNProxy(let ovpn):
            if vpnTunnel.isConnected {
                logger.log("WKWebView OVPN: \(ovpn.displayString) — device-wide VPN tunnel active, all WebView traffic routed via tunnel", category: .vpn, level: .info)
            } else {
                logger.log("WKWebView OVPN: \(ovpn.displayString) — no VPN tunnel, falling back to SOCKS5 for WebView", category: .vpn, level: .warning)
                if let fallbackProxy = proxyService.nextWorkingProxy(for: .joe) {
                    let endpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(fallbackProxy.host),
                        port: NWEndpoint.Port(integerLiteral: UInt16(fallbackProxy.port))
                    )
                    let proxyConfig = ProxyConfiguration(socksv5Proxy: endpoint)
                    if let u = fallbackProxy.username, let p = fallbackProxy.password {
                        proxyConfig.applyCredential(username: u, password: p)
                    }
                    dataStore.proxyConfigurations = [proxyConfig]
                    wkConfig.websiteDataStore = dataStore
                    logger.log("WKWebView OVPN: SOCKS5 fallback \(fallbackProxy.displayString)", category: .proxy, level: .info)
                }
            }

        case .direct:
            break
        }
    }

    private func resolveEffectiveConfig(_ config: ActiveNetworkConfig) -> ActiveNetworkConfig {
        if deviceProxy.isEnabled {
            if deviceProxy.isWireProxyActive, localProxy.isRunning, localProxy.wireProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            if deviceProxy.isVPNActive {
                return .direct
            }
            if let localConfig = deviceProxy.effectiveProxyConfig, localProxy.isRunning {
                return .socks5(localConfig)
            }
        }

        switch config {
        case .socks5:
            return config
        case .wireGuardDNS, .openVPNProxy:
            if localProxy.isRunning, localProxy.wireProxyMode, wireProxyBridge.isActive {
                return .socks5(localProxy.localProxyConfig)
            }
            if localProxy.isRunning, localProxy.upstreamProxy != nil {
                return .socks5(localProxy.localProxyConfig)
            }
            if vpnTunnel.isConnected {
                return .direct
            }
            return config
        case .direct:
            return config
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
