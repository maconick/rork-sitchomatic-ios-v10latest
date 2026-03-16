import Foundation
import Network
import Observation

nonisolated enum OpenVPNBridgeStatus: String, Sendable {
    case stopped = "Stopped"
    case connecting = "Connecting"
    case established = "Established"
    case reconnecting = "Reconnecting"
    case failed = "Failed"
}

nonisolated struct OpenVPNBridgeStats: Sendable {
    var connectionsServed: Int = 0
    var connectionsFailed: Int = 0
    var bytesUpstream: UInt64 = 0
    var bytesDownstream: UInt64 = 0
    var handshakeLatencyMs: Int = 0
    var lastValidatedAt: Date?
    var consecutiveFailures: Int = 0
    var resolutionSource: String = ""
}

nonisolated struct SOCKS5RegionCacheEntry: Sendable {
    let proxy: ProxyConfig
    let resolvedAt: Date
    let source: String
}

@Observable
@MainActor
class OpenVPNProxyBridge {
    static let shared = OpenVPNProxyBridge()

    private(set) var status: OpenVPNBridgeStatus = .stopped
    private(set) var stats: OpenVPNBridgeStats = OpenVPNBridgeStats()
    private(set) var lastError: String?
    private(set) var connectedSince: Date?
    private(set) var activeConfig: OpenVPNConfig?
    private(set) var activeSOCKS5Proxy: ProxyConfig?

    private let logger = DebugLogger.shared
    private var healthCheckTimer: Timer?
    private let healthCheckInterval: TimeInterval = 15
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 5
    private var isReconnecting: Bool = false

    private let socks5Port: Int = 1080
    private let regionCacheTTL: TimeInterval = 300
    private var regionCache: [String: SOCKS5RegionCacheEntry] = [:]

    var isActive: Bool { status == .established }

    // MARK: - Start

    func start(with config: OpenVPNConfig) async {
        guard status == .stopped || status == .failed else { return }

        activeConfig = config
        status = .connecting
        lastError = nil
        reconnectAttempts = 0

        let startTime = CFAbsoluteTimeGetCurrent()

        if let resolved = await resolveSOCKS5Endpoint(for: config) {
            let latencyMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            activeSOCKS5Proxy = resolved.proxy
            status = .established
            connectedSince = Date()
            stats.handshakeLatencyMs = latencyMs
            stats.lastValidatedAt = Date()
            stats.consecutiveFailures = 0
            stats.resolutionSource = resolved.source
            startHealthCheck()
            logger.log("OpenVPNBridge: ESTABLISHED via \(resolved.source) → \(resolved.proxy.host):\(resolved.proxy.port) (\(latencyMs)ms)", category: .vpn, level: .success)
            return
        }

        status = .failed
        lastError = "All SOCKS5 resolution strategies exhausted for \(config.fileName)"
        logger.log("OpenVPNBridge: FAILED — \(lastError!)", category: .vpn, level: .error)
    }

    // MARK: - Stop

    func stop() {
        stopHealthCheck()
        status = .stopped
        connectedSince = nil
        activeConfig = nil
        activeSOCKS5Proxy = nil
        lastError = nil
        isReconnecting = false
        stats = OpenVPNBridgeStats()
        logger.log("OpenVPNBridge: stopped", category: .vpn, level: .info)
    }

    // MARK: - Reconnect

    func reconnectPreservingSessions() async {
        guard let config = activeConfig, !isReconnecting else { return }
        isReconnecting = true
        status = .reconnecting

        let preservedStats = stats
        logger.log("OpenVPNBridge: reconnecting with preserved stats", category: .vpn, level: .warning)

        stop()
        stats = preservedStats

        let jitter = Double.random(in: 0...1.0)
        let backoffDelay = min(Double(reconnectAttempts + 1) * 1.5 + jitter, 10.0)
        try? await Task.sleep(for: .seconds(backoffDelay))

        reconnectAttempts += 1
        isReconnecting = false

        if let regionKey = config.nordCountryCode {
            regionCache.removeValue(forKey: regionKey)
        }

        await start(with: config)

        if status != .established && reconnectAttempts < maxReconnectAttempts {
            await reconnectPreservingSessions()
        }
    }

    // MARK: - Stats Recording

    func recordConnectionServed() {
        stats.connectionsServed += 1
    }

    func recordConnectionFailed() {
        stats.connectionsFailed += 1
        stats.consecutiveFailures += 1
    }

    func recordBytes(up: UInt64, down: UInt64) {
        stats.bytesUpstream += up
        stats.bytesDownstream += down
    }

    // MARK: - Endpoint Resolution

