import Foundation
import Network
import Observation

nonisolated enum WireProxyStatus: String, Sendable {
    case stopped = "Stopped"
    case connecting = "Connecting"
    case established = "Established"
    case reconnecting = "Reconnecting"
    case failed = "Failed"
}

nonisolated struct WireProxyStats: Sendable {
    var tcpSessionsCreated: Int = 0
    var tcpSessionsActive: Int = 0
    var dnsQueriesTotal: Int = 0
    var dnsCacheHits: Int = 0
    var bytesUpstream: UInt64 = 0
    var bytesDownstream: UInt64 = 0
    var connectionsServed: Int = 0
    var connectionsFailed: Int = 0
}

@Observable
@MainActor
class WireProxyBridge {
    static let shared = WireProxyBridge()

    private(set) var status: WireProxyStatus = .stopped
    private(set) var stats: WireProxyStats = WireProxyStats()
    private(set) var lastError: String?
    private(set) var connectedSince: Date?

    private let wgSession = WireGuardSession()
    private let tcpManager = TCPSessionManager()
    private let dnsResolver = TunnelDNSResolver()
    private let logger = DebugLogger.shared

    private var activeConfig: WireGuardConfig?
    private var localIP: UInt32 = 0
    private var tunnelConnections: [UUID: WireProxyTunnelConnection] = [:]
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3

    var isActive: Bool { status == .established }

    func start(with config: WireGuardConfig) async {
        guard status == .stopped || status == .failed else { return }

        activeConfig = config
        status = .connecting
        lastError = nil
        reconnectAttempts = 0

        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else {
            status = .failed
            lastError = "Invalid interface address: \(config.interfaceAddress)"
            return
        }
        localIP = ip

        tcpManager.configure(localIP: localIP)
        tcpManager.sendPacketHandler = { [weak self] packet in
            self?.wgSession.sendPacket(packet)
        }

        let dnsServer = config.interfaceDNS.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "1.1.1.1"
        dnsResolver.configure(dnsServer: dnsServer, sourceIP: localIP)
        dnsResolver.sendPacketHandler = { [weak self] packet in
            self?.wgSession.sendPacket(packet)
        }

        wgSession.onPacketReceived = { [weak self] ipData in
            self?.handleTunnelPacket(ipData)
        }

        let configured = wgSession.configure(
            privateKey: config.interfacePrivateKey,
            peerPublicKey: config.peerPublicKey,
            preSharedKey: config.peerPreSharedKey,
            endpoint: config.peerEndpoint,
            keepalive: config.peerPersistentKeepalive ?? 25
        )

        guard configured else {
            status = .failed
            lastError = wgSession.lastError ?? "Configuration failed"
            logger.log("WireProxyBridge: configuration failed - \(lastError ?? "")", category: .vpn, level: .error)
            return
        }

        await wgSession.connect()

        try? await Task.sleep(for: .seconds(3))

        if wgSession.isEstablished {
            status = .established
            connectedSince = Date()
            logger.log("WireProxyBridge: tunnel ESTABLISHED via \(config.peerEndpoint)", category: .vpn, level: .success)

            let dnsOK = await dnsResolver.verifyDNS()
            if !dnsOK {
                logger.log("WireProxyBridge: DNS verification failed — tunnel up but DNS not resolving, will retry", category: .vpn, level: .warning)
                try? await Task.sleep(for: .seconds(2))
                let retryOK = await dnsResolver.verifyDNS()
                if !retryOK {
                    logger.log("WireProxyBridge: DNS still failing after retry — tunnel may have limited connectivity", category: .vpn, level: .error)
                }
            }
        } else {
            status = .failed
            lastError = wgSession.lastError ?? "Handshake timeout"
            logger.log("WireProxyBridge: tunnel failed - \(lastError ?? "")", category: .vpn, level: .error)
        }
    }

    func stop() {
        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()

        tcpManager.shutdown()
        dnsResolver.clearCache()
        wgSession.disconnect()

        status = .stopped
        connectedSince = nil
        activeConfig = nil
        stats = WireProxyStats()
        logger.log("WireProxyBridge: stopped", category: .vpn, level: .info)
    }

    func handleSOCKS5Connection(
        id: UUID,
        clientConnection: NWConnection,
        targetHost: String,
        targetPort: UInt16,
        queue: DispatchQueue,
        server: LocalProxyServer
    ) {
        guard status == .established else {
            logger.log("WireProxyBridge: rejecting connection - tunnel not established", category: .vpn, level: .warning)
            return
        }

        stats.connectionsServed += 1

        let tunnelConn = WireProxyTunnelConnection(
            id: id,
            clientConnection: clientConnection,
            targetHost: targetHost,
            targetPort: targetPort,
            queue: queue,
            server: server,
            bridge: self
        )

        tunnelConnections[id] = tunnelConn
        tunnelConn.start()
    }

    func createTCPSession(destinationIP: UInt32, destinationPort: UInt16) -> TCPSession {
        stats.tcpSessionsCreated += 1
        stats.tcpSessionsActive = tcpManager.activeSessionCount + 1
        return tcpManager.createSession(destinationIP: destinationIP, destinationPort: destinationPort)
    }

    func initiateConnection(_ session: TCPSession) {
        tcpManager.initiateConnection(session)
    }

    func sendData(_ session: TCPSession, data: Data) {
        stats.bytesUpstream += UInt64(data.count)
        tcpManager.sendData(session, data: data)
    }

    func closeSession(_ session: TCPSession) {
        tcpManager.closeSession(session)
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    func resetSession(_ session: TCPSession) {
        tcpManager.sendReset(session)
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    func resolveHostname(_ hostname: String) async -> UInt32? {
        stats.dnsQueriesTotal += 1
        return await dnsResolver.resolve(hostname)
    }

    func connectionFinished(id: UUID, hadError: Bool) {
        tunnelConnections.removeValue(forKey: id)
        if hadError {
            stats.connectionsFailed += 1
        }
        stats.tcpSessionsActive = tcpManager.activeSessionCount
    }

    private func handleTunnelPacket(_ ipData: Data) {
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }

        if ipPacket.header.isUDP {
            dnsResolver.handleIncomingPacket(ipData)
            return
        }

        if ipPacket.header.isTCP {
            stats.bytesDownstream += UInt64(ipData.count)
            tcpManager.handleIncomingPacket(ipData)
            return
        }
    }

    var wgSessionStatus: WGSessionStatus { wgSession.status }
    var wgSessionStats: WGSessionStats { wgSession.stats }
    var dnsCacheSize: Int { dnsResolver.cacheSize }

    var uptimeString: String {
        guard let since = connectedSince else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(since))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }
}
