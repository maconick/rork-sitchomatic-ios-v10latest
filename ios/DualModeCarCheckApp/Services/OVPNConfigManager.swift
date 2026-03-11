import Foundation

@MainActor
class OVPNConfigManager {
    var joeConfigs: [OpenVPNConfig] = []
    var ignitionConfigs: [OpenVPNConfig] = []
    var ppsrConfigs: [OpenVPNConfig] = []
    var currentJoeIndex: Int = 0
    var currentIgnitionIndex: Int = 0
    var currentPPSRIndex: Int = 0

    private let joePersistKey = "openvpn_configs_joe_v1"
    private let ignitionPersistKey = "openvpn_configs_ignition_v1"
    private let ppsrPersistKey = "openvpn_configs_ppsr_v1"
    private let logger = DebugLogger.shared

    func loadAll() {
        if let data = UserDefaults.standard.data(forKey: joePersistKey),
           let configs = try? JSONDecoder().decode([OpenVPNConfig].self, from: data) { joeConfigs = configs }
        if let data = UserDefaults.standard.data(forKey: ignitionPersistKey),
           let configs = try? JSONDecoder().decode([OpenVPNConfig].self, from: data) { ignitionConfigs = configs }
        if let data = UserDefaults.standard.data(forKey: ppsrPersistKey),
           let configs = try? JSONDecoder().decode([OpenVPNConfig].self, from: data) { ppsrConfigs = configs }
    }

    func configs(for target: ProxyRotationService.ProxyTarget) -> [OpenVPNConfig] {
        switch target {
        case .joe: joeConfigs
        case .ignition: ignitionConfigs
        case .ppsr: ppsrConfigs
        }
    }

    func nextEnabled(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
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

    func nextReachable(for target: ProxyRotationService.ProxyTarget) -> OpenVPNConfig? {
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

    func importConfig(_ config: OpenVPNConfig, for target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: guard !joeConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }; joeConfigs.append(config)
        case .ignition: guard !ignitionConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }; ignitionConfigs.append(config)
        case .ppsr: guard !ppsrConfigs.contains(where: { $0.remoteHost == config.remoteHost && $0.remotePort == config.remotePort }) else { return }; ppsrConfigs.append(config)
        }
        persist(for: target)
    }

    func removeConfig(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeConfigs.removeAll { $0.id == config.id }
        case .ignition: ignitionConfigs.removeAll { $0.id == config.id }
        case .ppsr: ppsrConfigs.removeAll { $0.id == config.id }
        }
        persist(for: target)
    }

    func toggleConfig(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget, enabled: Bool) {
        switch target {
        case .joe: if let idx = joeConfigs.firstIndex(where: { $0.id == config.id }) { joeConfigs[idx].isEnabled = enabled }
        case .ignition: if let idx = ignitionConfigs.firstIndex(where: { $0.id == config.id }) { ignitionConfigs[idx].isEnabled = enabled }
        case .ppsr: if let idx = ppsrConfigs.firstIndex(where: { $0.id == config.id }) { ppsrConfigs[idx].isEnabled = enabled }
        }
        persist(for: target)
    }

    func markReachable(_ config: OpenVPNConfig, target: ProxyRotationService.ProxyTarget, reachable: Bool, latencyMs: Int? = nil) {
        func update(_ configs: inout [OpenVPNConfig]) {
            if let idx = configs.firstIndex(where: { $0.id == config.id || $0.uniqueKey == config.uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                configs[idx].lastLatencyMs = latencyMs
                if reachable { configs[idx].failCount = 0; configs[idx].isEnabled = true }
                else { configs[idx].failCount += 1; if configs[idx].failCount >= 2 { configs[idx].isEnabled = false } }
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
        logger.log("OVPNConfigManager: synced \(joeConfigs.count) OVPN configs across all targets", category: .vpn, level: .info)
    }

    func applyTestResult(uniqueKey: String, reachable: Bool, latency: Int, target: ProxyRotationService.ProxyTarget) {
        func update(_ configs: inout [OpenVPNConfig]) {
            if let idx = configs.firstIndex(where: { $0.uniqueKey == uniqueKey }) {
                configs[idx].isReachable = reachable
                configs[idx].lastTested = Date()
                configs[idx].lastLatencyMs = reachable ? latency : nil
                if reachable { configs[idx].failCount = 0; configs[idx].isEnabled = true }
                else { configs[idx].failCount += 1; if configs[idx].failCount >= 2 { configs[idx].isEnabled = false } }
            }
        }
        switch target {
        case .joe: update(&joeConfigs)
        case .ignition: update(&ignitionConfigs)
        case .ppsr: update(&ppsrConfigs)
        }
    }

    func resetRotationIndexes() {
        currentJoeIndex = 0
        currentIgnitionIndex = 0
        currentPPSRIndex = 0
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {
        let key: String
        let configs: [OpenVPNConfig]
        switch target {
        case .joe: key = joePersistKey; configs = joeConfigs
        case .ignition: key = ignitionPersistKey; configs = ignitionConfigs
        case .ppsr: key = ppsrPersistKey; configs = ppsrConfigs
        }
        do {
            let data = try JSONEncoder().encode(configs)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            logger.logError("OVPNConfigManager: failed to persist for \(target.rawValue)", error: error, category: .persistence)
        }
    }
}