    private func resolveSOCKS5Endpoint(for config: OpenVPNConfig) async -> (proxy: ProxyConfig, source: String)? {
        let nordService = NordVPNService.shared
        let username = nordService.serviceUsername
        let password = nordService.servicePassword
        let authUser: String? = username.isEmpty ? nil : username
        let authPass: String? = password.isEmpty ? nil : password

        if let regionKey = config.nordCountryCode, let cached = regionCache[regionKey] {
            if Date().timeIntervalSince(cached.resolvedAt) < regionCacheTTL {
                let (alive, _) = await validateSOCKS5Endpoint(cached.proxy)
                if alive {
                    logger.log("OpenVPNBridge: using cached \(cached.source) endpoint for region \(regionKey)", category: .vpn, level: .debug)
                    return (cached.proxy, "cached(\(cached.source))")
                }
                regionCache.removeValue(forKey: regionKey)
                logger.log("OpenVPNBridge: cached endpoint for \(regionKey) failed validation, re-resolving", category: .vpn, level: .warning)
            } else {
                regionCache.removeValue(forKey: regionKey)
            }
        }

        if let countryId = config.nordCountryId {
            let apiServers = await nordService.fetchSOCKS5Servers(countryId: countryId, limit: 3)
            for server in apiServers {
                let proxy = ProxyConfig(
                    host: server.hostname,
                    port: socks5Port,
                    username: authUser,
                    password: authPass
                )
                let (alive, validated) = await validateSOCKS5Endpoint(proxy)
                if alive && (validated || !nordService.hasServiceCredentials) {
                    cacheEndpoint(proxy: proxy, regionKey: config.nordCountryCode, source: "NordAPI(\(server.hostname))")
                    return (proxy, "NordAPI(\(server.hostname))")
                }

                let stationProxy = ProxyConfig(
                    host: server.station,
                    port: socks5Port,
                    username: authUser,
                    password: authPass
                )
                let (stationAlive, stationValidated) = await validateSOCKS5Endpoint(stationProxy)
                if stationAlive && (stationValidated || !nordService.hasServiceCredentials) {
                    cacheEndpoint(proxy: stationProxy, regionKey: config.nordCountryCode, source: "NordAPI-station(\(server.station))")
                    return (stationProxy, "NordAPI-station(\(server.station))")
                }
            }
            if !apiServers.isEmpty {
                logger.log("OpenVPNBridge: all \(apiServers.count) API SOCKS5 servers unreachable for country \(countryId), trying hostname fallback", category: .vpn, level: .warning)
            }
        }

        let serverHost = config.remoteHost
        guard !serverHost.isEmpty else { return nil }

        let hostnameProxy = ProxyConfig(
            host: serverHost,
            port: socks5Port,
            username: authUser,
            password: authPass
        )
        let (hostAlive, hostValidated) = await validateSOCKS5Endpoint(hostnameProxy)
        if hostAlive && (hostValidated || !nordService.hasServiceCredentials) {
            cacheEndpoint(proxy: hostnameProxy, regionKey: config.nordCountryCode, source: "hostname(\(serverHost):1080)")
            return (hostnameProxy, "hostname(\(serverHost):1080)")
        }

        let stationIP = resolveStationIP(from: config)
        if !stationIP.isEmpty && stationIP != serverHost {
            let stationProxy = ProxyConfig(
                host: stationIP,
                port: socks5Port,
                username: authUser,
                password: authPass
            )
            let (stationAlive, stationValidated) = await validateSOCKS5Endpoint(stationProxy)
            if stationAlive && (stationValidated || !nordService.hasServiceCredentials) {
                cacheEndpoint(proxy: stationProxy, regionKey: config.nordCountryCode, source: "stationIP(\(stationIP):1080)")
                return (stationProxy, "stationIP(\(stationIP):1080)")
            }
        }

        if config.remotePort != socks5Port {
            let altProxy = ProxyConfig(
                host: serverHost,
                port: config.remotePort,
                username: authUser,
                password: authPass
            )
            let (altAlive, _) = await validateSOCKS5Endpoint(altProxy)
            if altAlive {
                cacheEndpoint(proxy: altProxy, regionKey: config.nordCountryCode, source: "altPort(\(serverHost):\(config.remotePort))")
                return (altProxy, "altPort(\(serverHost):\(config.remotePort))")
            }
        }

        return nil
    }

    private func cacheEndpoint(proxy: ProxyConfig, regionKey: String?, source: String) {
        guard let key = regionKey else { return }
        regionCache[key] = SOCKS5RegionCacheEntry(proxy: proxy, resolvedAt: Date(), source: source)
    }

    func invalidateRegionCache() {
        regionCache.removeAll()
        logger.log("OpenVPNBridge: region cache cleared", category: .vpn, level: .debug)
    }

    // MARK: - Health Check

