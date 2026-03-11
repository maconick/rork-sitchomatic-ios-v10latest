import Foundation

@MainActor
class SOCKS5ProxyManager {
    var joeProxies: [ProxyConfig] = []
    var ignitionProxies: [ProxyConfig] = []
    var ppsrProxies: [ProxyConfig] = []
    var currentJoeIndex: Int = 0
    var currentIgnitionIndex: Int = 0
    var currentPPSRIndex: Int = 0

    private let joePersistKey = "saved_socks5_proxies_v2"
    private let ignitionPersistKey = "saved_socks5_proxies_ignition_v1"
    private let ppsrPersistKey = "saved_socks5_proxies_ppsr_v1"
    private let logger = DebugLogger.shared

    func loadAll() {
        joeProxies = loadProxyList(key: joePersistKey)
        if joeProxies.isEmpty { migrateFromV1() }
        ignitionProxies = loadProxyList(key: ignitionPersistKey)
        ppsrProxies = loadProxyList(key: ppsrPersistKey)
    }

    func proxies(for target: ProxyRotationService.ProxyTarget) -> [ProxyConfig] {
        switch target {
        case .joe: joeProxies
        case .ignition: ignitionProxies
        case .ppsr: ppsrProxies
        }
    }

    func nextWorkingProxy(for target: ProxyRotationService.ProxyTarget) -> ProxyConfig? {
        let list = proxies(for: target)
        let working = list.filter(\.isWorking)
        guard !working.isEmpty else {
            return list.isEmpty ? nil : list[indexFor(target) % list.count]
        }
        let idx = indexFor(target) % working.count
        incrementIndex(for: target)
        return working[idx]
    }

    func bulkImport(_ text: String, for target: ProxyRotationService.ProxyTarget) -> ProxyRotationService.ImportReport {
        let expandedLines = expandProxyLines(text)
        var added = 0
        var duplicates = 0
        var failed: [String] = []
        let targetList = proxies(for: target)

        for line in expandedLines {
            if let proxy = parseProxyLine(line) {
                let isDuplicate = targetList.contains { $0.host == proxy.host && $0.port == proxy.port && $0.username == proxy.username }
                if isDuplicate {
                    duplicates += 1
                } else {
                    appendProxy(proxy, for: target)
                    added += 1
                }
            } else {
                failed.append(line)
            }
        }

        if added > 0 { persist(for: target) }
        return ProxyRotationService.ImportReport(added: added, duplicates: duplicates, failed: failed)
    }

    func markWorking(_ proxy: ProxyConfig) {
        for target: ProxyRotationService.ProxyTarget in [.joe, .ignition, .ppsr] {
            if let idx = indexOfProxy(proxy, in: target) {
                updateProxy(at: idx, for: target) { p in
                    p.isWorking = true
                    p.lastTested = Date()
                    p.failCount = 0
                }
                persist(for: target)
            }
        }
    }

    func markFailed(_ proxy: ProxyConfig) {
        for target: ProxyRotationService.ProxyTarget in [.joe, .ignition, .ppsr] {
            if let idx = indexOfProxy(proxy, in: target) {
                updateProxy(at: idx, for: target) { p in
                    p.failCount += 1
                    p.lastTested = Date()
                    if p.failCount >= 3 { p.isWorking = false }
                }
                persist(for: target)
            }
        }
    }

