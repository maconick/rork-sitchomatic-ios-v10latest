import Foundation
import Observation

nonisolated enum RotationInterval: String, CaseIterable, Codable, Sendable {
    case everyBatch = "Every Batch"
    case every1Min = "Every 1 Minute"
    case every3Min = "Every 3 Minutes"
    case every5Min = "Every 5 Minutes"
    case every7Min = "Every 7 Minutes"
    case every10Min = "Every 10 Minutes"
    case every15Min = "Every 15 Minutes"

    var seconds: TimeInterval? {
        switch self {
        case .everyBatch: nil
        case .every1Min: 60
        case .every3Min: 180
        case .every5Min: 300
        case .every7Min: 420
        case .every10Min: 600
        case .every15Min: 900
        }
    }

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .everyBatch: "arrow.triangle.2.circlepath"
        case .every1Min: "1.circle.fill"
        case .every3Min: "3.circle.fill"
        case .every5Min: "5.circle.fill"
        case .every7Min: "7.circle.fill"
        case .every10Min: "10.circle.fill"
        case .every15Min: "15.circle.fill"
        }
    }
}

nonisolated struct RotationLogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let fromLabel: String
    let toLabel: String
    let reason: String

    init(id: UUID = UUID(), timestamp: Date = Date(), fromLabel: String, toLabel: String, reason: String) {
        self.id = id
        self.timestamp = timestamp
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.reason = reason
    }
}

@Observable
@MainActor
class DeviceProxyService {
    static let shared = DeviceProxyService()

    private let proxyService = ProxyRotationService.shared
    private let localProxy = LocalProxyServer.shared
    private let vpnTunnel = VPNTunnelManager.shared
    private let healthMonitor = ProxyHealthMonitor.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let logger = DebugLogger.shared

    var wireProxyTunnelEnabled: Bool = false {
        didSet {
            persistSettings()
            if isEnabled {
                syncWireProxyTunnel()
            }
        }
    }

    var vpnTunnelEnabled: Bool = false {
        didSet {
            persistSettings()
            if isEnabled && vpnTunnelEnabled {
                activateVPNTunnel()
            } else if !vpnTunnelEnabled {
                deactivateVPNTunnel()
            }
        }
    }

    var localProxyEnabled: Bool = true {
        didSet {
            persistSettings()
            if isEnabled {
                if localProxyEnabled {
                    localProxy.start()
                } else {
                    localProxy.stop()
                }
                syncLocalProxyUpstream()
            }
        }
    }

    var isEnabled: Bool = false {
        didSet {
            persistSettings()
            if isEnabled {
                activateUnifiedMode()
            } else {
                deactivateUnifiedMode()
            }
        }
    }

    var rotationInterval: RotationInterval = .every5Min {
        didSet {
            persistSettings()
            restartRotationTimer()
        }
    }

    var rotateOnBatchStart: Bool = true {
        didSet { persistSettings() }
    }

    var rotateOnFingerprintDetection: Bool = true {
        didSet { persistSettings() }
    }

    var autoFailoverEnabled: Bool = true {
        didSet {
            persistSettings()
            healthMonitor.autoFailoverEnabled = autoFailoverEnabled
        }
    }

    var healthCheckInterval: TimeInterval = 30 {
        didSet {
            persistSettings()
            healthMonitor.checkIntervalSeconds = healthCheckInterval
        }
    }

    var maxFailuresBeforeRotation: Int = 3 {
        didSet {
            persistSettings()
            healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation
        }
    }

    var activeConfig: ActiveNetworkConfig?
    var activeEndpointLabel: String?
    var activeConnectionType: String = "None"
    var activeSince: Date?
    var isActive: Bool = false
    var isRotating: Bool = false
    var rotationLog: [RotationLogEntry] = []
    var nextRotationDate: Date?
    private(set) var failoverCount: Int = 0

    private var rotationTimer: Timer?
    private var wgIndex: Int = 0
    private var ovpnIndex: Int = 0
    private var socks5Index: Int = 0

    private let settingsKey = "device_proxy_settings_v2"

    init() {
        loadSettings()
        healthMonitor.autoFailoverEnabled = autoFailoverEnabled
        healthMonitor.checkIntervalSeconds = healthCheckInterval
        healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation
        if isEnabled {
            activateUnifiedMode()
        }
    }

    var secondsUntilRotation: Int? {
        guard let next = nextRotationDate else { return nil }
        let remaining = Int(next.timeIntervalSinceNow)
        return max(0, remaining)
    }

