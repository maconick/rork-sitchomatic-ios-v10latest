import Foundation

nonisolated struct OpenVPNConfig: Identifiable, Codable, Sendable {
    let id: UUID
    let fileName: String
    let remoteHost: String
    let remotePort: Int
    let proto: String
    let rawContent: String
    var isEnabled: Bool
    var importedAt: Date
    var lastTested: Date?
    var isReachable: Bool
    var failCount: Int
    var lastLatencyMs: Int?

    init(fileName: String, remoteHost: String, remotePort: Int, proto: String, rawContent: String) {
        self.id = UUID()
        self.fileName = fileName
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.proto = proto
        self.rawContent = rawContent
        self.isEnabled = true
        self.importedAt = Date()
        self.lastTested = nil
        self.isReachable = false
        self.failCount = 0
        self.lastLatencyMs = nil
    }

    var displayString: String {
        "\(remoteHost):\(remotePort) (\(proto))"
    }

    var statusLabel: String {
        if !isEnabled { return "Disabled" }
        if let _ = lastTested {
            return isReachable ? "Reachable" : "Unreachable"
        }
        return "Untested"
    }

    var uniqueKey: String {
        "\(remoteHost)|\(remotePort)|\(proto)"
    }

    var serverName: String {
        let host = remoteHost
        if host.contains(".nordvpn.com") {
            return host.replacingOccurrences(of: ".nordvpn.com", with: "")
        }
        if host.contains(".") {
            let parts = host.components(separatedBy: ".")
            if parts.count >= 2 {
                return parts[0]
            }
        }
        return host
    }

    static func parse(fileName: String, content: String) -> OpenVPNConfig? {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var host = ""
        var port = 1194
        var proto = "udp"
        var foundRemote = false

        for line in lines {
            let lower = line.lowercased()

            if lower.hasPrefix("remote ") && !foundRemote {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 { host = parts[1] }
                if parts.count >= 3, let p = Int(parts[2]) { port = p }
                if parts.count >= 4 { proto = parts[3].lowercased() }
                foundRemote = true
            }

            if lower.hasPrefix("proto ") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 { proto = parts[1].lowercased() }
            }
        }

        guard !host.isEmpty else { return nil }

        return OpenVPNConfig(
            fileName: fileName,
            remoteHost: host,
            remotePort: port,
            proto: proto,
            rawContent: content
        )
    }
}
