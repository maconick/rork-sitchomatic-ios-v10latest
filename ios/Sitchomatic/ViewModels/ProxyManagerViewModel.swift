import Foundation
import Observation

@Observable
@MainActor
class ProxyManagerViewModel {
    var proxySets: [ProxySet] = []
    var useOneServerPerSet: Bool = false
    var showNewSetSheet: Bool = false
    var editingSet: ProxySet?

    private let persistKey = "proxy_manager_sets_v1"
    private let settingsKey = "proxy_manager_settings_v1"
    private let logger = DebugLogger.shared

    var canUseOnePerSet: Bool {
        proxySets.filter(\.isActive).count >= 4
    }

    var activeSetsCount: Int {
        proxySets.filter(\.isActive).count
    }

    var totalItemsCount: Int {
        proxySets.reduce(0) { $0 + $1.items.count }
    }

    init() {
        loadSets()
        loadSettings()
    }

    func createSet(name: String, type: ProxySetType) {
        let newSet = ProxySet(name: name, type: type)
        proxySets.append(newSet)
        persistSets()
        logger.log("ProxyManager: created set '\(name)' type=\(type.rawValue)", category: .proxy, level: .info)
    }

    func deleteSet(_ set: ProxySet) {
        proxySets.removeAll { $0.id == set.id }
        if !canUseOnePerSet {
            useOneServerPerSet = false
        }
        persistSets()
        persistSettings()
        logger.log("ProxyManager: deleted set '\(set.name)'", category: .proxy, level: .info)
    }

    func toggleSetActive(_ set: ProxySet) {
        guard let idx = proxySets.firstIndex(where: { $0.id == set.id }) else { return }
        proxySets[idx].isActive.toggle()
        if !canUseOnePerSet {
            useOneServerPerSet = false
        }
        persistSets()
        persistSettings()
    }

    func addItemToSet(_ setId: UUID, item: ProxySetItem) {
        guard let idx = proxySets.firstIndex(where: { $0.id == setId }) else { return }
        guard proxySets[idx].items.count < proxySets[idx].type.maxItems else { return }
        proxySets[idx].items.append(item)
        persistSets()
    }

    func removeItemFromSet(_ setId: UUID, itemId: UUID) {
        guard let idx = proxySets.firstIndex(where: { $0.id == setId }) else { return }
        proxySets[idx].items.removeAll { $0.id == itemId }
        persistSets()
    }

    func toggleItemEnabled(_ setId: UUID, itemId: UUID) {
        guard let setIdx = proxySets.firstIndex(where: { $0.id == setId }) else { return }
        guard let itemIdx = proxySets[setIdx].items.firstIndex(where: { $0.id == itemId }) else { return }
        proxySets[setIdx].items[itemIdx].isEnabled.toggle()
        persistSets()
    }

    func updateSetName(_ setId: UUID, name: String) {
        guard let idx = proxySets.firstIndex(where: { $0.id == setId }) else { return }
        proxySets[idx].name = name
        persistSets()
    }

    func importSOCKS5Bulk(_ text: String, toSetId: UUID) -> (added: Int, failed: Int) {
        guard let idx = proxySets.firstIndex(where: { $0.id == toSetId }) else { return (0, 0) }
        guard proxySets[idx].type == .socks5 else { return (0, 0) }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var added = 0
        var failed = 0

        for line in lines {
            guard proxySets[idx].items.count < 10 else { break }

            if let item = parseSOCKS5Line(line) {
                let isDuplicate = proxySets[idx].items.contains { $0.host == item.host && $0.port == item.port }
                if !isDuplicate {
                    proxySets[idx].items.append(item)
                    added += 1
                } else {
                    failed += 1
                }
            } else {
                failed += 1
            }
        }

        persistSets()
        logger.log("ProxyManager: imported \(added) SOCKS5 proxies to set '\(proxySets[idx].name)' (\(failed) skipped)", category: .proxy, level: .info)
        return (added, failed)
    }

    func importWireGuardFile(_ content: String, fileName: String, toSetId: UUID) -> Int {
        guard let idx = proxySets.firstIndex(where: { $0.id == toSetId }) else { return 0 }
        guard proxySets[idx].type == .wireGuard else { return 0 }

        let configs = WireGuardConfig.parseMultiple(fileName: fileName, content: content)
        if configs.isEmpty {
            if let single = WireGuardConfig.parse(fileName: fileName, content: content) {
                let item = ProxySetItem.fromWireGuardConfig(single)
                let isDuplicate = proxySets[idx].items.contains { $0.host == item.host && $0.port == item.port }
                if !isDuplicate && proxySets[idx].items.count < 10 {
                    proxySets[idx].items.append(item)
                    persistSets()
                    return 1
                }
            }
            return 0
        }

        var added = 0
        for config in configs {
            guard proxySets[idx].items.count < 10 else { break }
            let item = ProxySetItem.fromWireGuardConfig(config)
            let isDuplicate = proxySets[idx].items.contains { $0.host == item.host && $0.port == item.port }
            if !isDuplicate {
                proxySets[idx].items.append(item)
                added += 1
            }
        }
        persistSets()
        logger.log("ProxyManager: imported \(added) WireGuard configs to set '\(proxySets[idx].name)'", category: .proxy, level: .info)
        return added
    }

