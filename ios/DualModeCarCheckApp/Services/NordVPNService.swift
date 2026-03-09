import Foundation
import Observation

nonisolated struct NordVPNServer: Codable, Sendable {
    let id: Int
    let hostname: String
    let station: String
    let load: Int
    let locations: [NordLocation]?
    let technologies: [NordTechnology]?

    var publicKey: String? {
        technologies?.first(where: { $0.identifier == "wireguard_udp" })?
            .metadata?.first?.value
    }

    var hasOpenVPNTCP: Bool {
        technologies?.contains(where: { $0.identifier == "openvpn_tcp" }) ?? false
    }

    var hasOpenVPNUDP: Bool {
        technologies?.contains(where: { $0.identifier == "openvpn_udp" }) ?? false
    }

    var city: String? {
        locations?.first?.country?.city?.name
    }

    var country: String? {
        locations?.first?.country?.name
    }

    var tcpOVPNDownloadURL: URL? {
        URL(string: "https://downloads.nordcdn.com/configs/files/ovpn_tcp/servers/\(hostname).tcp.ovpn")
    }

    var udpOVPNDownloadURL: URL? {
        URL(string: "https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/\(hostname).udp.ovpn")
    }
}

nonisolated struct NordLocation: Codable, Sendable {
    let country: NordCountry?
}

nonisolated struct NordCountry: Codable, Sendable {
    let name: String?
    let city: NordCity?
}

nonisolated struct NordCity: Codable, Sendable {
    let name: String?
}

nonisolated struct NordTechnology: Codable, Sendable {
    let id: Int?
    let identifier: String?
    let metadata: [NordMetadata]?
}

nonisolated struct NordMetadata: Codable, Sendable {
    let name: String?
    let value: String?
}

nonisolated struct NordCredentials: Codable, Sendable {
    let nordlynx_private_key: String?
}

nonisolated enum NordKeyProfile: String, CaseIterable, Codable, Sendable {
    case nick = "Nick"
    case poli = "Poli"

    var hardcodedAccessKey: String {
        switch self {
        case .nick: kDefaultNickKey
        case .poli: kDefaultPoliKey
        }
    }
}

@Observable
@MainActor
class NordVPNService {
    static let shared = NordVPNService()

    var accessKey: String = ""
    var privateKey: String = ""
    var isLoadingServers: Bool = false
    var isLoadingKey: Bool = false
    var lastError: String?
    var recommendedServers: [NordVPNServer] = []
    var lastFetched: Date?
    var activeKeyProfile: NordKeyProfile = .nick

    private let accessKeyPersistKey = "nordvpn_access_key_v1"
    private let privateKeyPersistKey = "nordvpn_private_key_v1"
    private let keyProfilePersistKey = "nordvpn_key_profile_v1"
    private let nickPrivateKeyPersistKey = "nordvpn_nick_private_key_v1"
    private let poliPrivateKeyPersistKey = "nordvpn_poli_private_key_v1"
    private let logger = DebugLogger.shared
    private let serverCacheKey = "nordvpn_server_cache_v1"
    private let serverCacheTimestampKey = "nordvpn_server_cache_ts_v1"
    private let serverCacheMaxAge: TimeInterval = 3600

    init() {
        if let profileRaw = UserDefaults.standard.string(forKey: keyProfilePersistKey),
           let profile = NordKeyProfile(rawValue: profileRaw) {
            activeKeyProfile = profile
        }
        accessKey = activeKeyProfile.hardcodedAccessKey
        let pkKey = activeKeyProfile == .nick ? nickPrivateKeyPersistKey : poliPrivateKeyPersistKey
        privateKey = UserDefaults.standard.string(forKey: pkKey) ?? ""
    }

