import Foundation

@MainActor
class PerSessionTunnelManager {
    private let proxyService = ProxyRotationService.shared
    private let localProxy = LocalProxyServer.shared
    private let wireProxyBridge = WireProxyBridge.shared
    private let ovpnBridge = OpenVPNProxyBridge.shared
    private let configResolver: ProxyConfigResolver
    private let logger = DebugLogger.shared

    private(set) var wireProxyActive: Bool = false
    private(set) var wireProxyStarting: Bool = false
    private var wgConfig: WireGuardConfig?

    private(set) var openVPNActive: Bool = false
    private(set) var openVPNStarting: Bool = false
    private var ovpnConfig: OpenVPNConfig?

    init(configResolver: ProxyConfigResolver) {
        self.configResolver = configResolver
    }

    var tunnelCount: Int { wireProxyBridge.activeTunnelCount }
    var isMultiTunnelActive: Bool { wireProxyBridge.multiTunnelMode && wireProxyBridge.activeTunnelCount > 1 }

    var wireProxyConfigLabel: String? {
        wireProxyActive ? wgConfig?.serverName : nil
    }

    var openVPNConfigLabel: String? {
        openVPNActive ? ovpnConfig?.serverName : nil
    }

    // MARK: - WireGuard Per-Session

    func activateWireProxy(localProxyEnabled: Bool) {
        guard !wireProxyStarting else {
            logger.log("DeviceProxy: per-session WireProxy activation already in progress", category: .vpn, level: .debug)
            return
        }
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allWG = configResolver.collectUniqueWG(targets: targets)
        guard !allWG.isEmpty else {
            logger.log("DeviceProxy: no WG configs available for per-session WireProxy", category: .vpn, level: .warning)
            return
        }

        wireProxyStarting = true
        wireProxyActive = true
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)

        ensureLocalProxy(enabled: localProxyEnabled)

