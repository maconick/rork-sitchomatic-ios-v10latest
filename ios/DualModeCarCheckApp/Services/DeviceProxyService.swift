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

        logger.log("DeviceProxy: Unified IP mode ENABLED (localProxy: \(localProxyEnabled), autoFailover: \(autoFailoverEnabled))", category: .network, level: .info)
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

        if wireProxyBridge.isActive {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
        }

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

        isRotating = false

        logger.log("DeviceProxy: rotated to \(activeEndpointLabel ?? "Unknown") (reason: \(reason))", category: .network, level: .info)
    }

    var isVPNActive: Bool {
        false
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
        case .wireGuardDNS:
            syncWireProxyTunnel()
        default:
            localProxy.enableWireProxyMode(false)
            localProxy.updateUpstream(nil)
        }
    }

    private func syncWireProxyTunnel() {
        guard localProxyEnabled else {
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
        wireProxyBridge.isActive
    }

    var wireProxyStatus: WireProxyStatus {
        wireProxyBridge.status
    }

    var wireProxyStats: WireProxyStats {
        wireProxyBridge.stats
    }

    func reconnectWireProxy() {
        guard isEnabled, case .wireGuardDNS = activeConfig else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy reconnect requested", category: .vpn, level: .info)
        syncWireProxyTunnel()
    }

    func stopWireProxy() {
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy manually stopped", category: .vpn, level: .info)
    }

    func handleProfileSwitch() {
        if isEnabled {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            performRotation(reason: "Profile Switch")
        }
        logger.log("DeviceProxy: profile switched — configs reloaded, rotation triggered", category: .network, level: .info)
    }

    func rotateWireProxyConfig() {
        guard isEnabled else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        let config = resolveNextConfig()
        activeConfig = config
        activeSince = Date()

        switch config {
        case .wireGuardDNS(let wg):
            activeEndpointLabel = "WG: \(wg.fileName)"
            activeConnectionType = "WireGuard"
            Task {
                await wireProxyBridge.start(with: wg)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: WireProxy rotated to \(wg.serverName)", category: .vpn, level: .success)
                } else {
                    localProxy.enableWireProxyMode(false)
                    logger.log("DeviceProxy: WireProxy rotation failed for \(wg.serverName)", category: .vpn, level: .error)
                }
            }
        default:
            activeEndpointLabel = config.label
            activeConnectionType = "Direct"
            logger.log("DeviceProxy: WireProxy rotation landed on non-WG config, tunnel stopped", category: .vpn, level: .warning)
        }
    }

    var effectiveProxyConfig: ProxyConfig? {
        guard isEnabled, isActive, localProxyEnabled, localProxy.isRunning else { return nil }
        switch activeConfig {
        case .socks5:
            return localProxy.localProxyConfig
        case .wireGuardDNS:
            if wireProxyBridge.isActive {
                return localProxy.localProxyConfig
            }
            return nil
        case .openVPNProxy:
            return localProxy.localProxyConfig
        case .direct, .none:
            return nil
        }
    }

    private func resolveNextConfig() -> ActiveNetworkConfig {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let preferredMode = proxyService.unifiedConnectionMode

        let allWG = collectUniqueWG(targets: targets)
        let allOVPN = collectUniqueOVPN(targets: targets)
        let allProxies = collectUniqueProxies(targets: targets)

        switch preferredMode {
        case .wireguard:
            if let result = nextFromWG(allWG) { return result }
            if let result = nextFromOVPN(allOVPN) { return result }
            if let result = nextFromSOCKS5(allProxies) { return result }

        case .openvpn:
            if let result = nextFromOVPN(allOVPN) { return result }
            if let result = nextFromWG(allWG) { return result }
            if let result = nextFromSOCKS5(allProxies) { return result }

        case .proxy:
            if let result = nextFromSOCKS5(allProxies) { return result }
            if let result = nextFromWG(allWG) { return result }
            if let result = nextFromOVPN(allOVPN) { return result }

        case .dns:
            if let result = nextFromSOCKS5(allProxies) { return result }
            if let result = nextFromWG(allWG) { return result }
            if let result = nextFromOVPN(allOVPN) { return result }
        }

        return .direct
    }

    private func collectUniqueWG(targets: [ProxyRotationService.ProxyTarget]) -> [WireGuardConfig] {
        var all: [WireGuardConfig] = []
        for t in targets { all.append(contentsOf: proxyService.wgConfigs(for: t).filter { $0.isEnabled }) }
        return Array(Dictionary(grouping: all, by: \.uniqueKey).compactMapValues(\.first).values)
    }

    private func collectUniqueOVPN(targets: [ProxyRotationService.ProxyTarget]) -> [OpenVPNConfig] {
        var all: [OpenVPNConfig] = []
        for t in targets { all.append(contentsOf: proxyService.vpnConfigs(for: t).filter { $0.isEnabled }) }
        return Array(Dictionary(grouping: all, by: \.uniqueKey).compactMapValues(\.first).values)
    }

    private func collectUniqueProxies(targets: [ProxyRotationService.ProxyTarget]) -> [ProxyConfig] {
        var all: [ProxyConfig] = []
        for t in targets { all.append(contentsOf: proxyService.proxies(for: t)) }
        return Array(Dictionary(grouping: all, by: \.id).compactMapValues(\.first).values)
    }

    private func nextFromWG(_ configs: [WireGuardConfig]) -> ActiveNetworkConfig? {
        guard !configs.isEmpty else { return nil }
        let config = configs[wgIndex % configs.count]
        wgIndex += 1
        return .wireGuardDNS(config)
    }

    private func nextFromOVPN(_ configs: [OpenVPNConfig]) -> ActiveNetworkConfig? {
        guard !configs.isEmpty else { return nil }
        let config = configs[ovpnIndex % configs.count]
        ovpnIndex += 1
        return .openVPNProxy(config)
    }

    private func nextFromSOCKS5(_ proxies: [ProxyConfig]) -> ActiveNetworkConfig? {
        let working = proxies.filter { $0.isWorking || $0.lastTested == nil }
        if !working.isEmpty {
            let proxy = working[socks5Index % working.count]
            socks5Index += 1
            return .socks5(proxy)
        }
        guard !proxies.isEmpty else { return nil }
        let proxy = proxies[socks5Index % proxies.count]
        socks5Index += 1
        return .socks5(proxy)
    }

    private func persistSettings() {
        let dict: [String: Any] = [
            "enabled": isEnabled,
            "interval": rotationInterval.rawValue,
            "rotateOnBatch": rotateOnBatchStart,
            "rotateOnFingerprint": rotateOnFingerprintDetection,
            "localProxy": localProxyEnabled,
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
        if let af = dict["autoFailover"] as? Bool { autoFailoverEnabled = af }
        if let hci = dict["healthCheckInterval"] as? TimeInterval { healthCheckInterval = hci }
        if let mf = dict["maxFailures"] as? Int { maxFailuresBeforeRotation = mf }
    }
}
