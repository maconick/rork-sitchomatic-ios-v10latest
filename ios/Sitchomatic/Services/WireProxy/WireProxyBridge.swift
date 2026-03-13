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

struct WireProxyTunnelSlot {
    let index: Int
    let config: WireGuardConfig
    let wgSession: WireGuardSession
    let tcpManager: TCPSessionManager
    let dnsResolver: TunnelDNSResolver
    var localIP: UInt32 = 0
    var isEstablished: Bool = false
    var serverName: String { config.serverName }
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
    private let maxReconnectAttempts: Int = 5
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 12
    private var pendingReconnectHosts: [(host: String, port: UInt16)] = []
    private var isReconnecting: Bool = false

    private(set) var tunnelSlots: [WireProxyTunnelSlot] = []
    private var nextSlotIndex: Int = 0
    private(set) var multiTunnelMode: Bool = false
    var activeTunnelCount: Int { tunnelSlots.filter(\.isEstablished).count }

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
            reconnectAttempts = 0
            dnsResolver.startBackgroundRefresh()
            logger.log("WireProxyBridge: tunnel ESTABLISHED via \(config.peerEndpoint)", category: .vpn, level: .success)

            let dnsOK = await dnsResolver.verifyDNS()
            if !dnsOK {
                logger.log("WireProxyBridge: DNS verification failed — retrying with backoff", category: .vpn, level: .warning)
                for dnsRetry in 1...3 {
                    try? await Task.sleep(for: .seconds(Double(dnsRetry) * 1.5))
                    let retryOK = await dnsResolver.verifyDNS()
                    if retryOK {
                        logger.log("WireProxyBridge: DNS resolved on retry \(dnsRetry)", category: .vpn, level: .success)
                        break
                    }
                    if dnsRetry == 3 {
                        logger.log("WireProxyBridge: DNS still failing after 3 retries — tunnel may have limited connectivity", category: .vpn, level: .error)
                    }
                }
            }