        Task {
            try? await Task.sleep(for: .seconds(0.5))
            if !localProxy.isRunning && localProxyEnabled {
                localProxy.start()
                try? await Task.sleep(for: .seconds(0.3))
            }

            if allWG.count >= 2 {
                let multiConfigs = Array(allWG.prefix(min(allWG.count, 6)))
                wgConfig = multiConfigs.first
                await wireProxyBridge.startMultiple(configs: multiConfigs)
                if wireProxyBridge.isActive {
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy active → \(wireProxyBridge.activeTunnelCount)/\(multiConfigs.count) tunnels", category: .vpn, level: .success)
                } else {
                    logger.log("DeviceProxy: per-session multi-tunnel WireProxy failed — falling back to single", category: .vpn, level: .error)
                    await fallbackToSingleTunnel(allWG: allWG)
                }
            } else {
                await startSingleWGTunnel(allWG: allWG)
            }

            if !wireProxyBridge.isActive {
                wireProxyActive = false
                wgConfig = nil
                localProxy.enableWireProxyMode(false)
                logger.log("DeviceProxy: per-session WireProxy failed to start after all attempts", category: .vpn, level: .error)
            }
            wireProxyStarting = false
        }
    }

    func rotateWireProxy(localProxyEnabled: Bool) {
        guard wireProxyActive, !wireProxyStarting else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        wireProxyActive = false
        activateWireProxy(localProxyEnabled: localProxyEnabled)
    }

    func stopWireProxy() {
        guard wireProxyActive else { return }
        wireProxyBridge.stop()
        localProxy.enableWireProxyMode(false)
        wireProxyActive = false
        wgConfig = nil
        logger.log("DeviceProxy: per-session WireProxy stopped", category: .vpn, level: .info)
    }

    private func startSingleWGTunnel(allWG: [WireGuardConfig]) async {
        guard !allWG.isEmpty else { return }
        let wg = allWG[0]
        wgConfig = wg
        await wireProxyBridge.start(with: wg)
        if wireProxyBridge.isActive {
            localProxy.enableWireProxyMode(true)
            logger.log("DeviceProxy: per-session WireProxy active → \(wg.serverName)", category: .vpn, level: .success)
        } else {
            logger.log("DeviceProxy: per-session WireProxy failed for \(wg.serverName) — retrying", category: .vpn, level: .error)
            await retryTunnel(type: .wireGuard, failedServer: wg.serverName)
        }
    }

    private func fallbackToSingleTunnel(allWG: [WireGuardConfig]) async {
        for wg in allWG {
            wireProxyBridge.stop()
            try? await Task.sleep(for: .seconds(0.3))
            await wireProxyBridge.start(with: wg)
            if wireProxyBridge.isActive {
                wgConfig = wg
                localProxy.enableWireProxyMode(true)
                logger.log("DeviceProxy: single-tunnel fallback succeeded → \(wg.serverName)", category: .vpn, level: .success)
                return
            }
        }
        localProxy.enableWireProxyMode(false)
        logger.log("DeviceProxy: all WG tunnel fallbacks failed", category: .vpn, level: .error)
    }

    // MARK: - OpenVPN Per-Session

    func activateOpenVPN(localProxyEnabled: Bool) {
        guard !openVPNStarting else {
            logger.log("DeviceProxy: per-session OpenVPN activation already in progress", category: .vpn, level: .debug)
            return
        }
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let allOVPN = configResolver.collectUniqueOVPN(targets: targets)
        guard !allOVPN.isEmpty else {
            logger.log("DeviceProxy: no OVPN configs available for per-session OpenVPN", category: .vpn, level: .warning)
            return
        }

        openVPNStarting = true
        openVPNActive = true
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)

        ensureLocalProxy(enabled: localProxyEnabled)

        Task {
            try? await Task.sleep(for: .seconds(0.5))
            if !localProxy.isRunning && localProxyEnabled {
                localProxy.start()
                try? await Task.sleep(for: .seconds(0.3))
            }

            let ovpn = allOVPN[0]
            ovpnConfig = ovpn
            await ovpnBridge.start(with: ovpn)
            if ovpnBridge.isActive {
                localProxy.enableOpenVPNProxyMode(true)
                logger.log("DeviceProxy: per-session OpenVPN active → \(ovpn.serverName) via \(ovpnBridge.activeProxyLabel ?? "unknown")", category: .vpn, level: .success)
            } else {
                logger.log("DeviceProxy: per-session OpenVPN failed for \(ovpn.serverName) — retrying", category: .vpn, level: .error)
                await retryTunnel(type: .openVPN, failedServer: ovpn.serverName)
            }

            if !ovpnBridge.isActive {
                openVPNActive = false
                ovpnConfig = nil
                localProxy.enableOpenVPNProxyMode(false)
                logger.log("DeviceProxy: per-session OpenVPN failed to start after all attempts", category: .vpn, level: .error)
            }
            openVPNStarting = false
        }
    }

    func rotateOpenVPN(localProxyEnabled: Bool) {
        guard openVPNActive, !openVPNStarting else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        openVPNActive = false
        activateOpenVPN(localProxyEnabled: localProxyEnabled)
    }

    func stopOpenVPN() {
        guard openVPNActive else { return }
        ovpnBridge.stop()
        localProxy.enableOpenVPNProxyMode(false)
        openVPNActive = false
        ovpnConfig = nil
        logger.log("DeviceProxy: per-session OpenVPN stopped", category: .vpn, level: .info)
    }

    // MARK: - Shared Retry

    private enum TunnelType { case wireGuard, openVPN }

    private func retryTunnel(type: TunnelType, failedServer: String) async {
        let targets: [ProxyRotationService.ProxyTarget] = [.joe, .ignition, .ppsr]
        let label = type == .wireGuard ? "WireProxy" : "OpenVPN"

        switch type {
        case .wireGuard:
            let allWG = configResolver.collectUniqueWG(targets: targets)
            let candidates = allWG.filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative WG configs for per-session retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 5)
            for i in 0..<maxRetries {
                let next = candidates[i % candidates.count]
                wgConfig = next
                wireProxyBridge.stop()
                try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))
                await wireProxyBridge.start(with: next)
                if wireProxyBridge.isActive {
                    configResolver.advanceWGIndex(by: i + 1)
                    localProxy.enableWireProxyMode(true)
                    logger.log("DeviceProxy: per-session \(label) retry succeeded → \(next.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: per-session \(label) retry \(i + 1)/\(maxRetries) failed for \(next.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceWGIndex(by: maxRetries)
            localProxy.enableWireProxyMode(false)

        case .openVPN:
            let allOVPN = configResolver.collectUniqueOVPN(targets: targets)
            let candidates = allOVPN.filter { $0.serverName != failedServer }
            guard !candidates.isEmpty else {
                logger.log("DeviceProxy: no alternative OVPN configs for per-session retry", category: .vpn, level: .error)
                return
            }
            let maxRetries = min(candidates.count, 5)
            for i in 0..<maxRetries {
                let next = candidates[i % candidates.count]
                ovpnConfig = next
                ovpnBridge.stop()
                try? await Task.sleep(for: .seconds(Double(i) * 0.5 + 0.5))
                await ovpnBridge.start(with: next)
                if ovpnBridge.isActive {
                    configResolver.advanceOVPNIndex(by: i + 1)
                    localProxy.enableOpenVPNProxyMode(true)
                    logger.log("DeviceProxy: per-session \(label) retry succeeded → \(next.serverName) on attempt \(i + 1)/\(maxRetries)", category: .vpn, level: .success)
                    return
                }
                logger.log("DeviceProxy: per-session \(label) retry \(i + 1)/\(maxRetries) failed for \(next.serverName)", category: .vpn, level: .warning)
            }
            configResolver.advanceOVPNIndex(by: maxRetries)
            localProxy.enableOpenVPNProxyMode(false)
        }

        logger.log("DeviceProxy: per-session \(label) all retries exhausted", category: .vpn, level: .error)
    }

    // MARK: - Reset

    func resetAll() {
        wireProxyBridge.stop()
        ovpnBridge.stop()
        localProxy.enableWireProxyMode(false)
        localProxy.enableOpenVPNProxyMode(false)
        wireProxyActive = false
        wgConfig = nil
        openVPNActive = false
        ovpnConfig = nil
        openVPNStarting = false
        wireProxyStarting = false
    }

    // MARK: - Helpers

    private func ensureLocalProxy(enabled: Bool) {
        if enabled && !localProxy.isRunning {
            localProxy.start()
        }
    }
}