    func switchProfile(_ profile: NordKeyProfile) {
        let currentPKKey = activeKeyProfile == .nick ? nickPrivateKeyPersistKey : poliPrivateKeyPersistKey
        if !privateKey.isEmpty {
            UserDefaults.standard.set(privateKey, forKey: currentPKKey)
        }
        activeKeyProfile = profile
        accessKey = profile.hardcodedAccessKey
        UserDefaults.standard.set(profile.rawValue, forKey: keyProfilePersistKey)
        UserDefaults.standard.set(accessKey, forKey: accessKeyPersistKey)
        let newPKKey = profile == .nick ? nickPrivateKeyPersistKey : poliPrivateKeyPersistKey
        privateKey = UserDefaults.standard.string(forKey: newPKKey) ?? ""
        recommendedServers.removeAll()
        lastError = nil
        logger.log("NordVPN: switched to \(profile.rawValue) profile", category: .vpn, level: .success)
    }

    func setAccessKey(_ key: String) {
        accessKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(accessKey, forKey: accessKeyPersistKey)
    }

    func setPrivateKey(_ key: String) {
        privateKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let pkKey = activeKeyProfile == .nick ? nickPrivateKeyPersistKey : poliPrivateKeyPersistKey
        UserDefaults.standard.set(privateKey, forKey: pkKey)
    }

    var hasAccessKey: Bool { !accessKey.isEmpty }
    var hasPrivateKey: Bool { !privateKey.isEmpty }

