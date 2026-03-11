import Foundation
import Network

nonisolated struct PooledConnectionInfo: Sendable {
    let id: UUID
    let targetHost: String
    let targetPort: UInt16
    let createdAt: Date
    var lastUsedAt: Date
    var bytesTransferred: UInt64
    var isIdle: Bool
}

@Observable
@MainActor
class ProxyConnectionPool {
    static let shared = ProxyConnectionPool()

    private(set) var pooledConnections: [UUID: PooledConnectionInfo] = [:]
    private(set) var totalPoolHits: Int = 0
    private(set) var totalPoolMisses: Int = 0
    private(set) var totalEvictions: Int = 0

    var maxPoolSize: Int = 20
    var idleTimeoutSeconds: TimeInterval = 60
    var connectionTTLSeconds: TimeInterval = 300

    private var upstreamConnections: [UUID: NWConnection] = [:]
    private var cleanupTimer: Timer?
    private let logger = DebugLogger.shared
    private let queue = DispatchQueue(label: "proxy-connection-pool", qos: .userInitiated)

    private var cleanupTimerStarted = false

    init() {}

    func acquireUpstream(targetHost: String, targetPort: UInt16, upstream: ProxyConfig?, completion: @escaping (NWConnection?, UUID?) -> Void) {
        if !cleanupTimerStarted {
            cleanupTimerStarted = true
            startCleanupTimer()
        }
        let poolKey = "\(targetHost):\(targetPort)"

        for (id, info) in pooledConnections where info.isIdle && "\(info.targetHost):\(info.targetPort)" == poolKey {
            if let conn = upstreamConnections[id], conn.state == .ready {
                var updated = info
                updated.lastUsedAt = Date()
                updated.isIdle = false
                pooledConnections[id] = updated
                totalPoolHits += 1
                logger.log("ConnectionPool: HIT for \(poolKey) (id: \(id.uuidString.prefix(8)))", category: .proxy, level: .trace)
                completion(conn, id)
                return
            } else {
                evictConnection(id: id, reason: "stale")
            }
        }

        totalPoolMisses += 1

        if pooledConnections.count >= maxPoolSize {
            evictOldest()
        }

        let id = UUID()
        let info = PooledConnectionInfo(
            id: id,
            targetHost: targetHost,
            targetPort: targetPort,
            createdAt: Date(),
            lastUsedAt: Date(),
            bytesTransferred: 0,
            isIdle: false
        )
        pooledConnections[id] = info

        if let upstream {
            let proxyEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(upstream.host),
                port: NWEndpoint.Port(integerLiteral: UInt16(upstream.port))
            )
            let conn = NWConnection(to: proxyEndpoint, using: .tcp)
            upstreamConnections[id] = conn

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        completion(conn, id)
                    case .failed:
                        self?.evictConnection(id: id, reason: "connect failed")
                        completion(nil, nil)
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)
        } else {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(targetHost),
                port: NWEndpoint.Port(integerLiteral: targetPort)
            )
            let conn = NWConnection(to: endpoint, using: .tcp)
            upstreamConnections[id] = conn

            conn.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        completion(conn, id)
                    case .failed:
                        self?.evictConnection(id: id, reason: "direct connect failed")
                        completion(nil, nil)
                    default:
                        break
                    }
                }
            }
            conn.start(queue: queue)
        }
    }

    func releaseConnection(id: UUID, hadError: Bool) {
        if hadError {
            evictConnection(id: id, reason: "error")
            return
        }

        guard var info = pooledConnections[id] else { return }

        if let conn = upstreamConnections[id], conn.state == .ready {
            info.isIdle = true
            info.lastUsedAt = Date()
            pooledConnections[id] = info
            logger.log("ConnectionPool: released \(id.uuidString.prefix(8)) back to pool (idle)", category: .proxy, level: .trace)
        } else {
            evictConnection(id: id, reason: "not ready on release")
        }
    }

    func recordBytesTransferred(id: UUID, bytes: UInt64) {
        guard var info = pooledConnections[id] else { return }
        info.bytesTransferred += bytes
        pooledConnections[id] = info
    }

    func drainPool() {
        for (id, _) in upstreamConnections {
            upstreamConnections[id]?.cancel()
        }
        upstreamConnections.removeAll()
        pooledConnections.removeAll()
        totalPoolHits = 0
        totalPoolMisses = 0
        totalEvictions = 0
        logger.log("ConnectionPool: drained all connections", category: .proxy, level: .info)
    }

    var poolUtilization: Double {
        guard maxPoolSize > 0 else { return 0 }
        return Double(pooledConnections.count) / Double(maxPoolSize) * 100
    }

    var hitRate: Double {
        let total = totalPoolHits + totalPoolMisses
        guard total > 0 else { return 0 }
        return Double(totalPoolHits) / Double(total) * 100
    }

    var activeCount: Int {
        pooledConnections.values.filter { !$0.isIdle }.count
    }

    var idleCount: Int {
        pooledConnections.values.filter { $0.isIdle }.count
    }

    private func evictConnection(id: UUID, reason: String) {
        upstreamConnections[id]?.cancel()
        upstreamConnections.removeValue(forKey: id)
        pooledConnections.removeValue(forKey: id)
        totalEvictions += 1
        logger.log("ConnectionPool: evicted \(id.uuidString.prefix(8)) (\(reason))", category: .proxy, level: .trace)
    }

    private func evictOldest() {
        let idleConnections = pooledConnections.filter { $0.value.isIdle }.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
        if let oldest = idleConnections.first {
            evictConnection(id: oldest.key, reason: "pool full — evicting oldest idle")
            return
        }
        let allSorted = pooledConnections.sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }
        if let oldest = allSorted.first {
            evictConnection(id: oldest.key, reason: "pool full — evicting oldest active")
        }
    }

    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupExpiredConnections()
            }
        }
    }

    private func cleanupExpiredConnections() {
        let now = Date()
        var toEvict: [UUID] = []

        for (id, info) in pooledConnections {
            if info.isIdle && now.timeIntervalSince(info.lastUsedAt) > idleTimeoutSeconds {
                toEvict.append(id)
            } else if now.timeIntervalSince(info.createdAt) > connectionTTLSeconds {
                if info.isIdle {
                    toEvict.append(id)
                }
            }
        }

        for id in toEvict {
            evictConnection(id: id, reason: "expired")
        }

        if !toEvict.isEmpty {
            logger.log("ConnectionPool: cleanup evicted \(toEvict.count) expired connections (pool: \(pooledConnections.count)/\(maxPoolSize))", category: .proxy, level: .debug)
        }
    }
}
