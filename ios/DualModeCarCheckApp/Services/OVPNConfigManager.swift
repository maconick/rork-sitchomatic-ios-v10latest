import Foundation

@MainActor
class OVPNConfigManager {
    private let proxyService = ProxyRotationService.shared

    var joeConfigs: [OpenVPNConfig] { proxyService.joeVPNConfigs }
    var ignitionConfigs: [OpenVPNConfig] { proxyService.ignitionVPNConfigs }
    var ppsrConfigs: [OpenVPNConfig] { proxyService.ppsrVPNConfigs }

    func loadAll() {}

    func configs(for target: ProxyRotationService.ProxyTarget) -> [OpenVPNConfig] {
        proxyService.vpnConfigs(for: target)
    }

    func nextEnabled(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
        proxyService.nextEnabledOVPNConfig(for: target)
    }

    func nextReachable(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
        proxyService.nextReachableOVPNConfig(for: target)
    }

    func importConfig(_ config: OpenVPNConfig, for target: ProxyRotationService.ProxyTarget) {
        proxyService.importVPNConfig(config, for: target)
    }

    func removeConfig(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget) {
        proxyService.removeVPNConfig(config, target: target)
    }

    func toggleConfig(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget, enabled: Bool) {
        proxyService.toggleVPNConfig(config, target: target, enabled: enabled)
    }

    func markReachable(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget, reachable: Bool, latencyMs: Int? = nil) {
        proxyService.markVPNConfigReachable(config, target: target, reachable: reachable, latencyMs: latencyMs)
    }

    func clearAll(target: ProxyRotationService.ProxyTarget) {
        proxyService.clearAllVPNConfigs(target: target)
    }

    func removeUnreachable(target: ProxyRotationService.ProxyTarget) {
        proxyService.removeUnreachableVPNConfigs(target: target)
    }

    func syncAcrossTargets() {
        proxyService.syncVPNConfigsAcrossTargets()
    }

    func applyTestResult(uniqueKey: String, reachable: Bool, latency: Int, target: ProxyRotationService.ProxyTarget) {
        if let config = proxyService.vpnConfigs(for: target).first(where: { $0.uniqueKey == uniqueKey }) {
            proxyService.markVPNConfigReachable(config, target: target, reachable: reachable, latencyMs: latency)
        }
    }

    func resetRotationIndexes() {
        proxyService.resetRotationIndexes()
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {}
}