    func removeProxy(_ proxy: ProxyConfig, target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeProxies.removeAll { $0.id == proxy.id }
        case .ignition: ignitionProxies.removeAll { $0.id == proxy.id }
        case .ppsr: ppsrProxies.removeAll { $0.id == proxy.id }
        }
        persist(for: target)
    }

    func removeAll(target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeProxies.removeAll(); currentJoeIndex = 0
        case .ignition: ignitionProxies.removeAll(); currentIgnitionIndex = 0
        case .ppsr: ppsrProxies.removeAll(); currentPPSRIndex = 0
        }
        persist(for: target)
    }

    func removeDead(target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
        case .ignition: ignitionProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
        case .ppsr: ppsrProxies.removeAll { !$0.isWorking && $0.lastTested != nil }
        }
        persist(for: target)
    }

    func resetAllStatus(target: ProxyRotationService.ProxyTarget) {
        let count: Int
        switch target {
        case .joe: count = joeProxies.count; for i in joeProxies.indices { joeProxies[i].isWorking = false; joeProxies[i].lastTested = nil; joeProxies[i].failCount = 0 }
        case .ignition: count = ignitionProxies.count; for i in ignitionProxies.indices { ignitionProxies[i].isWorking = false; ignitionProxies[i].lastTested = nil; ignitionProxies[i].failCount = 0 }
        case .ppsr: count = ppsrProxies.count; for i in ppsrProxies.indices { ppsrProxies[i].isWorking = false; ppsrProxies[i].lastTested = nil; ppsrProxies[i].failCount = 0 }
        }
        _ = count
        persist(for: target)
    }

    func syncAcrossTargets() {
        ignitionProxies = joeProxies
        ppsrProxies = joeProxies
        persist(for: .ignition)
        persist(for: .ppsr)
        logger.log("SOCKS5ProxyManager: synced \(joeProxies.count) proxies across all targets", category: .proxy, level: .info)
    }

    func exportProxies(target: ProxyRotationService.ProxyTarget) -> String {
        proxies(for: target).map { proxy in
            if let u = proxy.username, let p = proxy.password {
                return "socks5://\(u):\(p)@\(proxy.host):\(proxy.port)"
            } else {
                return "socks5://\(proxy.host):\(proxy.port)"
            }
        }.joined(separator: "\n")
    }

    func applyTestResult(proxyId: UUID, working: Bool, target: ProxyRotationService.ProxyTarget) {
        if let idx = indexOfProxyById(proxyId, in: target) {
            updateProxy(at: idx, for: target) { p in
                p.isWorking = working
                p.lastTested = Date()
                if working { p.failCount = 0 } else { p.failCount += 1 }
            }
        }
    }

    func persistAll() {
        persist(for: .joe)
        persist(for: .ignition)
        persist(for: .ppsr)
    }

    func resetRotationIndexes() {
        currentJoeIndex = 0
        currentIgnitionIndex = 0
        currentPPSRIndex = 0
    }

    nonisolated func testSingleProxy(_ proxy: ProxyConfig) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        var proxyDict: [String: Any] = ["SOCKSEnable": 1, "SOCKSProxy": proxy.host, "SOCKSPort": proxy.port]
        if let u = proxy.username { proxyDict["SOCKSUser"] = u }
        if let p = proxy.password { proxyDict["SOCKSPassword"] = p }
        config.connectionProxyDictionary = proxyDict
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let testURLs = ["https://api.ipify.org?format=json", "https://httpbin.org/ip", "https://ifconfig.me/ip"]
        for urlString in testURLs {
            guard let url = URL(string: urlString) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty { return true }
            } catch { continue }
        }
        return false
    }

    // MARK: - Private

    private func indexFor(_ target: ProxyRotationService.ProxyTarget) -> Int {
        switch target {
        case .joe: currentJoeIndex
        case .ignition: currentIgnitionIndex
        case .ppsr: currentPPSRIndex
        }
    }

    private func incrementIndex(for target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: currentJoeIndex += 1
        case .ignition: currentIgnitionIndex += 1
        case .ppsr: currentPPSRIndex += 1
        }
    }

    private func appendProxy(_ proxy: ProxyConfig, for target: ProxyRotationService.ProxyTarget) {
        switch target {
        case .joe: joeProxies.append(proxy)
        case .ignition: ignitionProxies.append(proxy)
        case .ppsr: ppsrProxies.append(proxy)
        }
    }

    private func indexOfProxy(_ proxy: ProxyConfig, in target: ProxyRotationService.ProxyTarget) -> Int? {
        proxies(for: target).firstIndex(where: { $0.id == proxy.id })
    }

    private func indexOfProxyById(_ id: UUID, in target: ProxyRotationService.ProxyTarget) -> Int? {
        proxies(for: target).firstIndex(where: { $0.id == id })
    }

    private func updateProxy(at index: Int, for target: ProxyRotationService.ProxyTarget, update: (inout ProxyConfig) -> Void) {
        switch target {
        case .joe: update(&joeProxies[index])
        case .ignition: update(&ignitionProxies[index])
        case .ppsr: update(&ppsrProxies[index])
        }
    }

    func persist(for target: ProxyRotationService.ProxyTarget) {
        let key: String
        let list: [ProxyConfig]
        switch target {
        case .joe: key = joePersistKey; list = joeProxies
        case .ignition: key = ignitionPersistKey; list = ignitionProxies
        case .ppsr: key = ppsrPersistKey; list = ppsrProxies
        }
        let encoded = list.map { p -> [String: Any] in
            var dict: [String: Any] = ["id": p.id.uuidString, "host": p.host, "port": p.port, "isWorking": p.isWorking, "failCount": p.failCount]
            if let u = p.username { dict["username"] = u }
            if let pw = p.password { dict["password"] = pw }
            if let d = p.lastTested { dict["lastTested"] = d.timeIntervalSince1970 }
            return dict
        }
        if let data = try? JSONSerialization.data(withJSONObject: encoded) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadProxyList(key: String) -> [ProxyConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String, let port = dict["port"] as? Int else { return nil }
            let restoredID: UUID
            if let idString = dict["id"] as? String, let parsed = UUID(uuidString: idString) { restoredID = parsed } else { restoredID = UUID() }
            var proxy = ProxyConfig(id: restoredID, host: host, port: port, username: dict["username"] as? String, password: dict["password"] as? String)
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            proxy.failCount = dict["failCount"] as? Int ?? 0
            if let ts = dict["lastTested"] as? TimeInterval { proxy.lastTested = Date(timeIntervalSince1970: ts) }
            return proxy
        }
    }

    private func expandProxyLines(_ text: String) -> [String] {
        let rawLines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var expandedLines: [String] = []
        for line in rawLines {
            if line.contains("\t") { expandedLines.append(contentsOf: line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
            else if line.contains(" ") && !line.contains("://") { expandedLines.append(contentsOf: line.components(separatedBy: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
            else { expandedLines.append(line) }
        }
        return expandedLines
    }

    private func parseProxyLine(_ raw: String) -> ProxyConfig? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let schemePatterns = ["socks5h://", "socks5://", "socks4://", "socks://", "http://", "https://"]
        for scheme in schemePatterns {
            if line.lowercased().hasPrefix(scheme) { line = String(line.dropFirst(scheme.count)); break }
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !line.isEmpty else { return nil }
        var username: String?; var password: String?; var hostPort: String
        if let atIndex = line.lastIndex(of: "@") {
            let authPart = String(line[line.startIndex..<atIndex])
            hostPort = String(line[line.index(after: atIndex)...])
            if let colonIdx = authPart.firstIndex(of: ":") {
                username = String(authPart[authPart.startIndex..<colonIdx])
                password = String(authPart[authPart.index(after: colonIdx)...])
            } else { username = authPart }
        } else {
            let colonCount = line.filter({ $0 == ":" }).count
            if colonCount >= 3 {
                let parts = line.components(separatedBy: ":")
                if parts.count == 4, let _ = Int(parts[3]) { username = parts[0]; password = parts[1]; hostPort = "\(parts[2]):\(parts[3])" }
                else if parts.count == 4, let _ = Int(parts[1]) { hostPort = "\(parts[0]):\(parts[1])"; username = parts[2]; password = parts[3] }
                else { hostPort = line }
            } else { hostPort = line }
        }
        hostPort = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !hostPort.isEmpty else { return nil }
        let hpParts = hostPort.components(separatedBy: ":")
        guard hpParts.count >= 2 else { return nil }
        let portString = hpParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
        let host = hpParts.dropLast().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        if let u = username, u.isEmpty { username = nil }
        if let p = password, p.isEmpty { password = nil }
        return ProxyConfig(host: host, port: port, username: username, password: password)
    }

    private func migrateFromV1() {
        let v1Key = "saved_socks5_proxies_v1"
        guard let data = UserDefaults.standard.data(forKey: v1Key),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        joeProxies = array.compactMap { dict -> ProxyConfig? in
            guard let host = dict["host"] as? String, let port = dict["port"] as? Int else { return nil }
            var proxy = ProxyConfig(host: host, port: port, username: dict["username"] as? String, password: dict["password"] as? String)
            proxy.isWorking = dict["isWorking"] as? Bool ?? false
            if let ts = dict["lastTested"] as? TimeInterval { proxy.lastTested = Date(timeIntervalSince1970: ts) }
            return proxy
        }
        if !joeProxies.isEmpty { persist(for: .joe); UserDefaults.standard.removeObject(forKey: v1Key) }
    }
}
