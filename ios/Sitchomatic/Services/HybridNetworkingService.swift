import Foundation

@Observable
@MainActor
class HybridNetworkingService {
    static let shared = HybridNetworkingService()

    private let proxyService = ProxyRotationService.shared
    private let aiStrategy = AIProxyStrategyService.shared
    private let logger = DebugLogger.shared

    private var sessionIndex: Int = 0
    private var methodHealthScores: [HybridMethod: Double] = [:]
    private let persistKey = "hybrid_networking_health_v1"

    nonisolated enum HybridMethod: String, CaseIterable, Sendable {
        case wireProxy = "WireProxy"
        case nodeMaven = "NodeMaven"
        case openVPN = "OpenVPN"
        case socks5 = "SOCKS5"
        case httpsDOH = "HTTPS/DoH"

        var icon: String {
            switch self {
            case .wireProxy: "lock.trianglebadge.exclamationmark.fill"
            case .nodeMaven: "cloud.fill"
            case .openVPN: "shield.lefthalf.filled"
            case .socks5: "network"
            case .httpsDOH: "lock.shield.fill"
            }
        }

        var priority: Int {
            switch self {
            case .wireProxy: 0
            case .nodeMaven: 1
            case .openVPN: 2
            case .socks5: 3
            case .httpsDOH: 4
            }
        }
    }

    nonisolated struct HybridSessionAssignment: Sendable {
        let method: HybridMethod
        let config: ActiveNetworkConfig
        let label: String
    }

    var lastAssignments: [HybridSessionAssignment] = []
    var isActive: Bool = false
    var methodStats: [HybridMethod: MethodStat] = [:]

    nonisolated struct MethodStat: Sendable {
        var attempts: Int = 0
        var successes: Int = 0
        var failures: Int = 0
        var avgLatencyMs: Int = 0
        var lastUsed: Date?

        var successRate: Double {
            guard attempts > 0 else { return 0.5 }
            return Double(successes) / Double(attempts)
        }
    }

    init() {
        loadHealthScores()
    }

    func nextHybridConfig(for target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        let methods = availableMethodsRankedByAI(for: target)
        guard !methods.isEmpty else {
            logger.log("Hybrid: no methods available — falling back to direct", category: .network, level: .warning)
            return .direct
        }

        let method = methods[sessionIndex % methods.count]
        sessionIndex += 1

        let config = resolveConfig(for: method, target: target)
        let assignment = HybridSessionAssignment(method: method, config: config, label: method.rawValue)
        lastAssignments.append(assignment)
        if lastAssignments.count > 50 { lastAssignments.removeFirst(lastAssignments.count - 50) }

        logger.log("Hybrid: session \(sessionIndex) → \(method.rawValue) (\(config.label)) for \(target.rawValue)", category: .network, level: .info)
        return config
    }

    func assignConfigsForBatch(count: Int, target: ProxyRotationService.ProxyTarget) -> [ActiveNetworkConfig] {
        isActive = true
        lastAssignments.removeAll()
        sessionIndex = 0

        let methods = availableMethodsRankedByAI(for: target)
        guard !methods.isEmpty else {
            return Array(repeating: ActiveNetworkConfig.direct, count: count)
        }

        var configs: [ActiveNetworkConfig] = []
        for i in 0..<count {
            let method = methods[i % methods.count]
            let config = resolveConfig(for: method, target: target)
            configs.append(config)
            let assignment = HybridSessionAssignment(method: method, config: config, label: method.rawValue)
            lastAssignments.append(assignment)
        }

        let distribution = Dictionary(grouping: lastAssignments, by: \.method).mapValues(\.count)
        let distLabel = distribution.sorted(by: { $0.key.priority < $1.key.priority }).map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " ")
        logger.log("Hybrid: assigned \(count) sessions across \(methods.count) methods — \(distLabel)", category: .network, level: .success)

