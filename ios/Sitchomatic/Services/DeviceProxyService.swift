import Foundation
import Observation

@Observable
@MainActor
class DeviceProxyService {
    static let shared = DeviceProxyService()

    private let proxyService = ProxyRotationService.shared
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let resilience = NetworkResilienceService.shared
    private let intel = NordServerIntelligence.shared
    private let connectionPool = ProxyConnectionPool.shared
    private let healthMonitor = ProxyHealthMonitor.shared
    private let logger = DebugLogger.shared

    let configResolver = ProxyConfigResolver()
    private(set) var perSessionManager: PerSessionTunnelManager!

    var localProxyEnabled: Bool = true {
        didSet {
            persistSettings()
            if isEnabled {
                localProxyEnabled ? localProxy.start() : localProxy.stop()
                syncLocalProxyUpstream()
            }
        }
    }

    var ipRoutingMode: IPRoutingMode = .appWideUnited {
        didSet {
            persistSettings()
            if ipRoutingMode == .appWideUnited {
                perSessionManager.stopWireProxy()
                perSessionManager.stopOpenVPN()
                activateUnifiedMode()
            } else {
                deactivateUnifiedMode()
                activatePerSessionMode()
            }
        }
    }

    var rotationInterval: RotationInterval = .everyBatch {
        didSet { persistSettings(); restartRotationTimer() }
    }

    var rotateOnBatchStart: Bool = false {
        didSet { persistSettings() }
    }

    var rotateOnFingerprintDetection: Bool = true {
        didSet { persistSettings() }
    }

    var autoFailoverEnabled: Bool = true {
        didSet { persistSettings(); healthMonitor.autoFailoverEnabled = autoFailoverEnabled }
    }

    var healthCheckInterval: TimeInterval = 30 {
        didSet { persistSettings(); healthMonitor.checkIntervalSeconds = healthCheckInterval }
    }

    var maxFailuresBeforeRotation: Int = 3 {
        didSet { persistSettings(); healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation }
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
    private let settingsKey = "device_proxy_settings_v2"

    init() {
        perSessionManager = PerSessionTunnelManager(configResolver: configResolver)
        loadSettings()
        healthMonitor.autoFailoverEnabled = autoFailoverEnabled
        healthMonitor.checkIntervalSeconds = healthCheckInterval
        healthMonitor.maxConsecutiveFailures = maxFailuresBeforeRotation
        if ipRoutingMode == .appWideUnited {
            activateUnifiedMode()
        } else {
            activatePerSessionMode()
        }
    }

    // MARK: - Computed Properties

    var isEnabled: Bool { ipRoutingMode == .appWideUnited }
    var isVPNActive: Bool { false }

    var isWireProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .wireguard }
    var isOpenVPNProxyCompatibleMode: Bool { proxyService.unifiedConnectionMode == .openvpn }
    var isOpenVPNBridgeActive: Bool { ovpnBridge.isActive }
    var openVPNBridgeStatus: OpenVPNBridgeStatus { ovpnBridge.status }
    var openVPNBridgeStats: OpenVPNBridgeStats { ovpnBridge.stats }
    var isWireProxyActive: Bool { wireProxyBridge.isActive }
    var wireProxyStatus: WireProxyStatus { wireProxyBridge.status }
    var wireProxyStats: WireProxyStats { wireProxyBridge.stats }

    var shouldShowWireProxySection: Bool {
        isWireProxyCompatibleMode || perSessionManager.wireProxyActive || wireProxyBridge.isActive
    }
    var shouldShowOpenVPNSection: Bool {
        isOpenVPNProxyCompatibleMode || perSessionManager.openVPNActive || ovpnBridge.isActive
    }
    var shouldShowWireProxyDashboard: Bool { shouldShowWireProxySection && wireProxyBridge.isActive }
    var shouldShowOpenVPNDashboard: Bool { shouldShowOpenVPNSection && ovpnBridge.isActive }

    var canManageWireProxyTunnel: Bool {
        guard shouldShowWireProxySection else { return false }
        if isEnabled { guard case .wireGuardDNS = activeConfig else { return false }; return true }
        return perSessionManager.wireProxyActive
    }

    var canManageOpenVPNBridge: Bool {
        guard shouldShowOpenVPNSection else { return false }
        if isEnabled { guard case .openVPNProxy = activeConfig else { return false }; return true }
        return perSessionManager.openVPNActive
    }