    var rotationCountdownLabel: String {
        guard let seconds = secondsUntilRotation else { return "--:--" }
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    func rotateNow(reason: String = "Manual") {
        performRotation(reason: reason)
    }

    func notifyBatchStart() {
        guard isEnabled, rotateOnBatchStart else { return }
        performRotation(reason: "Batch Start")
    }

    func notifyFingerprintDetected() {
        guard isEnabled, rotateOnFingerprintDetection else { return }
        performRotation(reason: "Fingerprint Detected")
    }

    private func activateUnifiedMode() {
        if localProxyEnabled {
            localProxy.start()
        }
        performRotation(reason: "Activated")
        restartRotationTimer()

        localProxy.startHealthMonitoring { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUpstreamFailover()
            }
        }

        logger.log("DeviceProxy: Unified IP mode ENABLED (localProxy: \(localProxyEnabled), vpnTunnel: \(vpnTunnelEnabled), autoFailover: \(autoFailoverEnabled))", category: .network, level: .info)
    }

    private func deactivateUnifiedMode() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        nextRotationDate = nil
        activeConfig = nil
        activeEndpointLabel = nil
        activeConnectionType = "None"
        activeSince = nil
        isActive = false
        localProxy.stop()
        wireProxyBridge.stop()
        deactivateVPNTunnel()
        logger.log("DeviceProxy: Unified IP mode DISABLED", category: .network, level: .info)
    }

    private func handleUpstreamFailover() {
        guard isEnabled, autoFailoverEnabled else { return }
        failoverCount += 1
        logger.log("DeviceProxy: FAILOVER triggered (count: \(failoverCount)) - upstream dead, rotating to next", category: .proxy, level: .error)
        performRotation(reason: "Failover (upstream dead)")
    }

    private func restartRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        nextRotationDate = nil

        guard isEnabled, let interval = rotationInterval.seconds else { return }

        nextRotationDate = Date().addingTimeInterval(interval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performRotation(reason: "Timer (\(self?.rotationInterval.label ?? ""))")
            }
        }
    }

    private func performRotation(reason: String) {
        isRotating = true
        let previousLabel = activeEndpointLabel ?? "None"

        let config = resolveNextConfig()
        activeConfig = config
        activeSince = Date()
        isActive = true

        switch config {
        case .wireGuardDNS(let wg):
            activeEndpointLabel = "WG: \(wg.fileName)"
            activeConnectionType = "WireGuard"
        case .openVPNProxy(let ovpn):
            activeEndpointLabel = "OVPN: \(ovpn.fileName)"
            activeConnectionType = "OpenVPN"
        case .socks5(let proxy):
            activeEndpointLabel = "SOCKS5: \(proxy.displayString)"
            activeConnectionType = "SOCKS5"
        case .direct:
            activeEndpointLabel = "Direct"
            activeConnectionType = "Direct"
        }

        let entry = RotationLogEntry(
            fromLabel: previousLabel,
            toLabel: activeEndpointLabel ?? "Unknown",
            reason: reason
        )
        rotationLog.insert(entry, at: 0)
        if rotationLog.count > 20 {
            rotationLog = Array(rotationLog.prefix(20))
        }

        if let interval = rotationInterval.seconds {
            nextRotationDate = Date().addingTimeInterval(interval)
        }

        syncLocalProxyUpstream()
        syncVPNTunnel()

        isRotating = false

        logger.log("DeviceProxy: rotated to \(activeEndpointLabel ?? "Unknown") (reason: \(reason))", category: .network, level: .info)
    }

    private func activateVPNTunnel() {
        guard vpnTunnel.isSupported else {
            logger.log("DeviceProxy: VPN tunnel not supported on this device", category: .vpn, level: .warning)
            return
        }
        Task {
            await vpnTunnel.loadExistingManager()
            syncVPNTunnel()
        }
    }

    private func deactivateVPNTunnel() {
        if vpnTunnel.isActive {
            vpnTunnel.disconnect(reason: "Unified mode deactivated")
        }
    }

    private func syncVPNTunnel() {
        guard vpnTunnelEnabled, isEnabled else { return }
        if case .wireGuardDNS(let wg) = activeConfig {
            Task {
                await vpnTunnel.reconnectWithConfig(wg)
            }
            logger.log("DeviceProxy: VPN tunnel connecting to WG \(wg.serverName)", category: .vpn, level: .info)
        }
    }

    var isVPNActive: Bool {
        vpnTunnelEnabled && vpnTunnel.isConnected
    }

    private func syncLocalProxyUpstream() {
        guard localProxyEnabled else {
            localProxy.updateUpstream(nil)
            return
        }
        switch activeConfig {
        case .socks5(let proxy):
            localProxy.enableWireProxyMode(false)
            localProxy.updateUpstream(proxy)
        case .wireGuardDNS(let wg):
            if wireProxyTunnelEnabled {
                syncWireProxyTunnel()
            } else {
                localProxy.enableWireProxyMode(false)
                localProxy.updateUpstream(nil)
            }
        default:
            localProxy.enableWireProxyMode(false)
            localProxy.updateUpstream(nil)
        }
    }

    private func syncWireProxyTunnel() {
        guard wireProxyTunnelEnabled, localProxyEnabled else {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            return
        }
        guard case .wireGuardDNS(let wg) = activeConfig else {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            return
        }

        if wireProxyBridge.isActive {
            wireProxyBridge.stop()
        }

        Task {
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: WireProxy tunnel active for \(wg.serverName)", category: .vpn, level: .success)
            } else {
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: WireProxy tunnel failed for \(wg.serverName)", category: .vpn, level: .error)
            }
        }
    }

    var isWireProxyActive: Bool {
        wireProxyTunnelEnabled && wireProxyBridge.isActive
    }

    var wireProxyStatus: WireProxyStatus {
        wireProxyBridge.status
    }

    var wireProxyStats: WireProxyStats {
        wireProxyBridge.stats
    }

    var effectiveProxyConfig: ProxyConfig? {
        guard isEnabled, isActive, localProxyEnabled, localProxy.isRunning else { return nil }
        switch activeConfig {
        case .socks5:
            return localProxy.localProxyConfig
        case .wireGuardDNS:
            if wireProxyTunnelEnabled && wireProxyBridge.isActive {
                return localProxy.localProxyConfig
            }
            if vpnTunnelEnabled && vpnTunnel.isConnected {
                return nil
            }
            return localProxy.localProxyConfig
        case .openVPNProxy:
            if vpnTunnelEnabled && vpnTunnel.isConnected {
                return nil
            }
            return localProxy.localProxyConfig
        case .direct, .none:
            return nil
        }
    }

    private func resolveNextConfig() -> ActiveNetworkConfig {
        let wgConfigs = proxyService.wgConfigs(for: .joe).filter { $0.isEnabled }
        if !wgConfigs.isEmpty {
            let config = wgConfigs[wgIndex % wgConfigs.count]
            wgIndex += 1
            return .wireGuardDNS(config)
        }

        let ovpnConfigs = proxyService.vpnConfigs(for: .joe).filter { $0.isEnabled }
        if !ovpnConfigs.isEmpty {
            let config = ovpnConfigs[ovpnIndex % ovpnConfigs.count]
            ovpnIndex += 1
            return .openVPNProxy(config)
        }

        let proxies = proxyService.proxies(for: .joe).filter { $0.isWorking || $0.lastTested == nil }
        if !proxies.isEmpty {
            let proxy = proxies[socks5Index % proxies.count]
            socks5Index += 1
            return .socks5(proxy)
        }

        let allProxies = proxyService.proxies(for: .joe)
        if !allProxies.isEmpty {
            let proxy = allProxies[socks5Index % allProxies.count]
            socks5Index += 1
            return .socks5(proxy)
        }

        return .direct
    }

    private func persistSettings() {
        let dict: [String: Any] = [
            "enabled": isEnabled,
            "interval": rotationInterval.rawValue,
            "rotateOnBatch": rotateOnBatchStart,
            "rotateOnFingerprint": rotateOnFingerprintDetection,
            "localProxy": localProxyEnabled,
            "vpnTunnel": vpnTunnelEnabled,
            "wireProxyTunnel": wireProxyTunnelEnabled,
            "autoFailover": autoFailoverEnabled,
            "healthCheckInterval": healthCheckInterval,
            "maxFailures": maxFailuresBeforeRotation,
        ]
        UserDefaults.standard.set(dict, forKey: settingsKey)
    }

    private func loadSettings() {
        let key = settingsKey
        let fallbackKey = "device_proxy_settings_v1"
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? UserDefaults.standard.dictionary(forKey: fallbackKey)
        guard let dict else { return }
        if let enabled = dict["enabled"] as? Bool { isEnabled = enabled }
        if let interval = dict["interval"] as? String,
           let parsed = RotationInterval(rawValue: interval) { rotationInterval = parsed }
        if let batch = dict["rotateOnBatch"] as? Bool { rotateOnBatchStart = batch }
        if let fp = dict["rotateOnFingerprint"] as? Bool { rotateOnFingerprintDetection = fp }
        if let lp = dict["localProxy"] as? Bool { localProxyEnabled = lp }
        if let vt = dict["vpnTunnel"] as? Bool { vpnTunnelEnabled = vt }
        if let wpt = dict["wireProxyTunnel"] as? Bool { wireProxyTunnelEnabled = wpt }
        if let af = dict["autoFailover"] as? Bool { autoFailoverEnabled = af }
        if let hci = dict["healthCheckInterval"] as? TimeInterval { healthCheckInterval = hci }
        if let mf = dict["maxFailures"] as? Int { maxFailuresBeforeRotation = mf }
    }
}