    private func startHealthCheck() {
        stopHealthCheck()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performHealthCheck()
            }
        }
    }

    private func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func performHealthCheck() async {
        guard status == .established, let proxy = activeSOCKS5Proxy else { return }

        let (alive, _) = await validateSOCKS5Endpoint(proxy)
        if alive {
            stats.lastValidatedAt = Date()
            stats.consecutiveFailures = 0
        } else {
            stats.consecutiveFailures += 1
            logger.log("OpenVPNBridge: health check FAILED (consecutive: \(stats.consecutiveFailures))", category: .vpn, level: .warning)

            if stats.consecutiveFailures >= 3 {
                logger.log("OpenVPNBridge: 3+ failures — re-resolving endpoint", category: .vpn, level: .error)
                if let config = activeConfig, let regionKey = config.nordCountryCode {
                    regionCache.removeValue(forKey: regionKey)
                }
                await reconnectPreservingSessions()
            }
        }
    }

    // MARK: - SOCKS5 Validation

    nonisolated func validateSOCKS5Endpoint(_ proxy: ProxyConfig) async -> (alive: Bool, validated: Bool) {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
            )
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "ovpn-bridge-validate.\(UUID().uuidString.prefix(6))")
            var completed = false

            let timeoutWork = DispatchWorkItem { [weak connection] in
                guard !completed else { return }
                completed = true
                connection?.cancel()
                continuation.resume(returning: (false, false))
            }
            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWork)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var greeting: Data
                    if proxy.username != nil {
                        greeting = Data([0x05, 0x02, 0x00, 0x02])
                    } else {
                        greeting = Data([0x05, 0x01, 0x00])
                    }

                    connection.send(content: greeting, completion: .contentProcessed { sendError in
                        if sendError != nil {
                            guard !completed else { return }
                            completed = true
                            timeoutWork.cancel()
                            connection.cancel()
                            continuation.resume(returning: (true, false))
                            return
                        }

                        connection.receive(minimumIncompleteLength: 2, maximumLength: 16) { data, _, _, recvError in
                            guard !completed else { return }

                            if recvError != nil {
                                completed = true
                                timeoutWork.cancel()
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                                return
                            }

                            guard let data, data.count >= 2, data[0] == 0x05 else {
                                completed = true
                                timeoutWork.cancel()
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                                return
                            }

                            let authMethod = data[1]

                            if authMethod == 0x02, let username = proxy.username, let password = proxy.password {
                                var authPacket = Data([0x01])
                                let uBytes = Array(username.utf8)
                                authPacket.append(UInt8(uBytes.count))
                                authPacket.append(contentsOf: uBytes)
                                let pBytes = Array(password.utf8)
                                authPacket.append(UInt8(pBytes.count))
                                authPacket.append(contentsOf: pBytes)

                                connection.send(content: authPacket, completion: .contentProcessed { authSendError in
                                    if authSendError != nil {
                                        guard !completed else { return }
                                        completed = true
                                        timeoutWork.cancel()
                                        connection.cancel()
                                        continuation.resume(returning: (true, false))
                                        return
                                    }

                                    connection.receive(minimumIncompleteLength: 2, maximumLength: 4) { authData, _, _, authRecvError in
                                        guard !completed else { return }
                                        completed = true
                                        timeoutWork.cancel()
                                        connection.cancel()
                                        if authRecvError != nil {
                                            continuation.resume(returning: (true, false))
                                            return
                                        }
                                        guard let authData, authData.count >= 2 else {
                                            continuation.resume(returning: (true, false))
                                            return
                                        }
                                        let authSuccess = authData[1] == 0x00
                                        continuation.resume(returning: (true, authSuccess))
                                    }
                                })
                            } else if authMethod == 0x00 {
                                completed = true
                                timeoutWork.cancel()
                                connection.cancel()
                                continuation.resume(returning: (true, true))
                            } else if authMethod == 0xFF {
                                completed = true
                                timeoutWork.cancel()
                                connection.cancel()
                                continuation.resume(returning: (true, false))
                            } else {
                                completed = true
                                timeoutWork.cancel()
                                connection.cancel()
                                continuation.resume(returning: (true, true))
                            }
                        }
                    })

                case .failed:
                    guard !completed else { return }
                    completed = true
                    timeoutWork.cancel()
                    connection.cancel()
                    continuation.resume(returning: (false, false))

                case .cancelled:
                    guard !completed else { return }
                    completed = true
                    timeoutWork.cancel()
                    continuation.resume(returning: (false, false))

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Host Resolution Helpers

    private func resolveStationIP(from config: OpenVPNConfig) -> String {
        let lines = config.rawContent.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("remote ") {
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let addr = parts[1]
                    let isIP = addr.split(separator: ".").count == 4 && addr.allSatisfy { $0.isNumber || $0 == "." }
                    if isIP { return addr }
                }
            }
        }
        return ""
    }

    // MARK: - Display

    var uptimeString: String {
        guard let since = connectedSince else { return "--:--" }
        let elapsed = Int(Date().timeIntervalSince(since))
        let hrs = elapsed / 3600
        let mins = (elapsed % 3600) / 60
        let secs = elapsed % 60
        if hrs > 0 { return String(format: "%d:%02d:%02d", hrs, mins, secs) }
        return String(format: "%d:%02d", mins, secs)
    }

    var statusLabel: String {
        guard let proxy = activeSOCKS5Proxy else { return status.rawValue }
        return "\(status.rawValue) → \(proxy.host):\(proxy.port)"
    }

    var activeProxyLabel: String? {
        guard let proxy = activeSOCKS5Proxy else { return nil }
        return "\(proxy.host):\(proxy.port)"
    }

    var resolutionSourceLabel: String {
        stats.resolutionSource.isEmpty ? "—" : stats.resolutionSource
    }
}
