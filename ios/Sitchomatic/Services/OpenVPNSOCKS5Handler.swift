import Foundation
import Network

@MainActor
class OpenVPNSOCKS5Handler {
    let id: UUID
    private let clientConnection: NWConnection
    private let queue: DispatchQueue
    private weak var server: LocalProxyServer?
    private let bridge = OpenVPNProxyBridge.shared
    private let logger = DebugLogger.shared

    private var upstreamConnection: NWConnection?
    private var isCancelled: Bool = false
    private var targetHost: String = ""
    private var targetPort: UInt16 = 0
    private var timeoutWork: DispatchWorkItem?
    private let timeoutSeconds: TimeInterval = 30

    private var bytesRelayed: UInt64 = 0
    private var bytesUploaded: UInt64 = 0
    private var bytesDownloaded: UInt64 = 0
    private var hadError: Bool = false
    private var errorType: ConnectionErrorType = .none
    private var upstreamHalfClosed: Bool = false
    private var clientHalfClosed: Bool = false

    init(id: UUID, clientConnection: NWConnection, queue: DispatchQueue, server: LocalProxyServer) {
        self.id = id
        self.clientConnection = clientConnection
        self.queue = queue
        self.server = server
    }

    func start() {
        startTimeout()

        clientConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.readSOCKS5Greeting()
                case .failed:
                    self.errorType = .connection
                    self.finish(error: true)
                case .cancelled:
                    self.finish(error: false)
                default:
                    break
                }
            }
        }
        clientConnection.start(queue: queue)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        clientConnection.cancel()
        upstreamConnection?.cancel()
    }

    // MARK: - Client SOCKS5 Handshake

    private func readSOCKS5Greeting() {
        server?.updateConnectionInfo(id: id, targetHost: "", targetPort: 0, state: .handshaking)

        clientConnection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.finish(error: true); return }
                guard let data, data.count >= 2, data[0] == 0x05 else {
                    self.errorType = .handshake; self.finish(error: true); return
                }

                let response = Data([0x05, 0x00])
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isCancelled else { return }
                        if sendError != nil { self.errorType = .handshake; self.finish(error: true); return }
                        self.readSOCKS5Request()
                    }
                })
            }
        }
    }

    private func readSOCKS5Request() {
        clientConnection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.errorType = .handshake; self.finish(error: true); return }
                guard let data, data.count >= 4, data[0] == 0x05, data[1] == 0x01 else {
                    self.sendClientSOCKS5Error(0x07); return
                }

                let addressType = data[3]
                var host: String = ""
                var port: UInt16 = 0

                switch addressType {
                case 0x01:
                    guard data.count >= 10 else { self.errorType = .handshake; self.finish(error: true); return }
                    host = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
                    port = UInt16(data[8]) << 8 | UInt16(data[9])

                case 0x03:
                    guard data.count >= 5 else { self.errorType = .handshake; self.finish(error: true); return }
                    let domainLength = Int(data[4])
                    guard data.count >= 5 + domainLength + 2 else { self.errorType = .handshake; self.finish(error: true); return }
                    host = String(data: data[5..<(5 + domainLength)], encoding: .utf8) ?? ""
                    let portOffset = 5 + domainLength
                    port = UInt16(data[portOffset]) << 8 | UInt16(data[portOffset + 1])

                case 0x04:
                    guard data.count >= 22 else { self.errorType = .handshake; self.finish(error: true); return }
                    let ipv6Bytes = data[4..<20]
                    host = ipv6Bytes.map { String(format: "%02x", $0) }
                        .enumerated()
                        .reduce("") { result, pair in
                            let sep = (pair.offset > 0 && pair.offset % 2 == 0) ? ":" : ""
                            return result + sep + pair.element
                        }
                    port = UInt16(data[20]) << 8 | UInt16(data[21])

                default:
                    self.sendClientSOCKS5Error(0x08); return
                }

                guard !host.isEmpty, port > 0 else {
                    self.sendClientSOCKS5Error(0x01); return
                }

                self.targetHost = host
                self.targetPort = port
                self.server?.updateConnectionInfo(id: self.id, targetHost: host, targetPort: port, state: .handshaking)
                self.connectToUpstreamSOCKS5(targetHost: host, targetPort: port)
            }
        }
    }

    // MARK: - Upstream SOCKS5 Connection

    private func connectToUpstreamSOCKS5(targetHost: String, targetPort: UInt16) {
        guard let upstreamProxy = bridge.activeSOCKS5Proxy else {
            bridge.recordConnectionFailed()
            sendClientSOCKS5Error(0x01)
            return
        }

        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(upstreamProxy.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(upstreamProxy.port))
        )
        let conn = NWConnection(to: proxyEndpoint, using: .tcp)
        self.upstreamConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.performUpstreamGreeting(proxy: upstreamProxy, targetHost: targetHost, targetPort: targetPort)
                case .failed:
                    self.bridge.recordConnectionFailed()
                    self.errorType = .connection
                    self.sendClientSOCKS5Error(0x05)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func performUpstreamGreeting(proxy: ProxyConfig, targetHost: String, targetPort: UInt16) {
        guard let upstreamConnection, !isCancelled else { return }

        let needsAuth = proxy.username != nil && proxy.password != nil
        let greeting: Data = needsAuth ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00])

        upstreamConnection.send(content: greeting, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                self.readUpstreamGreetingResponse(proxy: proxy, targetHost: targetHost, targetPort: targetPort)
            }
        })
    }

    private func readUpstreamGreetingResponse(proxy: ProxyConfig, targetHost: String, targetPort: UInt16) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[0] == 0x05 else {
                    self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return
                }

                let method = data[1]
                if method == 0x02, let username = proxy.username, let password = proxy.password {
                    self.performUpstreamAuth(username: username, password: password, targetHost: targetHost, targetPort: targetPort)
                } else if method == 0x00 {
                    self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort)
                } else {
                    self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01)
                }
            }
        }
    }

    private func performUpstreamAuth(username: String, password: String, targetHost: String, targetPort: UInt16) {
        guard let upstreamConnection, !isCancelled else { return }

        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        var authData = Data([0x01, UInt8(usernameBytes.count)])
        authData.append(contentsOf: usernameBytes)
        authData.append(UInt8(passwordBytes.count))
        authData.append(contentsOf: passwordBytes)

        upstreamConnection.send(content: authData, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                self.readUpstreamAuthResponse(targetHost: targetHost, targetPort: targetPort)
            }
        })
    }

    private func readUpstreamAuthResponse(targetHost: String, targetPort: UInt16) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[1] == 0x00 else {
                    self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return
                }
                self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort)
            }
        }
    }

    private func sendUpstreamConnectRequest(targetHost: String, targetPort: UInt16) {
        guard let upstreamConnection, !isCancelled else { return }

        var request = Data([0x05, 0x01, 0x00, 0x03])
        let hostBytes = Array(targetHost.utf8)
        request.append(UInt8(hostBytes.count))
        request.append(contentsOf: hostBytes)
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))

        upstreamConnection.send(content: request, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                self.readUpstreamConnectResponse()
            }
        })
    }

    private func readUpstreamConnectResponse() {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(0x01); return }
                guard let data, data.count >= 4, data[0] == 0x05, data[1] == 0x00 else {
                    let rep = data != nil && data!.count >= 2 ? data![1] : UInt8(0x01)
                    self.bridge.recordConnectionFailed(); self.errorType = .handshake; self.sendClientSOCKS5Error(rep); return
                }
                self.bridge.recordConnectionServed()
                self.sendClientSOCKS5Success()
            }
        }
    }

    // MARK: - Client Response

    private func sendClientSOCKS5Success() {
        cancelTimeout()

        let response = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.finish(error: true); return }
                self.server?.updateConnectionInfo(id: self.id, targetHost: self.targetHost, targetPort: self.targetPort, state: .relaying)
                self.startRelaying()
            }
        })
    }

    private func sendClientSOCKS5Error(_ rep: UInt8) {
        let response = Data([0x05, rep, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(error: true)
            }
        })
    }

    // MARK: - Bidirectional Relay

    private func startRelaying() {
        relayData(from: clientConnection, to: upstreamConnection, isUpload: true)
        relayData(from: upstreamConnection, to: clientConnection, isUpload: false)
    }

    private func relayData(from source: NWConnection?, to destination: NWConnection?, isUpload: Bool) {
        guard let source, let destination, !isCancelled else { return }

        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }

                if let data, !data.isEmpty {
                    let count = UInt64(data.count)
                    self.bytesRelayed += count
                    if isUpload {
                        self.bytesUploaded += count
                    } else {
                        self.bytesDownloaded += count
                    }
                    self.server?.updateConnectionBytes(id: self.id, bytes: self.bytesRelayed)

                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isCancelled else { return }
                            if sendError != nil {
                                self.errorType = .relay
                                self.finish(error: true)
                                return
                            }
                            if isComplete {
                                self.handleHalfClose(isUpload: isUpload, destination: destination)
                            } else {
                                self.relayData(from: source, to: destination, isUpload: isUpload)
                            }
                        }
                    })
                } else if isComplete {
                    self.handleHalfClose(isUpload: isUpload, destination: destination)
                } else if error != nil {
                    self.errorType = .relay
                    self.finish(error: true)
                } else {
                    self.relayData(from: source, to: destination, isUpload: isUpload)
                }
            }
        }
    }

    private func handleHalfClose(isUpload: Bool, destination: NWConnection) {
        if isUpload {
            clientHalfClosed = true
        } else {
            upstreamHalfClosed = true
        }

        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if self.clientHalfClosed && self.upstreamHalfClosed {
                    self.finish(error: false)
                }
            }
        })
    }

    // MARK: - Lifecycle

    private func finish(error: Bool) {
        guard !isCancelled else { return }
        isCancelled = true
        cancelTimeout()
        hadError = error || hadError

        bridge.recordBytes(up: bytesUploaded, down: bytesDownloaded)

        clientConnection.cancel()
        upstreamConnection?.cancel()

        server?.connectionFinished(
            id: id,
            bytesRelayed: bytesRelayed,
            bytesUp: bytesUploaded,
            bytesDown: bytesDownloaded,
            hadError: hadError,
            errorType: errorType,
            targetHost: targetHost
        )
        server?.tunnelConnectionFinished(id: id)
    }

    private func startTimeout() {
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.errorType = .connection
                self.finish(error: true)
            }
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }
}
