import Foundation
import Network

@MainActor
class LocalProxyConnection {
    let id: UUID
    private let clientConnection: NWConnection
    private var upstreamConnection: NWConnection?
    private let upstream: ProxyConfig?
    private let queue: DispatchQueue
    private weak var server: LocalProxyServer?

    private var bytesRelayed: UInt64 = 0
    private var hadError: Bool = false
    private var isCancelled: Bool = false

    init(id: UUID, clientConnection: NWConnection, upstream: ProxyConfig?, queue: DispatchQueue, server: LocalProxyServer) {
        self.id = id
        self.clientConnection = clientConnection
        self.upstream = upstream
        self.queue = queue
        self.server = server
    }

    func start() {
        clientConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.readSOCKS5Greeting()
                case .failed:
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
        clientConnection.cancel()
        upstreamConnection?.cancel()
    }

    private func finish(error: Bool) {
        guard !isCancelled else { return }
        isCancelled = true
        hadError = error || hadError
        clientConnection.cancel()
        upstreamConnection?.cancel()
        server?.connectionFinished(id: id, bytesRelayed: bytesRelayed, hadError: hadError)
    }

    private func readSOCKS5Greeting() {
        clientConnection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if let error {
                    self.hadError = true
                    self.finish(error: true)
                    return
                }
                guard let data, data.count >= 2 else {
                    self.finish(error: true)
                    return
                }

                let version = data[0]
                guard version == 0x05 else {
                    self.finish(error: true)
                    return
                }

                let response = Data([0x05, 0x00])
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isCancelled else { return }
                        if sendError != nil {
                            self.finish(error: true)
                            return
                        }
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
                if let error {
                    self.hadError = true
                    self.finish(error: true)
                    return
                }
                guard let data, data.count >= 4 else {
                    self.finish(error: true)
                    return
                }

                guard data[0] == 0x05, data[1] == 0x01 else {
                    self.sendSOCKS5Error(0x07)
                    return
                }

                let addressType = data[3]
                var targetHost: String = ""
                var targetPort: UInt16 = 0
                var headerLength: Int = 0

                switch addressType {
                case 0x01:
                    guard data.count >= 10 else { self.finish(error: true); return }
                    targetHost = "\(data[4]).\(data[5]).\(data[6]).\(data[7])"
                    targetPort = UInt16(data[8]) << 8 | UInt16(data[9])
                    headerLength = 10

                case 0x03:
                    guard data.count >= 5 else { self.finish(error: true); return }
                    let domainLength = Int(data[4])
                    guard data.count >= 5 + domainLength + 2 else { self.finish(error: true); return }
                    targetHost = String(data: data[5..<(5 + domainLength)], encoding: .utf8) ?? ""
                    let portOffset = 5 + domainLength
                    targetPort = UInt16(data[portOffset]) << 8 | UInt16(data[portOffset + 1])
                    headerLength = 5 + domainLength + 2

                case 0x04:
                    guard data.count >= 22 else { self.finish(error: true); return }
                    let ipv6Bytes = data[4..<20]
                    targetHost = ipv6Bytes.map { String(format: "%02x", $0) }
                        .enumerated()
                        .reduce("") { result, pair in
                            let sep = (pair.offset > 0 && pair.offset % 2 == 0) ? ":" : ""
                            return result + sep + pair.element
                        }
                    targetPort = UInt16(data[20]) << 8 | UInt16(data[21])
                    headerLength = 22

                default:
                    self.sendSOCKS5Error(0x08)
                    return
                }

                guard !targetHost.isEmpty, targetPort > 0 else {
                    self.sendSOCKS5Error(0x01)
                    return
                }

                self.connectToTarget(host: targetHost, port: targetPort, originalRequest: data, addressType: addressType)
            }
        }
    }

    private func connectToTarget(host: String, port: UInt16, originalRequest: Data, addressType: UInt8) {
        if let upstream {
            connectViaUpstream(upstream, targetHost: host, targetPort: port, addressType: addressType)
        } else {
            connectDirect(host: host, port: port, addressType: addressType)
        }
    }

    private func connectDirect(host: String, port: UInt16, addressType: UInt8) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.upstreamConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.sendSOCKS5Success(addressType: addressType)
                case .failed:
                    self.sendSOCKS5Error(0x05)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func connectViaUpstream(_ proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        let proxyEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(proxy.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(proxy.port))
        )
        let conn = NWConnection(to: proxyEndpoint, using: .tcp)
        self.upstreamConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                switch state {
                case .ready:
                    self.performUpstreamSOCKS5Handshake(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                case .failed:
                    self.sendSOCKS5Error(0x05)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
    }

    private func performUpstreamSOCKS5Handshake(proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        let needsAuth = proxy.username != nil && proxy.password != nil
        let greeting: Data
        if needsAuth {
            greeting = Data([0x05, 0x02, 0x00, 0x02])
        } else {
            greeting = Data([0x05, 0x01, 0x00])
        }

        upstreamConnection.send(content: greeting, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.sendSOCKS5Error(0x01); return }
                self.readUpstreamGreetingResponse(proxy: proxy, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        })
    }

    private func readUpstreamGreetingResponse(proxy: ProxyConfig, targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.sendSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[0] == 0x05 else {
                    self.sendSOCKS5Error(0x01)
                    return
                }

                let method = data[1]
                if method == 0x02, let username = proxy.username, let password = proxy.password {
                    self.performUpstreamAuth(username: username, password: password, targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                } else if method == 0x00 {
                    self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
                } else {
                    self.sendSOCKS5Error(0x01)
                }
            }
        }
    }

    private func performUpstreamAuth(username: String, password: String, targetHost: String, targetPort: UInt16, addressType: UInt8) {
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
                if error != nil { self.sendSOCKS5Error(0x01); return }
                self.readUpstreamAuthResponse(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        })
    }

    private func readUpstreamAuthResponse(targetHost: String, targetPort: UInt16, addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.sendSOCKS5Error(0x01); return }
                guard let data, data.count == 2, data[1] == 0x00 else {
                    self.sendSOCKS5Error(0x01)
                    return
                }
                self.sendUpstreamConnectRequest(targetHost: targetHost, targetPort: targetPort, addressType: addressType)
            }
        }
    }

    private func sendUpstreamConnectRequest(targetHost: String, targetPort: UInt16, addressType: UInt8) {
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
                if error != nil { self.sendSOCKS5Error(0x01); return }
                self.readUpstreamConnectResponse(addressType: addressType)
            }
        })
    }

    private func readUpstreamConnectResponse(addressType: UInt8) {
        guard let upstreamConnection, !isCancelled else { return }

        upstreamConnection.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.sendSOCKS5Error(0x01); return }
                guard let data, data.count >= 4, data[0] == 0x05, data[1] == 0x00 else {
                    let rep = data != nil && data!.count >= 2 ? data![1] : UInt8(0x01)
                    self.sendSOCKS5Error(rep)
                    return
                }
                self.sendSOCKS5Success(addressType: addressType)
            }
        }
    }

    private func sendSOCKS5Success(addressType: UInt8) {
        let response = Data([0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                if error != nil { self.finish(error: true); return }
                self.startRelaying()
            }
        })
    }

    private func sendSOCKS5Error(_ rep: UInt8) {
        let response = Data([0x05, rep, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finish(error: true)
            }
        })
    }

    private func startRelaying() {
        relayData(from: clientConnection, to: upstreamConnection, label: "client→upstream")
        relayData(from: upstreamConnection, to: clientConnection, label: "upstream→client")
    }

    private func relayData(from source: NWConnection?, to destination: NWConnection?, label: String) {
        guard let source, let destination, !isCancelled else { return }

        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }

                if let data, !data.isEmpty {
                    self.bytesRelayed += UInt64(data.count)
                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        Task { @MainActor [weak self] in
                            guard let self, !self.isCancelled else { return }
                            if sendError != nil {
                                self.finish(error: true)
                                return
                            }
                            self.relayData(from: source, to: destination, label: label)
                        }
                    })
                } else if isComplete || error != nil {
                    self.finish(error: error != nil)
                } else {
                    self.relayData(from: source, to: destination, label: label)
                }
            }
        }
    }
}