            startHealthCheck()
        } else {
            logger.log("WireProxyBridge: initial handshake failed — retrying with extended wait", category: .vpn, level: .warning)
            try? await Task.sleep(for: .seconds(3))
            if wgSession.isEstablished {
                status = .established
                connectedSince = Date()
                reconnectAttempts = 0
                dnsResolver.startBackgroundRefresh()
                logger.log("WireProxyBridge: tunnel ESTABLISHED on extended wait via \(config.peerEndpoint)", category: .vpn, level: .success)
                startHealthCheck()
            } else {
                status = .failed
                lastError = wgSession.lastError ?? "Handshake timeout"
                logger.log("WireProxyBridge: tunnel failed - \(lastError ?? "")", category: .vpn, level: .error)
            }
        }
    }

    func stop() {
        stopHealthCheck()
        dnsResolver.stopBackgroundRefresh()

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        pendingReconnectHosts.removeAll()

        tcpManager.shutdown()
        dnsResolver.clearCache()
        wgSession.disconnect()

        for slot in tunnelSlots {
            slot.dnsResolver.stopBackgroundRefresh()
            slot.tcpManager.shutdown()
            slot.dnsResolver.clearCache()
            slot.wgSession.disconnect()
        }
        tunnelSlots.removeAll()
        nextSlotIndex = 0
        multiTunnelMode = false

        status = .stopped
        connectedSince = nil
        activeConfig = nil
        isReconnecting = false
        stats = WireProxyStats()
        logger.log("WireProxyBridge: stopped", category: .vpn, level: .info)
    }

    func reconnectPreservingSessions() async {
        guard let config = activeConfig, !isReconnecting else { return }
        isReconnecting = true
        status = .reconnecting

        pendingReconnectHosts = tunnelConnections.values.map { ($0.targetHost, $0.targetPort) }
        let preservedStats = stats

        logger.log("WireProxyBridge: reconnecting — preserving \(pendingReconnectHosts.count) session targets", category: .vpn, level: .warning)

        for conn in tunnelConnections.values {
            conn.cancel()
        }
        tunnelConnections.removeAll()
        tcpManager.shutdown()
        wgSession.disconnect()

        let backoffDelay = min(Double(reconnectAttempts + 1) * 1.5, 8.0)
        try? await Task.sleep(for: .seconds(backoffDelay))

        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else {
            status = .failed
            lastError = "Invalid interface address on reconnect"
            isReconnecting = false
            return
        }
        localIP = ip

        tcpManager.configure(localIP: localIP)
        tcpManager.sendPacketHandler = { [weak self] packet in
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
            lastError = "Reconnect configuration failed"
            isReconnecting = false
            return
        }

        await wgSession.connect()
        try? await Task.sleep(for: .seconds(3))

        if !wgSession.isEstablished {
            try? await Task.sleep(for: .seconds(3))
        }

        if wgSession.isEstablished {
            status = .established
            stats = preservedStats
            reconnectAttempts = 0
            dnsResolver.startBackgroundRefresh()
            startHealthCheck()

            logger.log("WireProxyBridge: reconnect SUCCEEDED — tunnel re-established, \(pendingReconnectHosts.count) sessions were active", category: .vpn, level: .success)
            pendingReconnectHosts.removeAll()
        } else {
            reconnectAttempts += 1
            if reconnectAttempts < maxReconnectAttempts {
                logger.log("WireProxyBridge: reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) failed, retrying with \(String(format: "%.1f", min(Double(reconnectAttempts + 1) * 1.5, 8.0)))s backoff...", category: .vpn, level: .warning)
                isReconnecting = false
                await reconnectPreservingSessions()
                return
            }
            status = .failed
            lastError = "Reconnect failed after \(maxReconnectAttempts) attempts"
            logger.log("WireProxyBridge: reconnect FAILED after \(maxReconnectAttempts) attempts", category: .vpn, level: .error)
        }

        isReconnecting = false
    }

    private func startHealthCheck() {
        stopHealthCheck()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkTunnelHealth()
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func checkTunnelHealth() {
        guard status == .established else { return }

        if multiTunnelMode {
            var anyDown = false
            for (i, slot) in tunnelSlots.enumerated() where slot.isEstablished {
                if !slot.wgSession.isEstablished {
                    logger.log("WireProxyBridge: health check — slot \(i) (\(slot.serverName)) DOWN — attempting slot reconnect", category: .vpn, level: .error)
                    tunnelSlots[i].isEstablished = false
                    anyDown = true
                    Task {
                        await self.reconnectSlot(i)
                    }
                }
            }
            let activeCount = tunnelSlots.filter(\.isEstablished).count
            if activeCount == 0 {
                logger.log("WireProxyBridge: all multi-tunnel slots DOWN — initiating full reconnect", category: .vpn, level: .error)
                Task { await reconnectPreservingSessions() }
            } else if anyDown {
                logger.log("WireProxyBridge: \(activeCount)/\(tunnelSlots.count) slots still active", category: .vpn, level: .warning)
            }
            return
        }

        if !wgSession.isEstablished {
            logger.log("WireProxyBridge: health check detected tunnel DOWN — initiating reconnect", category: .vpn, level: .error)
            Task {
                await reconnectPreservingSessions()
            }
        }
    }

    private func reconnectSlot(_ index: Int) async {
        guard index < tunnelSlots.count else { return }
        let slot = tunnelSlots[index]
        let config = slot.config

        slot.wgSession.disconnect()
        slot.tcpManager.shutdown()
        try? await Task.sleep(for: .seconds(2))

        let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
        guard let ip = IPv4Packet.ipFromString(address) else { return }

        slot.tcpManager.configure(localIP: ip)
        let slotSession = slot.wgSession
        slot.tcpManager.sendPacketHandler = { packet in
            slotSession.sendPacket(packet)
        }
        slot.wgSession.onPacketReceived = { [weak self, index] ipData in
            self?.handleMultiTunnelPacket(ipData, slotIndex: index)
        }

        let configured = slot.wgSession.configure(
            privateKey: config.interfacePrivateKey,
            peerPublicKey: config.peerPublicKey,
            preSharedKey: config.peerPreSharedKey,
            endpoint: config.peerEndpoint,
            keepalive: config.peerPersistentKeepalive ?? 25
        )
        guard configured else {
            logger.log("WireProxyBridge: slot \(index) reconnect config failed", category: .vpn, level: .error)
            return
        }

        await slot.wgSession.connect()
        try? await Task.sleep(for: .seconds(3))

        if slot.wgSession.isEstablished {
            tunnelSlots[index].isEstablished = true
            slot.dnsResolver.startBackgroundRefresh()
            logger.log("WireProxyBridge: slot \(index) (\(config.serverName)) RECONNECTED", category: .vpn, level: .success)
        } else {
            logger.log("WireProxyBridge: slot \(index) (\(config.serverName)) reconnect FAILED", category: .vpn, level: .error)
        }
    }

    func startMultiple(configs: [WireGuardConfig]) async {
        guard status == .stopped || status == .failed else { return }
        guard configs.count > 1 else {
            if let first = configs.first {
                await start(with: first)
            }
            return
        }

        status = .connecting
        lastError = nil
        reconnectAttempts = 0
        multiTunnelMode = true
        tunnelSlots.removeAll()
        nextSlotIndex = 0

        logger.log("WireProxyBridge: starting multi-tunnel with \(configs.count) WG configs", category: .vpn, level: .info)

        for (i, config) in configs.enumerated() {
            let session = WireGuardSession()
            let tcp = TCPSessionManager()
            let dns = TunnelDNSResolver()

            let address = config.interfaceAddress.split(separator: "/").first.map(String.init) ?? config.interfaceAddress
            guard let ip = IPv4Packet.ipFromString(address) else {
                logger.log("WireProxyBridge: slot \(i) invalid address: \(config.interfaceAddress)", category: .vpn, level: .error)
                continue
            }

            tcp.configure(localIP: ip)
            tcp.sendPacketHandler = { [weak session] packet in
                session?.sendPacket(packet)
            }

            let dnsServer = config.interfaceDNS.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "1.1.1.1"
            dns.configure(dnsServer: dnsServer, sourceIP: ip)
            dns.sendPacketHandler = { [weak session] packet in
                session?.sendPacket(packet)
            }

            session.onPacketReceived = { [weak self, i] ipData in
                self?.handleMultiTunnelPacket(ipData, slotIndex: i)
            }

            let configured = session.configure(
                privateKey: config.interfacePrivateKey,
                peerPublicKey: config.peerPublicKey,
                preSharedKey: config.peerPreSharedKey,
                endpoint: config.peerEndpoint,
                keepalive: config.peerPersistentKeepalive ?? 25
            )

            guard configured else {
                logger.log("WireProxyBridge: slot \(i) config failed for \(config.serverName)", category: .vpn, level: .error)
                continue
            }

            var slot = WireProxyTunnelSlot(
                index: i,
                config: config,
                wgSession: session,
                tcpManager: tcp,
                dnsResolver: dns,
                localIP: ip
            )

            await session.connect()
            try? await Task.sleep(for: .seconds(3))

            if session.isEstablished {
                slot.isEstablished = true
                dns.startBackgroundRefresh()
                logger.log("WireProxyBridge: slot \(i) ESTABLISHED → \(config.peerEndpoint) (\(config.serverName))", category: .vpn, level: .success)
            } else {
                logger.log("WireProxyBridge: slot \(i) FAILED for \(config.serverName) — \(session.lastError ?? "timeout")", category: .vpn, level: .error)
            }

            tunnelSlots.append(slot)
        }

        let established = tunnelSlots.filter(\.isEstablished).count
        if established > 0 {
            status = .established
            connectedSince = Date()
            startHealthCheck()
            logger.log("WireProxyBridge: multi-tunnel ready — \(established)/\(configs.count) tunnels active", category: .vpn, level: .success)
        } else {
            status = .failed
            lastError = "All \(configs.count) tunnel slots failed to establish"
            logger.log("WireProxyBridge: multi-tunnel FAILED — 0/\(configs.count) established", category: .vpn, level: .error)
        }
    }

    func nextTunnelSlot() -> WireProxyTunnelSlot? {
        let established = tunnelSlots.filter(\.isEstablished)
        guard !established.isEmpty else { return nil }
        let slot = established[nextSlotIndex % established.count]
        nextSlotIndex += 1
        return slot
    }

    private func handleMultiTunnelPacket(_ ipData: Data, slotIndex: Int) {
        guard slotIndex < tunnelSlots.count else { return }
        guard let ipPacket = IPv4Packet.parse(ipData) else { return }

        let slot = tunnelSlots[slotIndex]
        if ipPacket.header.isUDP {
            slot.dnsResolver.handleIncomingPacket(ipData)
            return
        }
        if ipPacket.header.isTCP {
            stats.bytesDownstream += UInt64(ipData.count)
            slot.tcpManager.handleIncomingPacket(ipData)
            return
        }
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

        if multiTunnelMode, let slot = nextTunnelSlot() {
            let tunnelConn = WireProxyMultiTunnelConnection(
                id: id,
                clientConnection: clientConnection,
                targetHost: targetHost,
                targetPort: targetPort,
                queue: queue,
                server: server,
                bridge: self,
                slot: slot
            )
            tunnelConnections[id] = tunnelConn
            tunnelConn.start()
            logger.log("WireProxyBridge: routed \(targetHost) → slot \(slot.index) (\(slot.serverName))", category: .vpn, level: .debug)
            return
        }

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

    func createMultiTunnelTCPSession(slot: WireProxyTunnelSlot, destinationIP: UInt32, destinationPort: UInt16) -> TCPSession {
        stats.tcpSessionsCreated += 1
        stats.tcpSessionsActive += 1
        return slot.tcpManager.createSession(destinationIP: destinationIP, destinationPort: destinationPort)
    }

    func initiateMultiTunnelConnection(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.initiateConnection(session)
    }

    func sendMultiTunnelData(_ session: TCPSession, data: Data, slot: WireProxyTunnelSlot) {
        stats.bytesUpstream += UInt64(data.count)
        slot.tcpManager.sendData(session, data: data)
    }

    func closeMultiTunnelSession(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.closeSession(session)
        stats.tcpSessionsActive = max(0, stats.tcpSessionsActive - 1)
    }

    func resetMultiTunnelSession(_ session: TCPSession, slot: WireProxyTunnelSlot) {
        slot.tcpManager.sendReset(session)
        stats.tcpSessionsActive = max(0, stats.tcpSessionsActive - 1)
    }

    func resolveMultiTunnelHostname(_ hostname: String, slot: WireProxyTunnelSlot) async -> UInt32? {
        stats.dnsQueriesTotal += 1
        return await slot.dnsResolver.resolve(hostname)
    }

    var wgSessionStatus: WGSessionStatus { wgSession.status }
    var wgSessionStats: WGSessionStats { wgSession.stats }
    var dnsCacheSize: Int { dnsResolver.cacheSize }
    var reconnectCount: Int { reconnectAttempts }

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
