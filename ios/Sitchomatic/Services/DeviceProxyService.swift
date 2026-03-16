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

nonisolated enum IPRoutingMode: String, CaseIterable, Codable, Sendable {
    case separatePerSession = "Separate IP per Session"
    case appWideUnited = "App-Wide United IP"

    var label: String { rawValue }

    var icon: String {
        switch self {
        case .separatePerSession: "arrow.triangle.branch"
        case .appWideUnited: "shield.checkered"
        }
    }

    var shortLabel: String {
        switch self {
        case .separatePerSession: "Per-Session"
        case .appWideUnited: "United IP"
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
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let resilience = NetworkResilienceService.shared
    private let scoring = ProxyScoringService.shared
    private let connectionPool = ProxyConnectionPool.shared
    private let aiProxyStrategy = AIProxyStrategyService.shared
    private let intel = NordServerIntelligence.shared
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

    var ipRoutingMode: IPRoutingMode = .appWideUnited {
        didSet {
            persistSettings()
            if ipRoutingMode == .appWideUnited {
                stopPerSessionWireProxy()
                stopPerSessionOpenVPN()
                activateUnifiedMode()
            } else {
                deactivateUnifiedMode()
                if isWireProxyCompatibleMode {
                    activatePerSessionWireProxy()
                } else if isOpenVPNProxyCompatibleMode {
                    activatePerSessionOpenVPN()
                }
            }
        }
    }

    var isEnabled: Bool {
        ipRoutingMode == .appWideUnited
    }

    var isWireProxyCompatibleMode: Bool {
        proxyService.unifiedConnectionMode == .wireguard
    }

    var isOpenVPNProxyCompatibleMode: Bool {
        proxyService.unifiedConnectionMode == .openvpn
    }

    var isOpenVPNBridgeActive: Bool {
        ovpnBridge.isActive
    }

    var openVPNBridgeStatus: OpenVPNBridgeStatus {
        ovpnBridge.status
    }

    var openVPNBridgeStats: OpenVPNBridgeStats {
        ovpnBridge.stats
    }

    var shouldShowWireProxySection: Bool {
        isWireProxyCompatibleMode
    }

    var shouldShowOpenVPNSection: Bool {
        isOpenVPNProxyCompatibleMode
    }

    var shouldShowWireProxyDashboard: Bool {
        shouldShowWireProxySection && wireProxyBridge.isActive
    }

    var shouldShowOpenVPNDashboard: Bool {
        shouldShowOpenVPNSection && ovpnBridge.isActive
    }

    var canManageWireProxyTunnel: Bool {
        guard shouldShowWireProxySection else { return false }
        if isEnabled {
            guard case .wireGuardDNS = activeConfig else { return false }
            return true
        }
        return perSessionWireProxyActive
    }

    var canManageOpenVPNBridge: Bool {
        guard shouldShowOpenVPNSection else { return false }
        if isEnabled {
            guard case .openVPNProxy = activeConfig else { return false }
            return true
        }
        return perSessionOpenVPNActive
    }

    private(set) var perSessionWireProxyActive: Bool = false
    private var perSessionWGConfig: WireGuardConfig?
    private(set) var perSessionOpenVPNActive: Bool = false
    private(set) var perSessionOpenVPNStarting: Bool = false
    private var perSessionOVPNConfig: OpenVPNConfig?

    var rotationInterval: RotationInterval = .everyBatch {
        didSet {
            persistSettings()
            restartRotationTimer()
        }
    }

    var rotateOnBatchStart: Bool = false {
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
        if ipRoutingMode == .appWideUnited {
            activateUnifiedMode()
        } else if isWireProxyCompatibleMode {
            activatePerSessionWireProxy()
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
        if isEnabled {
            if rotateOnBatchStart || rotationInterval == .everyBatch {
                performRotation(reason: "Batch Start")
            }
            return
        }

        if rotateOnBatchStart && isWireProxyCompatibleMode && perSessionWireProxyActive {
            rotatePerSessionWireProxy()
            logger.log("DeviceProxy: per-session WireGuard rotated on batch start", category: .vpn, level: .info)
        }

        if rotateOnBatchStart && isOpenVPNProxyCompatibleMode && perSessionOpenVPNActive {
            rotatePerSessionOpenVPN()
            logger.log("DeviceProxy: per-session OpenVPN rotated on batch start", category: .vpn, level: .info)
        }

        if proxyService.unifiedConnectionMode == .hybrid {
            HybridNetworkingService.shared.resetBatch()
            logger.log("DeviceProxy: hybrid mode reset for new batch", category: .network, level: .info)
        }
    }

    func notifyFingerprintDetected() {
        guard isEnabled, rotateOnFingerprintDetection else { return }
        performRotation(reason: "Fingerprint Detected")
    }

    private func activateUnifiedMode() {
        if localProxyEnabled {
            localProxy.start()
        }
        resilience.resetBackoff()
        intel.startMonitoring()
        performRotation(reason: "Activated")
        restartRotationTimer()

        localProxy.startHealthMonitoring { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUpstreamFailover()
            }
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

    private func syncOpenVPNProxyBridge(_ config: OpenVPNConfig) {
        guard localProxyEnabled else {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            return
        }

        if ovpnBridge.isActive {
            ovpnBridge.stop()
        }

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
        let allOVPN = collectUniqueOVPN(targets: targets)
        let candidates = allOVPN.filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative OVPN configs for retry", category: .vpn, level: .error)
            return
        }

        let maxRetries = min(candidates.count, 4)
        for attempt in 0..<maxRetries {
            let nextOVPN = candidates[(ovpnIndex + attempt) % candidates.count]
            activeConfig = .openVPNProxy(nextOVPN)
            activeEndpointLabel = "OVPN: \(nextOVPN.fileName)"
            activeConnectionType = "OpenVPN"

            ovpnBridge.stop()
            try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))

            await ovpnBridge.start(with: nextOVPN)
            if ovpnBridge.isActive {
                ovpnIndex += attempt + 1
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: OpenVPN bridge retry succeeded with \(nextOVPN.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: OpenVPN bridge retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextOVPN.serverName)", category: .vpn, level: .warning)
        }

        ovpnIndex += maxRetries
        localProxy.enableOpenVPNProxyMode(false)
        logger.log("DeviceProxy: OpenVPN bridge all \(maxRetries) retry attempts exhausted", category: .vpn, level: .error)
    }

    private func syncWireProxyTunnel() {
        guard isWireProxyCompatibleMode else {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            return
        }
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
                logger.log("DeviceProxy: WireProxy tunnel failed for \(wg.serverName) — retrying with next config", category: .vpn, level: .error)
                await retryWireProxyWithNextConfig(failedServer: wg.serverName)
            }
        }
    }

    private func retryWireProxyWithNextConfig(failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        var allWG: [WireGuardConfig] = []
        for t in targets { allWG.append(contentsOf: proxyService.wgConfigs(for: t).filter { $0.isEnabled }) }
        let unique = Array(Dictionary(grouping: allWG, by: \.uniqueKey).compactMapValues(\.first).values)
        let candidates = unique.filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative WG configs for retry", category: .vpn, level: .error)
            return
        }

        let maxRetries = min(candidates.count, 4)
        for attempt in 0..<maxRetries {
            let nextWG = candidates[(wgIndex + attempt) % candidates.count]
            activeConfig = .wireGuardDNS(nextWG)
            activeEndpointLabel = "WG: \(nextWG.fileName)"
            activeConnectionType = "WireGuard"

            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(Double(attempt) * 0.5 + 0.5))

            await wireProxyBridge.start(with: nextWG)
            if wireProxyBridge.isActive {
                wgIndex += attempt + 1
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: WireProxy retry succeeded with \(nextWG.serverName) on attempt \(attempt + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: WireProxy retry attempt \(attempt + 1)/\(maxRetries) failed for \(nextWG.serverName)", category: .vpn, level: .warning)
        }

        wgIndex += maxRetries
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: WireProxy all \(maxRetries) retry attempts exhausted", category: .vpn, level: .error)
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
        if !isEnabled && perSessionWireProxyActive {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            logger.log("DeviceProxy: WireProxy reconnect requested (per-session)", category: .vpn, level: .info)
            activatePerSessionWireProxy()
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
        if !isEnabled {
            perSessionWireProxyActive = false
            perSessionWGConfig = nil
        }
        logger.log("DeviceProxy: WireProxy manually stopped", category: .vpn, level: .info)
    }

    func handleUnifiedConnectionModeChange() {
        if !isWireProxyCompatibleMode {
            wireProxyBridge.stop()
            localProxy.enableWireProxyMode(false)
            stopPerSessionWireProxy()
        }

        if !isOpenVPNProxyCompatibleMode {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            stopPerSessionOpenVPN()
        }

        if isEnabled {
            performRotation(reason: "Connection Mode Changed")
        } else if isWireProxyCompatibleMode && !perSessionWireProxyActive {
            activatePerSessionWireProxy()
        } else if isOpenVPNProxyCompatibleMode && !perSessionOpenVPNActive {
            activatePerSessionOpenVPN()
        }
    }

    private(set) var perSessionWireProxyStarting: Bool = false

    func activatePerSessionWireProxy() {
        guard !isEnabled, isWireProxyCompatibleMode else { return }
        guard !perSessionWireProxyStarting else {
            logger.log("DeviceProxy: per-session WireProxy activation already in progress", category: .vpn, level: .debug)
            return
        }
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allWG = collectUniqueWG(targets: targets)
        guard !allWG.isEmpty else {
            logger.log("DeviceProxy: no WG configs available for per-session WireProxy", category: .vpn, level: .warning)
            return
        }

        perSessionWireProxyStarting = true
        perSessionWireProxyActive = true

        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)

        if localProxyEnabled {
            if !localProxy.isRunning {
                localProxy.start()
            }
        }

        Task {
            try? await Task.sleep(for: .seconds(0.5))

            if !localProxy.isRunning && localProxyEnabled {
                localProxy.start()
                try? await Task.sleep(for: .seconds(0.3))
            }

            if allWG.count >= 2 {
                let multiConfigs = Array(allWG.prefix(min(allWG.count, 6)))
                perSessionWGConfig = multiConfigs.first

                await wireProxyBridge.startMultiple(configs: multiConfigs)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy active → \(wireProxyBridge.activeTunnelCount)/\(multiConfigs.count) tunnels", category: .vpn, level: .success)
                } else {
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy failed — falling back to single", category: .vpn, level: .error)
                    await fallbackToSingleTunnel(allWG: allWG)
                }
            } else {
                let wg = allWG[wgIndex % allWG.count]
                wgIndex += 1
                perSessionWGConfig = wg

                await wireProxyBridge.start(with: wg)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: per-session WireProxy active → \(wg.serverName)", category: .vpn, level: .success)
                } else {
                    logger.log("DeviceProxy: per-session WireProxy failed for \(wg.serverName) — retrying", category: .vpn, level: .error)
                    await retryPerSessionWireProxy(failedServer: wg.serverName)
                }
            }

            if !wireProxyBridge.isActive {
                perSessionWireProxyActive = false
                perSessionWGConfig = nil
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: per-session WireProxy failed to start after all attempts", category: .vpn, level: .error)
            }

            perSessionWireProxyStarting = false
        }
    }

    private func fallbackToSingleTunnel(allWG: [WireGuardConfig]) async {
        for wg in allWG {
            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(0.3))
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                perSessionWGConfig = wg
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: single-tunnel fallback succeeded → \(wg.serverName)", category: .vpn, level: .success)
                return
            }
        }
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: all WG tunnel fallbacks failed", category: .vpn, level: .error)
    }

    private func retryPerSessionWireProxy(failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allWG = collectUniqueWG(targets: targets)
        let candidates = allWG.filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative WG configs for per-session retry", category: .vpn, level: .error)
            return
        }

        let maxRetries = min(candidates.count, 5)
        for i in 0..<maxRetries {
            let nextWG = candidates[(wgIndex + i) % candidates.count]
            perSessionWGConfig = nextWG

            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))

            await wireProxyBridge.start(with: nextWG)
            if wireProxyBridge.isActive {
                wgIndex += i + 1
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: per-session WireProxy retry succeeded → \(nextWG.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: per-session WireProxy retry \(i + 1)/\(maxRetries) failed for \(nextWG.serverName)", category: .vpn, level: .warning)
        }

        wgIndex += maxRetries
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: per-session WireProxy all \(maxRetries) retries exhausted", category: .vpn, level: .error)
    }

    private func stopPerSessionWireProxy() {
        guard perSessionWireProxyActive else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        perSessionWireProxyActive = false
        perSessionWGConfig = nil
        logger.log("DeviceProxy: per-session WireProxy stopped", category: .vpn, level: .info)
    }

    func rotatePerSessionWireProxy() {
        guard perSessionWireProxyActive, !isEnabled, !perSessionWireProxyStarting else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        perSessionWireProxyActive = false
        activatePerSessionWireProxy()
    }

    var perSessionTunnelCount: Int {
        wireProxyBridge.activeTunnelCount
    }

    var isMultiTunnelActive: Bool {
        wireProxyBridge.multiTunnelMode && wireProxyBridge.activeTunnelCount > 1
    }

    var wireProxyActiveConfigLabel: String? {
        if isEnabled, case .wireGuardDNS(let wg) = activeConfig {
            return wg.serverName
        }
        if perSessionWireProxyActive, let wg = perSessionWGConfig {
            return wg.serverName
        }
        return nil
    }

    var openVPNActiveConfigLabel: String? {
        if isEnabled, case .openVPNProxy(let ovpn) = activeConfig {
            return ovpn.serverName
        }
        if perSessionOpenVPNActive, let ovpn = perSessionOVPNConfig {
            return ovpn.serverName
        }
        return nil
    }

    // MARK: - Per-Session OpenVPN

    func activatePerSessionOpenVPN() {
        guard !isEnabled, isOpenVPNProxyCompatibleMode else { return }
        guard !perSessionOpenVPNStarting else {
            logger.log("DeviceProxy: per-session OpenVPN activation already in progress", category: .vpn, level: .debug)
            return
        }
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allOVPN = collectUniqueOVPN(targets: targets)
        guard !allOVPN.isEmpty else {
            logger.log("DeviceProxy: no OVPN configs available for per-session OpenVPN", category: .vpn, level: .warning)
            return
        }

        perSessionOpenVPNStarting = true
        perSessionOpenVPNActive = true

        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)

        if localProxyEnabled && !localProxy.isRunning {
            localProxy.start()
        }

        Task {
            try? await Task.sleep(for: .seconds(0.5))

            if !localProxy.isRunning && localProxyEnabled {
                localProxy.start()
                try? await Task.sleep(for: .seconds(0.3))
            }

            let ovpn = allOVPN[ovpnIndex % allOVPN.count]
            ovpnIndex += 1
            perSessionOVPNConfig = ovpn

            await ovpnBridge.start(with: ovpn)
            if ovpnBridge.isActive {
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: per-session OpenVPN active \u{2192} \(ovpn.serverName) via \(ovpnBridge.activeProxyLabel ?? "unknown")", category: .vpn, level: .success)
            } else {
                logger.log("DeviceProxy: per-session OpenVPN failed for \(ovpn.serverName) \u{2014} retrying", category: .vpn, level: .error)
                await retryPerSessionOpenVPN(failedServer: ovpn.serverName)
            }

            if !ovpnBridge.isActive {
                perSessionOpenVPNActive = false
                perSessionOVPNConfig = nil
                localProxy.enableOpenVPNProxyMode(false)
                logger.log("DeviceProxy: per-session OpenVPN failed to start after all attempts", category: .vpn, level: .error)
            }

            perSessionOpenVPNStarting = false
        }
    }

    private func retryPerSessionOpenVPN(failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allOVPN = collectUniqueOVPN(targets: targets)
        let candidates = allOVPN.filter { $0.serverName != failedServer }
        guard !candidates.isEmpty else {
            logger.log("DeviceProxy: no alternative OVPN configs for per-session retry", category: .vpn, level: .error)
            return
        }

        let maxRetries = min(candidates.count, 5)
        for i in 0..<maxRetries {
            let nextOVPN = candidates[(ovpnIndex + i) % candidates.count]
            perSessionOVPNConfig = nextOVPN

            ovpnBridge.stop()
            try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))

            await ovpnBridge.start(with: nextOVPN)
            if ovpnBridge.isActive {
                ovpnIndex += i + 1
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: per-session OpenVPN retry succeeded \u{2192} \(nextOVPN.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                return
            }
            logger.log("DeviceProxy: per-session OpenVPN retry \(i + 1)/\(maxRetries) failed for \(nextOVPN.serverName)", category: .vpn, level: .warning)
        }

        ovpnIndex += maxRetries
        localProxy.enableOpenVPNProxyMode(false)
        logger.log("DeviceProxy: per-session OpenVPN all \(maxRetries) retries exhausted", category: .vpn, level: .error)
    }

    private func stopPerSessionOpenVPN() {
        guard perSessionOpenVPNActive else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        perSessionOpenVPNActive = false
        perSessionOVPNConfig = nil
        logger.log("DeviceProxy: per-session OpenVPN stopped", category: .vpn, level: .info)
    }

    func rotatePerSessionOpenVPN() {
        guard perSessionOpenVPNActive, !isEnabled, !perSessionOpenVPNStarting else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        perSessionOpenVPNActive = false
        activatePerSessionOpenVPN()
    }

    func reconnectOpenVPN() {
        if !isEnabled && perSessionOpenVPNActive {
            ovpnBridge.stop()
            localProxy.enableOpenVPNProxyMode(false)
            logger.log("DeviceProxy: OpenVPN reconnect requested (per-session)", category: .vpn, level: .info)
            activatePerSessionOpenVPN()
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
        if !isEnabled {
            perSessionOpenVPNActive = false
            perSessionOVPNConfig = nil
        }
        logger.log("DeviceProxy: OpenVPN manually stopped", category: .vpn, level: .info)
    }

    func handleProfileSwitch() {
        wireProxyBridge.stop()
        ovpnBridge.stop()
        localProxy.enableWireProxyMode(false)
        localProxy.enableOpenVPNProxyMode(false)
        localProxy.updateUpstream(nil)
        perSessionWireProxyActive = false
        perSessionWGConfig = nil
        perSessionOpenVPNActive = false
        perSessionOVPNConfig = nil
        perSessionOpenVPNStarting = false
        intel.clearAll()

        activeConfig = nil
        activeEndpointLabel = nil
        activeConnectionType = "None"
        activeSince = nil
        isActive = false

        wgIndex = 0
        ovpnIndex = 0
        socks5Index = 0

        rotationLog.removeAll()

        if ipRoutingMode == .appWideUnited {
            performRotation(reason: "Profile Switch")
        } else if isWireProxyCompatibleMode {
            activatePerSessionWireProxy()
        } else if isOpenVPNProxyCompatibleMode {
            activatePerSessionOpenVPN()
        }

        let profile = NordVPNService.shared.activeKeyProfile
        logger.log("DeviceProxy: profile switched to \(profile.rawValue) — tunnel stopped, state reset, configs reloaded", category: .network, level: .success)
    }

    func rotateWireProxyConfig() {
        if !isEnabled && perSessionWireProxyActive {
            rotatePerSessionWireProxy()
            return
        }
        guard canManageWireProxyTunnel else { return }
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
        if ipRoutingMode == .appWideUnited, isActive, localProxyEnabled, localProxy.isRunning {
            switch activeConfig {
            case .socks5:
                return localProxy.localProxyConfig
            case .wireGuardDNS:
                if isWireProxyCompatibleMode, wireProxyBridge.isActive {
                    return localProxy.localProxyConfig
                }
                return nil
            case .openVPNProxy:
                if ovpnBridge.isActive, localProxy.openVPNProxyMode {
                    return localProxy.localProxyConfig
                }
                return nil
            case .direct, .none:
                return nil
            }
        }

        if ipRoutingMode == .separatePerSession, localProxyEnabled, localProxy.isRunning {
            if perSessionWireProxyActive, wireProxyBridge.isActive, localProxy.wireProxyMode {
                return localProxy.localProxyConfig
            }
            if perSessionOpenVPNActive, ovpnBridge.isActive, localProxy.openVPNProxyMode {
                return localProxy.localProxyConfig
            }
        }

        return nil
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

        case .nodeMaven:
            let nm = NodeMavenService.shared
            if let proxy = nm.generateProxyConfig() { return .socks5(proxy) }
            if let result = nextFromSOCKS5(allProxies) { return result }
            if let result = nextFromWG(allWG) { return result }
            if let result = nextFromOVPN(allOVPN) { return result }

        case .hybrid:
            return HybridNetworkingService.shared.nextHybridConfig(for: .joe)
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
        if let aiPick = aiRankedWGConfig(from: configs) {
            logger.log("DeviceProxy: AI-ranked WG \(aiPick.displayString)", category: .vpn, level: .debug)
            return .wireGuardDNS(aiPick)
        }
        let config = configs[wgIndex % configs.count]
        wgIndex += 1
        return .wireGuardDNS(config)
    }

    private func aiRankedWGConfig(from configs: [WireGuardConfig]) -> WireGuardConfig? {
        guard configs.count > 1 else { return nil }
        let strategy = aiProxyStrategy
        let host = "unified"
        var scored: [(WireGuardConfig, Double)] = []
        for wg in configs {
            let key = "wg_\(wg.uniqueKey)"
            let profiles = strategy.proxyPerformanceSummary(for: host)
            if let match = profiles.first(where: { $0.proxyId == key }) {
                scored.append((wg, match.score))
            } else {
                scored.append((wg, 0.5))
            }
        }
        scored.sort { $0.1 > $1.1 }
        let topCount = max(1, min(3, scored.count))
        let candidates = Array(scored.prefix(topCount))
        return candidates.randomElement()?.0
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
            if let aiPick = aiProxyStrategy.bestProxy(for: "unified", from: working, target: .joe) {
                logger.log("DeviceProxy: AI-selected SOCKS5 \(aiPick.displayString)", category: .proxy, level: .debug)
                return .socks5(aiPick)
            }
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
        let key = settingsKey
        let fallbackKey = "device_proxy_settings_v1"
        let dict = UserDefaults.standard.dictionary(forKey: key) ?? UserDefaults.standard.dictionary(forKey: fallbackKey)
        guard let dict else { return }
        if let modeRaw = dict["ipRoutingMode"] as? String,
           let mode = IPRoutingMode(rawValue: modeRaw) {
            ipRoutingMode = mode
        } else if let enabled = dict["enabled"] as? Bool {
            ipRoutingMode = enabled ? .appWideUnited : .separatePerSession
        }
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