        return configs
    }

    func recordOutcome(method: HybridMethod, success: Bool, latencyMs: Int) {
        var stat = methodStats[method] ?? MethodStat()
        stat.attempts += 1
        if success { stat.successes += 1 } else { stat.failures += 1 }
        let prevTotal = stat.avgLatencyMs * (stat.attempts - 1)
        stat.avgLatencyMs = (prevTotal + latencyMs) / stat.attempts
        stat.lastUsed = Date()
        methodStats[method] = stat

        let score = calculateHealthScore(for: stat)
        methodHealthScores[method] = score
        persistHealthScores()

        if stat.failures >= 3 && stat.successRate < 0.2 {
            logger.log("Hybrid: \(method.rawValue) degraded — SR:\(Int(stat.successRate * 100))% after \(stat.attempts) attempts, AI deprioritizing", category: .network, level: .warning)
        }
    }

    func resetBatch() {
        isActive = false
        lastAssignments.removeAll()
        sessionIndex = 0
    }

    var hybridSummary: String {
        let methods = HybridMethod.allCases.filter { methodHealthScores[$0] != nil }
        if methods.isEmpty { return "No data" }
        return methods.sorted(by: { $0.priority < $1.priority }).map { m in
            let score = Int((methodHealthScores[m] ?? 0.5) * 100)
            return "\(m.rawValue):\(score)%"
        }.joined(separator: " | ")
    }

    private func availableMethodsRankedByAI(for target: ProxyRotationService.ProxyTarget) -> [HybridMethod] {
        var available: [HybridMethod] = []

        let wgConfigs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
        if !wgConfigs.isEmpty { available.append(.wireProxy) }

        if NodeMavenService.shared.isEnabled { available.append(.nodeMaven) }

        let ovpnConfigs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
        if !ovpnConfigs.isEmpty { available.append(.openVPN) }

        let socks5 = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
        if !socks5.isEmpty { available.append(.socks5) }

        available.append(.httpsDOH)

        let ranked = available.sorted { a, b in
            let scoreA = methodHealthScores[a] ?? 0.5
            let scoreB = methodHealthScores[b] ?? 0.5
            if abs(scoreA - scoreB) < 0.05 {
                return a.priority < b.priority
            }
            return scoreA > scoreB
        }

        logger.log("Hybrid: \(ranked.count) methods available — \(ranked.map(\.rawValue).joined(separator: ", "))", category: .network, level: .debug)
        return ranked
    }

    private func resolveConfig(for method: HybridMethod, target: ProxyRotationService.ProxyTarget) -> ActiveNetworkConfig {
        switch method {
        case .wireProxy:
            let wireProxyBridge = WireProxyBridge.shared
            let localProxy = LocalProxyServer.shared
            if wireProxyBridge.isActive, localProxy.isRunning, localProxy.wireProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            let configs = proxyService.wgConfigs(for: target).filter { $0.isEnabled }
            if let wg = configs.randomElement() {
                return .wireGuardDNS(wg)
            }
            return .direct

        case .nodeMaven:
            if let proxy = NodeMavenService.shared.generateProxyConfig(sessionId: "hybrid_\(Int(Date().timeIntervalSince1970))_\(sessionIndex)") {
                return .socks5(proxy)
            }
            return .direct

        case .openVPN:
            let ovpnBridge = OpenVPNProxyBridge.shared
            let localProxy = LocalProxyServer.shared
            if ovpnBridge.isActive, localProxy.isRunning, localProxy.openVPNProxyMode {
                return .socks5(localProxy.localProxyConfig)
            }
            if ovpnBridge.isActive, let bridgeProxy = ovpnBridge.activeSOCKS5Proxy {
                return .socks5(bridgeProxy)
            }
            let configs = proxyService.vpnConfigs(for: target).filter { $0.isEnabled }
            if let ovpn = configs.randomElement() {
                return .openVPNProxy(ovpn)
            }
            return .direct

        case .socks5:
            let proxies = proxyService.proxies(for: target).filter { $0.isWorking || $0.lastTested == nil }
            let host = hostForTarget(target)
            if let aiPick = aiStrategy.bestProxy(for: host, from: proxies, target: target) {
                return .socks5(aiPick)
            }
            if let proxy = proxies.randomElement() {
                return .socks5(proxy)
            }
            return .direct

        case .httpsDOH:
            return .direct
        }
    }

    private func hostForTarget(_ target: ProxyRotationService.ProxyTarget) -> String {
        switch target {
        case .joe: "joefortune24.com"
        case .ignition: "ignitioncasino.eu"
        case .ppsr: "ppsr.com.au"
        }
    }

    private func calculateHealthScore(for stat: MethodStat) -> Double {
        let srScore = stat.successRate * 0.50
        let latScore = max(0, 1.0 - (Double(stat.avgLatencyMs) / 15000.0)) * 0.25
        var recency = 0.3
        if let last = stat.lastUsed {
            let ago = Date().timeIntervalSince(last)
            recency = max(0, 1.0 - (ago / 3600.0))
        }
        let recencyScore = recency * 0.15
        let volumePenalty = stat.attempts < 3 ? 0.05 : 0.10
        return srScore + latScore + recencyScore + volumePenalty
    }

    private func persistHealthScores() {
        var dict: [String: Double] = [:]
        for (method, score) in methodHealthScores {
            dict[method.rawValue] = score
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: persistKey)
        }
    }

    private func loadHealthScores() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        for (key, score) in dict {
            if let method = HybridMethod(rawValue: key) {
                methodHealthScores[method] = score
            }
        }
    }
}
