import Foundation
import Network
import Observation

nonisolated struct WGEndpointTestResult: Sendable {
    let config: String
    let reachable: Bool
    let latencyMs: Int
    let protocol_: String
    let port: Int
}

@Observable
@MainActor
class WireGuardTunnelService {
    static let shared = WireGuardTunnelService()

    private let vpnTunnel = VPNTunnelManager.shared
    private let logger = DebugLogger.shared

    private(set) var isTestingEndpoints: Bool = false
    private(set) var endpointResults: [WGEndpointTestResult] = []
    private(set) var lastBatchTestDate: Date?

    func testAllEndpoints(_ configs: [WireGuardConfig]) async {
        isTestingEndpoints = true
        endpointResults.removeAll()

        for config in configs where config.isEnabled {
            let result = await vpnTunnel.testEndpointReachability(config)
            let testResult = WGEndpointTestResult(
                config: config.fileName,
                reachable: result.reachable,
                latencyMs: result.latencyMs,
                protocol_: "UDP",
                port: config.endpointPort
            )
            endpointResults.append(testResult)
            logger.log("WGTunnel: \(config.fileName) - \(result.reachable ? "OK" : "FAIL") (\(result.latencyMs)ms)", category: .vpn, level: result.reachable ? .success : .warning)
        }

        lastBatchTestDate = Date()
        isTestingEndpoints = false
    }

    func connectBestEndpoint(_ configs: [WireGuardConfig]) async {
        let enabled = configs.filter { $0.isEnabled }
        guard !enabled.isEmpty else {
            logger.log("WGTunnel: no enabled configs for best endpoint selection", category: .vpn, level: .warning)
            return
        }

        var bestConfig: WireGuardConfig?
        var bestLatency: Int = Int.max

        for config in enabled {
            let result = await vpnTunnel.testEndpointReachability(config)
            if result.reachable && result.latencyMs < bestLatency {
                bestLatency = result.latencyMs
                bestConfig = config
            }
        }

        if let best = bestConfig {
            logger.log("WGTunnel: best endpoint is \(best.fileName) (\(bestLatency)ms)", category: .vpn, level: .info)
            await vpnTunnel.configureAndConnect(with: best)
        } else {
            logger.log("WGTunnel: no reachable endpoints found", category: .vpn, level: .error)
        }
    }

    func validateConfig(_ config: WireGuardConfig) -> [String] {
        var issues: [String] = []

        if config.interfacePrivateKey.isEmpty {
            issues.append("Missing interface private key")
        }
        if config.peerPublicKey.isEmpty {
            issues.append("Missing peer public key")
        }
        if config.peerEndpoint.isEmpty {
            issues.append("Missing peer endpoint")
        }
        if config.interfaceAddress.isEmpty {
            issues.append("Missing interface address")
        }

        let keyLength = config.interfacePrivateKey.count
        if keyLength != 44 && !config.interfacePrivateKey.isEmpty {
            issues.append("Private key appears invalid (expected 44 chars base64, got \(keyLength))")
        }

        let pubKeyLength = config.peerPublicKey.count
        if pubKeyLength != 44 && !config.peerPublicKey.isEmpty {
            issues.append("Public key appears invalid (expected 44 chars base64, got \(pubKeyLength))")
        }

        if config.endpointPort < 1 || config.endpointPort > 65535 {
            issues.append("Invalid endpoint port: \(config.endpointPort)")
        }

        if let mtu = config.interfaceMTU, (mtu < 576 || mtu > 65535) {
            issues.append("Invalid MTU: \(mtu) (valid range: 576-65535)")
        }

        return issues
    }

    func generateWGQuickConfig(_ config: WireGuardConfig) -> String {
        var lines: [String] = []
        lines.append("[Interface]")
        lines.append("PrivateKey = \(config.interfacePrivateKey)")
        lines.append("Address = \(config.interfaceAddress)")
        if !config.interfaceDNS.isEmpty {
            lines.append("DNS = \(config.interfaceDNS)")
        }
        if let mtu = config.interfaceMTU {
            lines.append("MTU = \(mtu)")
        }
        lines.append("")
        lines.append("[Peer]")
        lines.append("PublicKey = \(config.peerPublicKey)")
        if let psk = config.peerPreSharedKey, !psk.isEmpty {
            lines.append("PresharedKey = \(psk)")
        }
        lines.append("Endpoint = \(config.peerEndpoint)")
        lines.append("AllowedIPs = \(config.peerAllowedIPs)")
        if let keepalive = config.peerPersistentKeepalive, keepalive > 0 {
            lines.append("PersistentKeepalive = \(keepalive)")
        }
        return lines.joined(separator: "\n")
    }

    var reachableCount: Int {
        endpointResults.filter { $0.reachable }.count
    }

    var averageLatency: Int? {
        let reachable = endpointResults.filter { $0.reachable }
        guard !reachable.isEmpty else { return nil }
        return reachable.map { $0.latencyMs }.reduce(0, +) / reachable.count
    }

    var bestEndpoint: WGEndpointTestResult? {
        endpointResults.filter { $0.reachable }.min { $0.latencyMs < $1.latencyMs }
    }
}
