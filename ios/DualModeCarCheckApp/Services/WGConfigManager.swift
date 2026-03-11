import Foundation

@MainActor
class WGConfigManager {
    var joeConfigs: [WireGuardConfig] = []
    var ignitionConfigs: [WireGuardConfig] = []
    var ppsrConfigs: [WireGuardConfig] = []
    var currentJoeIndex: Int = 0
    var currentIgnitionIndex: Int = 0
    var currentPPSRIndex: Int = 0

    private let joePersistKey = "wireguard_configs_joe_v1"
    private let ignitionPersistKey = "wireguard_configs_ignition_v1"
    private let ppsrPersistKey = "wireguard_configs_ppsr_v1"
    private let logger = DebugLogger.shared

    func loadAll() {
        if let data = UserDefaults.standard.data(forKey: joePersistKey),
           let configs = try? JSONDecoder().decode([WireGuardConfig].self, from: data) { joeConfigs = configs }
        if let data = UserDefaults.standard.data(forKey: ignitionPersistKey),
           let configs = try? JSONDecoder().decode([WireGuardConfig].self, from: data) { ignitionConfigs = configs }
        if let data = UserDefaults.standard.data(forKey: ppsrPersistKey),
           let configs = try? JSONDecoder().decode([WireGuardConfig].self, from: data) { ppsrConfigs = configs }
    }

    func configs(for target: ProxyRotationService.ProxyTarget) -> [WireGuardConfig] {
        switch target {
        case .joe: joeConfigs
        case .ignition: ignitionConfigs
        case .ppsr: ppsrConfigs
        }
    }

    func nextEnabled(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        let list = configs(for: target).filter { $0.isEnabled }
        guard !list.isEmpty else { return nil }
        let idx: Int
        switch target {
        case .joe: idx = currentJoeIndex % list.count; currentJoeIndex = idx + 1
        case .ignition: idx = currentIgnitionIndex % list.count; currentIgnitionIndex = idx + 1
        case .ppsr: idx = currentPPSRIndex % list.count; currentPPSRIndex = idx + 1
        }
        return list[idx]
    }

    func nextReachable(for target: ProxyRotationService.ProxyTarget) -> WireGuardConfig? {
        let reachable = configs(for: target).filter { $0.isEnabled && $0.isReachable }
        if !reachable.isEmpty {
            let idx: Int
            switch target {
            case .joe: idx = currentJoeIndex % reachable.count; currentJoeIndex = idx + 1
            case .ignition: idx = currentIgnitionIndex % reachable.count; currentIgnitionIndex = idx + 1
            case .ppsr: idx = currentPPSRIndex % reachable.count; currentPPSRIndex = idx + 1
            }
            return reachable[idx]
        }
        return nextEnabled(for: target)
    }

    func importConfig(_ config: WireGuardConfig, for target: ProxyRotationService.ProxyTarget) {
        let existing = configs(for: target)
        guard !existing.contains(where: { $0.uniqueKey == config.uniqueKey }) else { return }
        switch target {
        case .joe: joeConfigs.append(config)
        case .ignition: ignitionConfigs.append(config)
        case .ppsr: ppsrConfigs.append(config)
        }
        persist(for: target)
    }

    func bulkImport(_ configs: [WireGuardConfig], for target: ProxyRotationService.ProxyTarget) -> ProxyRotationService.ImportReport {
        var added = 0
        var duplicates = 0
        let failed: [String] = []
        var seenKeys = Set(self.configs(for: target).map(\.uniqueKey))
        for config in configs {
            if seenKeys.contains(config.uniqueKey) { duplicates += 1 }
            else {
                seenKeys.insert(config.uniqueKey)
                switch target {
                case .joe: joeConfigs.append(config)
                case .ignition: ignitionConfigs.append(config)
                case .ppsr: ppsrConfigs.append(config)
                }
                added += 1
            }
        }
        if added > 0 { persist(for: target) }
        return ProxyRotationService.ImportReport(added: added, duplicates: duplicates, failed: failed)
    }

    func removeConfig(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        case .ignition: ignitionConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        case .ppsr: ppsrConfigs.removeAll { $0.id == config.id || $0.uniqueKey == config.uniqueKey }
        }
        persist(for: target)
    }

    func toggleConfig(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget, enabled: Bool) {
        switch target {
        case .joe: if let idx = joeConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { joeConfigs[idx].isEnabled = enabled }
        case .ignition: if let idx = ignitionConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { ignitionConfigs[idx].isEnabled = enabled }
        case .ppsr: if let idx = ppsrConfigs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) { ppsrConfigs[idx].isEnabled = enabled }
        }
        persist(for: target)
    }

    func markReachable(_ config: WireGuardConfig, target: ProxyRotationService.ProxyTarget, reachable: Bool) {
        func update(_ configs: inout [WireGuardConfig]) {
            if let idx = configs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                if reachable { configs[idx].failCount = 0; configs[idx].isEnabled = true }
                else { configs[idx].failCount += 1; if configs[idx].failCount >= 3 { configs[idx].isEnabled = false } }
            }
        }
        switch target {
        case .joe: update(&joeConfigs)
        case .ignition: update(&ignitionConfigs)
        case .ppsr: update(&ppsrConfigs)
        }
        persist(for: target)
    }

    func clearAll(target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeConfigs.removeAll()
        case .ignition: ignitionConfigs.removeAll()
        case .ppsr: ppsrConfigs.removeAll()
        }
        persist(for: target)
    }

    func removeUnreachable(target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ignition: ignitionConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        case .ppsr: ppsrConfigs.removeAll { !$0.isReachable && $0.lastTested != nil }
        }
        persist(for: target)
    }

    func syncAcrossTargets() {
        ignitionConfigs = joeConfigs
        ppsrConfigs = joeConfigs
        persist(for: .ignition)
        persist(for: .ppsr)
        logger.log("WGConfigManager: synced \(joeConfigs.count) WG configs across all targets", category: .vpn, level: .info)
    }

    func applyTestResult(uniqueKey: String, reachable: Bool, target: ProxyRotationService.ProxyTarget) {
        func update(_ configs: inout [WireGuardConfig]) {
            if let idx = configs.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                if reachable { configs[idx].failCount = 0; configs[idx].isEnabled = true }
                else { configs[idx].failCount += 1; if configs[idx].failCount >= 3 { configs[idx].isEnabled = false } }
            }
        }
        switch target {
        case .joe: update(&joeConfigs)
        case .ignition: update(&ignitionConfigs)
        case .ppsr: update(&ppsrConfigs)
        }
    }

    func resetTestState(for target: ProxyRotationService.ProxyTarget) {
        func reset(_ configs: inout [WireGuardConfig]) {
            for i in configs.indices { configs[i].isEnabled = true; configs[i].isReachable = false; configs[i].lastTested = nil; configs[i].failCount = 0 }
        }
        switch target {
        case .joe: reset(&joeConfigs)
        case .ignition: reset(&ignitionConfigs)
        case .ppsr: reset(&ppsrConfigs)
        }
    }

    func resetRotationIndexes() {
        currentJoeIndex = 0
        currentIgnitionIndex = 0
        currentPPSRIndex = 0
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {
        let key: String
        let configs: [WireGuardConfig]
        switch target {
        case .joe: key = joePersistKey; configs = joeConfigs
        case .ignition: key = ignitionPersistKey; configs = ignitionConfigs
        case .ppsr: key = ppsrPersistKey; configs = ppsrConfigs
        }
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.logError("WGConfigManager: failed to persist for \(target.rawValue)", error: error, category: .persistence)
        }
    }
}
