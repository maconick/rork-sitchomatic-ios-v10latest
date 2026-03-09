import Foundation
import Network
import Observation

nonisolated struct LocalProxyStats: Sendable {
    var activeConnections: Int = 0
    var totalConnections: Int = 0
    var bytesRelayed: UInt64 = 0
    var upstreamErrors: Int = 0
    var lastConnectionTime: Date?
}

@Observable
@MainActor
class LocalProxyServer {
    static let shared = LocalProxyServer()

    private(set) var isRunning: Bool = false
    private(set) var listeningPort: UInt16 = 0
    private(set) var stats: LocalProxyStats = LocalProxyStats()
    private(set) var statusMessage: String = "Stopped"
    private(set) var upstreamLabel: String = "None"

    var upstreamProxy: ProxyConfig?

    private var listener: NWListener?
    private var connections: [UUID: LocalProxyConnection] = [:]
    private let queue = DispatchQueue(label: "local-proxy-server", qos: .userInitiated)
    private let logger = DebugLogger.shared
    private let preferredPort: UInt16 = 18080

    func start() {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback

            let nwListener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: preferredPort))
            self.listener = nwListener

            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            nwListener.newConnectionHandler = { [weak self] nwConnection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(nwConnection)
                }
            }

            nwListener.start(queue: queue)
            isRunning = true
            statusMessage = "Starting..."
            logger.log("LocalProxy: starting on port \(preferredPort)", category: .network, level: .info)
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
            logger.log("LocalProxy: failed to start — \(error)", category: .network, level: .error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        for conn in connections.values {
            conn.cancel()
        }
        connections.removeAll()

        isRunning = false
        listeningPort = 0
        statusMessage = "Stopped"
        stats = LocalProxyStats()
        logger.log("LocalProxy: stopped", category: .network, level: .info)
    }

    func updateUpstream(_ proxy: ProxyConfig?) {
        upstreamProxy = proxy
        if let proxy {
            upstreamLabel = proxy.displayString
            logger.log("LocalProxy: upstream changed → \(proxy.displayString)", category: .proxy, level: .info)
        } else {
            upstreamLabel = "None (direct)"
            logger.log("LocalProxy: upstream cleared → direct", category: .proxy, level: .info)
        }
    }

    var localProxyConfig: ProxyConfig {
        ProxyConfig(host: "127.0.0.1", port: Int(listeningPort == 0 ? preferredPort : listeningPort))
    }

    func connectionFinished(id: UUID, bytesRelayed: UInt64, hadError: Bool) {
        connections.removeValue(forKey: id)
        stats.activeConnections = connections.count
        stats.bytesRelayed += bytesRelayed
        if hadError {
            stats.upstreamErrors += 1
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                listeningPort = port.rawValue
            }
            isRunning = true
            statusMessage = "Running on :\(listeningPort)"
            logger.log("LocalProxy: listening on port \(listeningPort)", category: .network, level: .success)

        case .failed(let error):
            isRunning = false
            statusMessage = "Failed: \(error.localizedDescription)"
            logger.log("LocalProxy: listener failed — \(error)", category: .network, level: .error)
            listener?.cancel()
            listener = nil

        case .cancelled:
            isRunning = false
            statusMessage = "Stopped"

        default:
            break
        }
    }

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let id = UUID()
        stats.totalConnections += 1
        stats.lastConnectionTime = Date()

        let connection = LocalProxyConnection(
            id: id,
            clientConnection: nwConnection,
            upstream: upstreamProxy,
            queue: queue,
            server: self
        )
        connections[id] = connection
        stats.activeConnections = connections.count

        connection.start()
    }
}
