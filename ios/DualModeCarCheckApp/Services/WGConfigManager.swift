import Foundation

@MainActor
class WGConfigManager {
    private let proxyService = ProxyRotationService.shared

    var joeConfigs: [WireGuardConfig] { proxyService.joeWGConfigs }
    var ignitionConfigs: [WireGuardConfig] { proxyService.ignitionWGConfigs }
    var ppsrConfigs: [WireGuardConfig] { proxyService.ppsrWGConfigs }

    func loadAll() {}

    func configs(for target: ProxyRotationService.ProxyTarget) -> [WireGuardConfig] {
        proxyService.wgConfigs(for: target)
    }

    func nextEnabled(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        proxyService.nextEnabledWGConfig(for: target)
    }

    func nextReachable(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        proxyService.nextReachableWGConfig(for: target)
    }

    func importConfig(_ config: WireGuardConfig, for target: ProxyRotationService.ProxyTarget) {
        proxyService.importWGConfig(config, for: target)
    }

    func bulkImport(_ configs: [WireGuardConfig], for target: ProxyRotationService.ProxyTarget) -> ProxyRotationService.ImportReport {
        proxyService.bulkImportWGConfigs(configs, for: target)
    }

    func removeConfig(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget) {
        proxyService.removeWGConfig(config, target: target)
    }

    func toggleConfig(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget, enabled: Bool) {
        proxyService.toggleWGConfig(config, target: target, enabled: enabled)
    }

    func markReachable(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget, reachable: Bool) {
        proxyService.markWGConfigReachable(config, target: target, reachable: reachable)
    }

    func clearAll(target: ProxyRotationService.ProxyTarget) {
        proxyService.clearAllWGConfigs(target: target)
    }

    func removeUnreachable(target: ProxyRotationService.ProxyTarget) {
        proxyService.removeUnreachableWGConfigs(target: target)
    }

    func syncAcrossTargets() {
        proxyService.syncWGConfigsAcrossTargets()
    }

    func applyTestResult(uniqueKey: String, reachable: Bool, target: ProxyRotationService.ProxyTarget) {
        if let config = proxyService.wgConfigs(for: target).first(where: { $0.uniqueKey == uniqueKey }) {
            proxyService.markWGConfigReachable(config, target: target, reachable: reachable)
        }
    }

    func resetTestState(for target: ProxyRotationService.ProxyTarget) {}

    func resetRotationIndexes() {
        proxyService.resetRotationIndexes()
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {}
}