    func fetchPrivateKey() async {
        guard hasAccessKey else {
            lastError = "No access key configured"
            return
        }

        isLoadingKey = true
        lastError = nil
        defer { isLoadingKey = false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://api.nordvpn.com/v1/users/services/credentials") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let credentials = "token:\(accessKey)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                switch http.statusCode {
                case 401:
                    lastError = "Access token expired or invalid. Generate a new token from NordVPN dashboard → Manual Setup."
                    isTokenExpired = true
                case 403:
                    lastError = "Access denied. Your NordVPN subscription may have expired or the token lacks permissions."
                    isTokenExpired = true
                case 404:
                    lastError = "Credentials endpoint not found (HTTP 404). NordVPN may have updated their API."
                case 429:
                    lastError = "Rate limited by NordVPN. Wait a minute and try again."
                default:
                    lastError = "API returned HTTP \(http.statusCode)"
                }
                logger.log("NordVPN: fetchPrivateKey failed — HTTP \(http.statusCode): \(body.prefix(200))", category: .vpn, level: .error, metadata: ["statusCode": "\(http.statusCode)"])
                return
            }
            let creds = try JSONDecoder().decode(NordCredentials.self, from: data)
            if let pk = creds.nordlynx_private_key, !pk.isEmpty {
                setPrivateKey(pk)
                isTokenExpired = false
                logger.log("NordVPN: private key fetched successfully", category: .vpn, level: .success)
            } else {
                lastError = "No private key in response. Token may not have NordLynx access."
                logger.log("NordVPN: response missing nordlynx_private_key", category: .vpn, level: .error)
            }
        } catch let error as URLError where error.code == .timedOut {
            lastError = "Request timed out. Check your connection and try again."
            logger.logError("NordVPN: fetchPrivateKey timeout", error: error, category: .vpn)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            lastError = "No internet connection."
            logger.logError("NordVPN: fetchPrivateKey no network", error: error, category: .vpn)
        } catch {
            lastError = "Failed to fetch key: \(error.localizedDescription)"
            logger.logError("NordVPN: fetchPrivateKey network error", error: error, category: .vpn)
        }
    }

    var isTokenExpired: Bool = UserDefaults.standard.bool(forKey: "nordvpn_token_expired_v1") {
        didSet { UserDefaults.standard.set(isTokenExpired, forKey: "nordvpn_token_expired_v1") }
    }
    var isDownloadingOVPN: Bool = false
    var ovpnDownloadProgress: String = ""

    func fetchRecommendedServers(country: String? = nil, limit: Int = 10, technology: String = "openvpn_tcp") async {
        isLoadingServers = true
        lastError = nil
        defer { isLoadingServers = false }

        var components = URLComponents(string: "https://api.nordvpn.com/v1/servers/recommendations")
        components?.queryItems = [
            URLQueryItem(name: "filters[servers_technologies][identifier]", value: technology),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        if let country = country {
            components?.queryItems?.append(URLQueryItem(name: "filters[country_id]", value: country))
        }

        guard let url = components?.url else {
            lastError = "Invalid API URL"
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    break
                case 404:
                    lastError = "Server endpoint not found (HTTP 404). NordVPN API may have changed."
                    logger.log("NordVPN: fetchServers 404 — endpoint may be deprecated", category: .vpn, level: .error)
                    let cached = loadCachedServers()
                    if !cached.isEmpty {
                        recommendedServers = cached
                        lastError = (lastError ?? "") + " Using cached servers."
                    }
                    return
                case 429:
                    lastError = "Rate limited by NordVPN. Wait a minute and try again."
                    logger.log("NordVPN: fetchServers rate limited", category: .vpn, level: .warning)
                    return
                default:
                    lastError = "API returned HTTP \(http.statusCode)"
                    logger.log("NordVPN: fetchServers failed — HTTP \(http.statusCode)", category: .vpn, level: .error)
                    return
                }
            }
            let servers = try JSONDecoder().decode([NordVPNServer].self, from: data)
            recommendedServers = servers
            lastFetched = Date()
            cacheServers(servers)
            logger.log("NordVPN: fetched \(servers.count) servers (tech: \(technology))", category: .vpn, level: .success)
        } catch is DecodingError {
            lastError = "Failed to parse server response. API format may have changed."
            logger.log("NordVPN: server response decoding failed", category: .vpn, level: .error)
            let cached = loadCachedServers()
            if !cached.isEmpty {
                recommendedServers = cached
                lastError = (lastError ?? "") + " Using cached servers."
            }
        } catch let error as URLError where error.code == .timedOut {
            lastError = "Request timed out. Check your connection."
            let cached = loadCachedServers()
            if !cached.isEmpty {
                recommendedServers = cached
                lastError = (lastError ?? "") + " Using cached servers."
            }
            logger.logError("NordVPN: fetchServers timeout", error: error, category: .vpn)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            lastError = "No internet connection."
            let cached = loadCachedServers()
            if !cached.isEmpty {
                recommendedServers = cached
                lastError = (lastError ?? "") + " Using cached servers."
            }
            logger.logError("NordVPN: fetchServers no network", error: error, category: .vpn)
        } catch {
            let cached = loadCachedServers()
            if !cached.isEmpty {
                recommendedServers = cached
                lastFetched = Date()
                lastError = "Using cached servers (API unavailable)"
                logger.log("NordVPN: API failed, loaded \(cached.count) cached servers", category: .vpn, level: .warning)
            } else {
                lastError = "Failed to fetch servers: \(error.localizedDescription)"
                logger.logError("NordVPN: fetchServers error (no cache)", error: error, category: .vpn)
            }
        }
    }

    func downloadOVPNConfig(from server: NordVPNServer, proto: NordOVPNProto = .tcp) async -> OpenVPNConfig? {
        let downloadURL: URL?
        switch proto {
        case .tcp: downloadURL = server.tcpOVPNDownloadURL
        case .udp: downloadURL = server.udpOVPNDownloadURL
        }

        guard let url = downloadURL else {
            logger.log("NordVPN: no download URL for \(server.hostname) (\(proto.rawValue))", category: .vpn, level: .error)
            return nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.log("NordVPN: OVPN download HTTP \(http.statusCode) for \(server.hostname)", category: .vpn, level: .error)
                return nil
            }
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                logger.log("NordVPN: OVPN download empty/non-UTF8 for \(server.hostname)", category: .vpn, level: .error)
                return nil
            }
            let fileName = "\(server.hostname).\(proto == .tcp ? "tcp" : "udp").ovpn"
            let parsed = OpenVPNConfig.parse(fileName: fileName, content: content)
            if parsed != nil {
                logger.log("NordVPN: downloaded \(fileName) (\(data.count) bytes)", category: .vpn, level: .success)
            } else {
                logger.log("NordVPN: OVPN parse failed for \(fileName) (\(data.count) bytes)", category: .vpn, level: .error)
            }
            return parsed
        } catch {
            logger.logError("NordVPN: OVPN download error for \(server.hostname)", error: error, category: .vpn)
            return nil
        }
    }

    func downloadAllTCPConfigs(for servers: [NordVPNServer], target: ProxyRotationService.ProxyTarget) async -> (imported: Int, failed: Int) {
        isDownloadingOVPN = true
        ovpnDownloadProgress = "0/\(servers.count)"
        defer {
            isDownloadingOVPN = false
            ovpnDownloadProgress = ""
        }

        let proxyService = ProxyRotationService.shared
        var imported = 0
        var failed = 0

        for (index, server) in servers.enumerated() {
            ovpnDownloadProgress = "\(index + 1)/\(servers.count)"
            if let config = await downloadOVPNConfig(from: server, proto: .tcp) {
                proxyService.importVPNConfig(config, for: target)
                imported += 1
            } else {
                failed += 1
            }
        }

        return (imported, failed)
    }

    func fetchAndDownloadTCPServers(country: String? = nil, limit: Int = 10, target: ProxyRotationService.ProxyTarget) async -> (imported: Int, failed: Int) {
        await fetchRecommendedServers(country: country, limit: limit, technology: "openvpn_tcp")
        guard !recommendedServers.isEmpty else {
            return (0, 0)
        }
        return await downloadAllTCPConfigs(for: recommendedServers, target: target)
    }

    func generateWireGuardConfig(from server: NordVPNServer) -> WireGuardConfig? {
        guard let publicKey = server.publicKey, !publicKey.isEmpty else { return nil }
        guard hasPrivateKey else { return nil }

        let endpoint = "\(server.station):51820"
        let rawContent = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = \(publicKey)\nAllowedIPs = 0.0.0.0/0\nEndpoint = \(endpoint)\nPersistentKeepalive = 25"

        return WireGuardConfig(
            fileName: server.hostname,
            interfaceAddress: "10.5.0.2/32",
            interfacePrivateKey: privateKey,
            interfaceDNS: "103.86.96.100, 103.86.99.100",
            interfaceMTU: nil,
            peerPublicKey: publicKey,
            peerPreSharedKey: nil,
            peerEndpoint: endpoint,
            peerAllowedIPs: "0.0.0.0/0",
            peerPersistentKeepalive: 25,
            rawContent: rawContent
        )
    }

    func generateOpenVPNEndpoint(from server: NordVPNServer, proto: String = "tcp", port: Int = 443) -> OpenVPNConfig {
        let rawContent = "client\ndev tun\nproto \(proto)\nremote \(server.hostname) \(port)\nresolv-retry infinite\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\ncipher AES-256-GCM\nauth SHA512\nverb 3"

        return OpenVPNConfig(
            fileName: server.hostname,
            remoteHost: server.hostname,
            remotePort: port,
            proto: proto,
            rawContent: rawContent
        )
    }

    private func cacheServers(_ servers: [NordVPNServer]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: serverCacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: serverCacheTimestampKey)
        }
    }

    private func loadCachedServers() -> [NordVPNServer] {
        let ts = UserDefaults.standard.double(forKey: serverCacheTimestampKey)
        guard ts > 0 else { return [] }
        let age = Date().timeIntervalSince1970 - ts
        guard age < serverCacheMaxAge else { return [] }
        guard let data = UserDefaults.standard.data(forKey: serverCacheKey) else { return [] }
        return (try? JSONDecoder().decode([NordVPNServer].self, from: data)) ?? []
    }
}

nonisolated enum NordOVPNProto: String, Sendable {
    case tcp
    case udp
}