    var perSessionWireProxyActive: Bool { perSessionManager.wireProxyActive }
    var perSessionWireProxyStarting: Bool { perSessionManager.wireProxyStarting }
    var perSessionOpenVPNActive: Bool { perSessionManager.openVPNActive }
    var perSessionOpenVPNStarting: Bool { perSessionManager.openVPNStarting }
    var perSessionTunnelCount: Int { perSessionManager.tunnelCount }
    var isMultiTunnelActive: Bool { perSessionManager.isMultiTunnelActive }

    var wireProxyActiveConfigLabel: String? {
        if isEnabled, case .wireGuardDNS(let wg) = activeConfig { return wg.serverName }
        return perSessionManager.wireProxyConfigLabel
    }

    var openVPNActiveConfigLabel: String? {
        if isEnabled, case .openVPNProxy(let ovpn) = activeConfig { return ovpn.serverName }
        return perSessionManager.openVPNConfigLabel
    }

    var secondsUntilRotation: Int? {
        guard let next = nextRotationDate else { return nil }
        return max(0, Int(next.timeIntervalSinceNow))
    }

    var rotationCountdownLabel: String {
        guard let seconds = secondsUntilRotation else { return "--:--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var effectiveProxyConfig: ProxyConfig? {
        if ipRoutingMode == .appWideUnited, isActive, localProxyEnabled, localProxy.isRunning {
            switch activeConfig {
            case .socks5: return localProxy.localProxyConfig
            case .wireGuardDNS:
                return (isWireProxyCompatibleMode && wireProxyBridge.isActive) ? localProxy.localProxyConfig : nil
            case .openVPNProxy:
                return (ovpnBridge.isActive && localProxy.openVPNProxyMode) ? localProxy.localProxyConfig : nil
            case .direct, .none: return nil
            }
        }
        if ipRoutingMode == .separatePerSession, localProxyEnabled, localProxy.isRunning {
            if perSessionManager.wireProxyActive, wireProxyBridge.isActive, localProxy.wireProxyMode {
                return localProxy.localProxyConfig
            }
            if perSessionManager.openVPNActive, ovpnBridge.isActive, localProxy.openVPNProxyMode {
                return localProxy.localProxyConfig
            }
        }
        return nil
    }

    // MARK: - Public Actions

    func cancel() {}

    func rotateNow(reason: String = "Manual") {
        performRotation(reason: reason)
    }

    func notifyBatchStart() {
        if isEnabled {
            if rotateOnBatchStart || rotationInterval == .everyBatch {
                performRotation(reason: "Batch Start")
            }
            return
        }
        guard rotateOnBatchStart else { return }
        if perSessionManager.wireProxyActive {
            perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
            logger.log("DeviceProxy: per-session WireGuard rotated on batch start", category: .vpn, level: .info)
        }
        if perSessionManager.openVPNActive {
            perSessionManager.rotateOpenVPN(localProxyEnabled: localProxyEnabled)
            logger.log("DeviceProxy: per-session OpenVPN rotated on batch start", category: .vpn, level: .info)
        }
        if proxyService.unifiedConnectionMode == .hybrid {
            HybridNetworkingService.shared.resetBatch()
            logger.log("DeviceProxy: hybrid mode reset for new batch", category: .network, level: .info)
        }
        NetworkSessionFactory.shared.resetRotationIndexes()
        logger.log("DeviceProxy: per-session rotation indexes reset on batch start (mode: \(proxyService.unifiedConnectionMode.label))", category: .network, level: .info)
    }

    func notifyFingerprintDetected() {
        guard isEnabled, rotateOnFingerprintDetection else { return }
        performRotation(reason: "Fingerprint Detected")
    }

    func handleUnifiedConnectionModeChange() {
        if !isWireProxyCompatibleMode {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            perSessionManager.stopWireProxy()
        }
        if !isOpenVPNProxyCompatibleMode {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            perSessionManager.stopOpenVPN()
        }
        isEnabled ? performRotation(reason: "Connection Mode Changed") : activatePerSessionMode()
    }

    func reconnectWireProxy() {
        if !isEnabled && perSessionManager.wireProxyActive {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            logger.log("DeviceProxy: WireProxy reconnect requested (per-session)", category: .vpn, level: .info)
            perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageWireProxyTunnel else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy reconnect requested", category: .vpn, level: .info)
        syncWireProxyTunnel()
    }

    func stopWireProxy() {
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        if !isEnabled { perSessionManager.stopWireProxy() }
        logger.log("DeviceProxy: WireProxy manually stopped", category: .vpn, level: .info)
    }

    func reconnectOpenVPN() {
        if !isEnabled && perSessionManager.openVPNActive {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            logger.log("DeviceProxy: OpenVPN reconnect requested (per-session)", category: .vpn, level: .info)
            perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageOpenVPNBridge else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        logger.log("DeviceProxy: OpenVPN reconnect requested", category: .vpn, level: .info)
        if case .openVPNProxy(let ovpn) = activeConfig {
            syncOpenVPNProxyBridge(ovpn)
        }
    }

    func stopOpenVPN() {
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        if !isEnabled { perSessionManager.stopOpenVPN() }
        logger.log("DeviceProxy: OpenVPN manually stopped", category: .vpn, level: .info)
    }

    func activatePerSessionWireProxy() {
        guard !isEnabled else { return }
        perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func activatePerSessionOpenVPN() {
        guard !isEnabled else { return }
        perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func rotatePerSessionWireProxy() {
        guard !isEnabled else { return }
        perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func rotatePerSessionOpenVPN() {
        guard !isEnabled else { return }
        perSessionManager.rotateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func rotateWireProxyConfig() {
        if !isEnabled && perSessionManager.wireProxyActive {
            perSessionManager.rotateWireProxy(localProxyEnabled: localProxyEnabled)
            return
        }
        guard canManageWireProxyTunnel else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        let config = configResolver.resolveNextConfig()
        activeConfig = config
        activeSince = Date()
        if case .wireGuardDNS(let wg) = config {
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
        } else {
            activeEndpointLabel = config.label
            activeConnectionType = "Direct"
            logger.log("DeviceProxy: WireProxy rotation landed on non-WG config, tunnel stopped", category: .vpn, level: .warning)
        }
    }

    func handleProfileSwitch() {
        perSessionManager.resetAll()
        localProxy.updateUpstream(nil)
        intel.clearAll()
        activeConfig = nil
        activeEndpointLabel = nil
        activeConnectionType = "None"
        activeSince = nil
        isActive = false
        configResolver.resetIndexes()
        rotationLog.removeAll()

        if ipRoutingMode == .appWideUnited {
            performRotation(reason: "Profile Switch")
        } else {
            activatePerSessionMode()
        }
        let profile = NordVPNService.shared.activeKeyProfile
        logger.log("DeviceProxy: profile switched to \(profile.rawValue) — tunnel stopped, state reset, configs reloaded", category: .network, level: .success)
    }

    // MARK: - Unified Mode

    private func activateUnifiedMode() {
        if localProxyEnabled { localProxy.start() }
        resilience.resetBackoff()
        intel.startMonitoring()
        performRotation(reason: "Activated")
        restartRotationTimer()

        localProxy.startHealthMonitoring { [weak self] in
            Task { @MainActor [weak self] in self?.handleUpstreamFailover() }
        }

        if case .socks5(let proxy) = activeConfig {
            resilience.startVerificationLoop(expectedProxy: proxy)
        }
        connectionPool.prewarmConnections(count: 3, upstream: localProxy.upstreamProxy)
        logger.log("DeviceProxy: App-Wide United IP ENABLED (localProxy: \(localProxyEnabled), autoFailover: \(autoFailoverEnabled))", category: .network, level: .info)
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
        wireProxyBridge.stop()
        ovpnBridge.stop()
        localProxy.enableWireProxyMode(false)
        localProxy.enableOpenVPNProxyMode(false)
        localProxy.stop()
        intel.stopMonitoring()
        resilience.stopVerificationLoop()
        resilience.resetBackoff()
        resilience.resetThrottling()
        logger.log("DeviceProxy: App-Wide United IP DISABLED", category: .network, level: .info)
    }

    private func activatePerSessionMode() {
        let mode = proxyService.unifiedConnectionMode
        if mode == .direct {
            perSessionManager.stopWireProxy()
            perSessionManager.stopOpenVPN()
            logger.log("DeviceProxy: DIRECT mode — no proxy/tunnel, bypassing all network layers", category: .network, level: .info)
        } else if mode == .wireguard && !perSessionManager.wireProxyActive {
            perSessionManager.activateWireProxy(localProxyEnabled: localProxyEnabled)
        } else if mode == .openvpn && !perSessionManager.openVPNActive {
            perSessionManager.activateOpenVPN(localProxyEnabled: localProxyEnabled)
        } else {
            NetworkSessionFactory.shared.resetRotationIndexes()
            logger.log("DeviceProxy: per-session mode active for \(mode.label) — each session gets its own IP from the pool", category: .network, level: .info)
        }
    }

    // MARK: - Rotation

    private func performRotation(reason: String) {
        isRotating = true
        let previousLabel = activeEndpointLabel ?? "None"

        if wireProxyBridge.isActive {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
        }
        if ovpnBridge.isActive {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
        }

        let config = configResolver.resolveNextConfig()
        activeConfig = config
        activeSince = Date()
        isActive = true

        switch config {
        case .wireGuardDNS(let wg):
            activeEndpointLabel = "WG: \(wg.fileName)"; activeConnectionType = "WireGuard"
        case .openVPNProxy(let ovpn):
            activeEndpointLabel = "OVPN: \(ovpn.fileName)"; activeConnectionType = "OpenVPN"
        case .socks5(let proxy):
            activeEndpointLabel = "SOCKS5: \(proxy.displayString)"; activeConnectionType = "SOCKS5"
        case .direct:
            activeEndpointLabel = "Direct"; activeConnectionType = "Direct"
        }

        rotationLog.insert(RotationLogEntry(fromLabel: previousLabel, toLabel: activeEndpointLabel ?? "Unknown", reason: reason), at: 0)
        if rotationLog.count > 20 { rotationLog = Array(rotationLog.prefix(20)) }
        if let interval = rotationInterval.seconds { nextRotationDate = Date().addingTimeInterval(interval) }

        syncLocalProxyUpstream()
        resilience.resetBackoff()

        if case .socks5(let proxy) = config {
            resilience.startVerificationLoop(expectedProxy: proxy)
            connectionPool.prewarmConnections(count: 2, upstream: proxy)
        } else {
            resilience.stopVerificationLoop()
        }

        isRotating = false
        logger.log("DeviceProxy: rotated to \(activeEndpointLabel ?? "Unknown") (reason: \(reason))", category: .network, level: .info)
    }

    private func handleUpstreamFailover() {
        guard isEnabled, autoFailoverEnabled else { return }
        if resilience.shouldThrottleFailover() {
            logger.log("DeviceProxy: FAILOVER throttled — backoff \(String(format: "%.1f", resilience.failoverBackoffSeconds))s remaining", category: .proxy, level: .warning)
            return
        }
        let backoffDelay = resilience.calculateBackoffDelay()
        failoverCount += 1
        logger.log("DeviceProxy: FAILOVER triggered (count: \(failoverCount), backoff: \(String(format: "%.1f", backoffDelay))s) - upstream dead, rotating to next", category: .proxy, level: .error)
        Task {
            try? await Task.sleep(for: .seconds(backoffDelay))
            self.performRotation(reason: "Failover (upstream dead, attempt \(self.failoverCount))")
        }
    }

    private func restartRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        nextRotationDate = nil
        guard ipRoutingMode == .appWideUnited, let interval = rotationInterval.seconds else { return }
        nextRotationDate = Date().addingTimeInterval(interval)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performRotation(reason: "Timer (\(self?.rotationInterval.label ?? ""))")
            }
        }
    }

    // MARK: - Upstream Sync

    private func syncLocalProxyUpstream() {
        guard localProxyEnabled else { localProxy.updateUpstream(nil); return }
        switch activeConfig {
        case .socks5(let proxy):
            localProxy.enableWireProxyMode(false)
            localProxy.enableOpenVPNProxyMode(false)
            localProxy.updateUpstream(proxy)
        case .wireGuardDNS:
            localProxy.enableOpenVPNProxyMode(false)
            guard isWireProxyCompatibleMode else {
                wireProxyBridge.stop()
                localProxy.enableWireProxyMode(false)
                localProxy.updateUpstream(nil)
                return
            }
            syncWireProxyTunnel()
        case .openVPNProxy(let ovpn):
            localProxy.enableWireProxyMode(false)
            syncOpenVPNProxyBridge(ovpn)
        default:
            localProxy.enableWireProxyMode(false)
            localProxy.enableOpenVPNProxyMode(false)
            localProxy.updateUpstream(nil)
        }
    }

    private func syncWireProxyTunnel() {
        guard isWireProxyCompatibleMode, localProxyEnabled,
              case .wireGuardDNS(let wg) = activeConfig else {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            return
        }
        if wireProxyBridge.isActive { wireProxyBridge.stop() }
        Task {
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: WireProxy tunnel active for \(wg.serverName)", category: .vpn, level: .success)
            } else {
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: WireProxy tunnel failed for \(wg.serverName) — retrying with next config", category: .vpn, level: .error)
                await retryWireProxyWithNextConfig(failedServer: wg.serverName)
            }
        }
    }

    private func retryWireProxyWithNextConfig(failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let candidates = configResolver.collectUniqueWG(targets: targets).filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative WG configs for retry", category: .vpn, level: .error)
            return
        }
        let maxRetries = min(candidates.count, 4)
        for attempt in 0..<maxRetries {
            let nextWG = candidates[attempt % candidates.count]
            activeConfig = .wireGuardDNS(nextWG)
            activeEndpointLabel = "WG: \(nextWG.fileName)"
            activeConnectionType = "WireGuard"
            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))
            await wireProxyBridge.start(with: nextWG)
            if wireProxyBridge.isActive {
                configResolver.advanceWGIndex(by: attempt + 1)
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: WireProxy retry succeeded with \(nextWG.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: WireProxy retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextWG.serverName)", category: .vpn, level: .warning)
        }
        configResolver.advanceWGIndex(by: maxRetries)
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy all \(maxRetries) retry attempts exhausted", category: .vpn, level: .error)
    }

    private func syncOpenVPNProxyBridge(_ config: OpenVPNConfig) {
        guard localProxyEnabled else {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            return
        }
        if ovpnBridge.isActive { ovpnBridge.stop() }
        Task {
            await ovpnBridge.start(with: config)
            if ovpnBridge.isActive {
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: OpenVPN bridge active → \(ovpnBridge.activeProxyLabel ?? "unknown") for \(config.serverName), handler mode enabled", category: .vpn, level: .success)
            } else {
                localProxy.enableOpenVPNProxyMode(false)
                logger.log("DeviceProxy: OpenVPN bridge failed for \(config.serverName) — retrying with next config", category: .vpn, level: .error)
                await retryOpenVPNBridgeWithNextConfig(failedServer: config.serverName)
            }
        }
    }

    private func retryOpenVPNBridgeWithNextConfig(failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let candidates = configResolver.collectUniqueOVPN(targets: targets).filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative OVPN configs for retry", category: .vpn, level: .error)
            return
        }
        let maxRetries = min(candidates.count, 4)
        for attempt in 0..<maxRetries {
            let nextOVPN = candidates[attempt % candidates.count]
            activeConfig = .openVPNProxy(nextOVPN)
            activeEndpointLabel = "OVPN: \(nextOVPN.fileName)"
            activeConnectionType = "OpenVPN"
            ovpnBridge.stop()
            try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))
            await ovpnBridge.start(with: nextOVPN)
            if ovpnBridge.isActive {
                configResolver.advanceOVPNIndex(by: attempt + 1)
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: OpenVPN bridge retry succeeded with \(nextOVPN.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: OpenVPN bridge retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextOVPN.serverName)", category: .vpn, level: .warning)
        }
        configResolver.advanceOVPNIndex(by: maxRetries)
        localProxy.enableOpenVPNProxyMode(false)
        logger.log("DeviceProxy: OpenVPN bridge all \(maxRetries) retry attempts exhausted", category: .vpn, level: .error)
    }

    // MARK: - Persistence

    private func persistSettings() {
        let dict: [String: Any] = [
            "ipRoutingMode": ipRoutingMode.rawValue,
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
        let dict = UserDefaults.standard.dictionary(forKey: settingsKey) ?? UserDefaults.standard.dictionary(forKey: "device_proxy_settings_v1")
        guard let dict else { return }
        if let modeRaw = dict["ipRoutingMode"] as? String, let mode = IPRoutingMode(rawValue: modeRaw) {
            ipRoutingMode = mode
        } else if let enabled = dict["enabled"] as? Bool {
            ipRoutingMode = enabled ? .appWideUnited : .separatePerSession
        }
        if let interval = dict["interval"] as? String, let parsed = RotationInterval(rawValue: interval) { rotationInterval = parsed }
        if let batch = dict["rotateOnBatch"] as? Bool { rotateOnBatchStart = batch }
        if let fp = dict["rotateOnFingerprint"] as? Bool { rotateOnFingerprintDetection = fp }
        if let lp = dict["localProxy"] as? Bool { localProxyEnabled = lp }
        if let af = dict["autoFailover"] as? Bool { autoFailoverEnabled = af }
        if let hci = dict["healthCheckInterval"] as? TimeInterval { healthCheckInterval = hci }
        if let mf = dict["maxFailures"] as? Int { maxFailuresBeforeRotation = mf }
    }
}