    func importOpenVPNFile(_ content: String, fileName: String, toSetId: UUID) -> Bool {
        guard let idx = proxySets.firstIndex(where: { $0.id == toSetId }) else { return false }
        guard proxySets[idx].type == .openVPN else { return false }
        guard proxySets[idx].items.count < 10 else { return false }

        guard let config = OpenVPNConfig.parse(fileName: fileName, content: content) else { return false }
        let item = ProxySetItem.fromOpenVPNConfig(config)
        let isDuplicate = proxySets[idx].items.contains { $0.host == item.host && $0.port == item.port }
        guard !isDuplicate else { return false }

        proxySets[idx].items.append(item)
        persistSets()
        logger.log("ProxyManager: imported OpenVPN config '\(fileName)' to set '\(proxySets[idx].name)'", category: .proxy, level: .info)
        return true
    }

    func setForIndex(_ index: Int) -> ProxySet? {
        let active = proxySets.filter(\.isActive)
        guard index < active.count else { return nil }
        return active[index]
    }

    func serverForSession(sessionIndex: Int) -> ProxySetItem? {
        guard useOneServerPerSet, canUseOnePerSet else { return nil }
        let active = proxySets.filter(\.isActive)
        guard sessionIndex < active.count else { return nil }
        let set = active[sessionIndex]
        let enabledItems = set.items.filter(\.isEnabled)
        guard !enabledItems.isEmpty else { return nil }
        return enabledItems[sessionIndex % enabledItems.count]
    }

    private func parseSOCKS5Line(_ line: String) -> ProxySetItem? {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let protocolPrefixes = ["socks5://", "socks4://", "socks://", "http://", "https://"]
        for prefix in protocolPrefixes {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                break
            }
        }

        if cleaned.contains("@") {
            let atParts = cleaned.components(separatedBy: "@")
            guard atParts.count == 2 else { return nil }
            let hostPort = atParts[1].components(separatedBy: ":")
            guard hostPort.count >= 2, let port = Int(hostPort.last ?? "") else { return nil }
            let host = hostPort.dropLast().joined(separator: ":")
            guard !host.isEmpty, port > 0, port <= 65535 else { return nil }
            return ProxySetItem(label: "\(host):\(port)", host: host, port: port)
        }

        let parts = cleaned.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        if parts.count == 2, let port = Int(parts[1]), port > 0, port <= 65535 {
            return ProxySetItem(label: "\(parts[0]):\(port)", host: parts[0], port: port)
        }

        if parts.count == 4 {
            if let port = Int(parts[1]), port > 0, port <= 65535 {
                return ProxySetItem(label: "\(parts[0]):\(port)", host: parts[0], port: port)
            }
            if let port = Int(parts[3]), port > 0, port <= 65535 {
                return ProxySetItem(label: "\(parts[2]):\(port)", host: parts[2], port: port)
            }
        }

        if parts.count == 3 {
            if let port = Int(parts[1]), port > 0, port <= 65535 {
                return ProxySetItem(label: "\(parts[0]):\(port)", host: parts[0], port: port)
            }
            if let port = Int(parts[2]), port > 0, port <= 65535 {
                return ProxySetItem(label: "\(parts[0]):\(port)", host: parts[0], port: port)
            }
        }

        for i in 1..<parts.count {
            if let port = Int(parts[i]), port > 0, port <= 65535 {
                let host = parts[i - 1]
                let looksLikeHost = host.contains(".") || host.allSatisfy({ $0.isNumber || $0 == "." })
                if looksLikeHost {
                    return ProxySetItem(label: "\(host):\(port)", host: host, port: port)
                }
            }
        }

        return nil
    }

    private func persistSets() {
        guard let data = try? JSONEncoder().encode(proxySets) else { return }
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    private func loadSets() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let decoded = try? JSONDecoder().decode([ProxySet].self, from: data) else { return }
        proxySets = decoded
    }

    private func persistSettings() {
        UserDefaults.standard.set(useOneServerPerSet, forKey: settingsKey)
    }

    private func loadSettings() {
        useOneServerPerSet = UserDefaults.standard.bool(forKey: settingsKey)
        if !canUseOnePerSet {
            useOneServerPerSet = false
        }
    }
}
