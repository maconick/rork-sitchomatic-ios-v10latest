import Foundation

nonisolated struct DoHProvider: Sendable {
    let name: String
    let url: String
}

nonisolated struct DNSAnswer: Sendable {
    let ip: String
    let provider: String
    let latencyMs: Int
}

nonisolated struct DoHResponse: Codable, Sendable {
    let Status: Int?
    let Answer: [DoHAnswerEntry]?
}

nonisolated struct DoHAnswerEntry: Codable, Sendable {
    let name: String?
    let type: Int?
    let TTL: Int?
    let data: String?
}

struct ManagedDoHProvider: Identifiable {
    let id: UUID = UUID()
    let name: String
    let url: String
    var isEnabled: Bool
    let isDefault: Bool
}

@MainActor
class PPSRDoHService {
    static let shared = PPSRDoHService()

    private var providerIndex: Int = 0
    private let persistKey = "doh_managed_providers_v1"
    private let logger = DebugLogger.shared

    static let defaultProviders: [DoHProvider] = [
        DoHProvider(name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query"),
        DoHProvider(name: "Google", url: "https://dns.google/dns-query"),
        DoHProvider(name: "Quad9", url: "https://dns.quad9.net:5053/dns-query"),
        DoHProvider(name: "OpenDNS", url: "https://doh.opendns.com/dns-query"),
        DoHProvider(name: "Mullvad", url: "https://dns.mullvad.net/dns-query"),
        DoHProvider(name: "AdGuard", url: "https://dns.adguard-dns.com/dns-query"),
        DoHProvider(name: "NextDNS", url: "https://dns.nextdns.io/dns-query"),
        DoHProvider(name: "ControlD", url: "https://freedns.controld.com/p0"),
        DoHProvider(name: "CleanBrowsing", url: "https://doh.cleanbrowsing.org/doh/security-filter/"),
        DoHProvider(name: "DNS.SB", url: "https://doh.dns.sb/dns-query"),
    ]

    var managedProviders: [ManagedDoHProvider] = []

    var providers: [DoHProvider] {
        managedProviders.filter(\.isEnabled).map { DoHProvider(name: $0.name, url: $0.url) }
    }

    init() {
        loadManagedProviders()
    }

    var currentProvider: DoHProvider {
        let active = providers
        guard !active.isEmpty else { return DoHProvider(name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query") }
        return active[providerIndex % active.count]
    }

    func nextProvider() -> DoHProvider {
        let active = providers
        guard !active.isEmpty else { return DoHProvider(name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query") }
        let provider = active[providerIndex % active.count]
        providerIndex += 1
        return provider
    }

    func resolveWithRotation(hostname: String) async -> DNSAnswer? {
        for attempt in 0..<3 {
            let provider = nextProvider()
            if let answer = await resolve(hostname: hostname, using: provider) {
                if attempt > 0 {
                    logger.logHealing(category: .dns, originalError: "Previous DoH providers failed", healingAction: "Resolved via \(provider.name) on attempt #\(attempt + 1)", succeeded: true, attemptNumber: attempt + 1)
                }
                return answer
            }
            logger.log("DoH: \(provider.name) failed for \(hostname) (attempt \(attempt + 1)/3)", category: .dns, level: .debug)
        }
        logger.log("DoH: all 3 rotation attempts failed for \(hostname)", category: .dns, level: .error)
        return nil
    }

    func resolve(hostname: String, using provider: DoHProvider) async -> DNSAnswer? {
        guard var components = URLComponents(string: provider.url) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "type", value: "A"),
        ]
        guard let url = components.url else { return nil }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.log("DoH: \(provider.name) HTTP \(code) for \(hostname)", category: .dns, level: .debug)
                return nil
            }

            guard !data.isEmpty else {
                logger.log("DoH: \(provider.name) empty response for \(hostname)", category: .dns, level: .debug)
                return nil
            }

            let decoded = try JSONDecoder().decode(DoHResponse.self, from: data)

            guard decoded.Status == 0 || decoded.Status == nil else {
                logger.log("DoH: \(provider.name) DNS status \(decoded.Status ?? -1) for \(hostname)", category: .dns, level: .debug)
                return nil
            }

            guard let answers = decoded.Answer,
                  let aRecord = answers.first(where: { $0.type == 1 }),
                  let ip = aRecord.data,
                  !ip.isEmpty else {
                logger.log("DoH: \(provider.name) no A record for \(hostname)", category: .dns, level: .debug)
                return nil
            }

            return DNSAnswer(ip: ip, provider: provider.name, latencyMs: latency)
        } catch {
            logger.logError("DoH: \(provider.name) error resolving \(hostname)", error: error, category: .dns)
            return nil
        }
    }

    func preflightResolve(hostname: String) async -> (provider: String, ip: String, latencyMs: Int)? {
        for _ in 0..<3 {
            let provider = nextProvider()
            if let answer = await resolve(hostname: hostname, using: provider) {
                return (provider: answer.provider, ip: answer.ip, latencyMs: answer.latencyMs)
            }
        }
        return nil
    }

    var providerCount: Int {
        providers.count
    }

    var allProviderNames: [String] {
        providers.map(\.name)
    }

    func resetRotation() {
        providerIndex = 0
    }

    func toggleProvider(id: UUID, enabled: Bool) {
        if let idx = managedProviders.firstIndex(where: { $0.id == id }) {
            managedProviders[idx].isEnabled = enabled
            persistManagedProviders()
        }
    }

    func addProvider(name: String, url: String) -> Bool {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedName.isEmpty else { return false }
        guard !managedProviders.contains(where: { $0.url == trimmedURL }) else { return false }
        managedProviders.append(ManagedDoHProvider(name: trimmedName, url: trimmedURL, isEnabled: true, isDefault: false))
        persistManagedProviders()
        return true
    }

    func bulkImportProviders(_ text: String) -> (added: Int, duplicates: Int, invalid: Int) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var added = 0
        var duplicates = 0
        var invalid = 0
        for line in lines {
            let parts = line.components(separatedBy: "|")
            let urlStr: String
            let nameStr: String
            if parts.count >= 2 {
                nameStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                urlStr = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                urlStr = line
                nameStr = URL(string: line)?.host ?? "Custom"
            }
            guard urlStr.hasPrefix("https://"), URL(string: urlStr) != nil else { invalid += 1; continue }
            if managedProviders.contains(where: { $0.url == urlStr }) {
                duplicates += 1
                continue
            }
            managedProviders.append(ManagedDoHProvider(name: nameStr, url: urlStr, isEnabled: true, isDefault: false))
            added += 1
        }
        if added > 0 { persistManagedProviders() }
        return (added, duplicates, invalid)
    }

    func deleteProvider(id: UUID) {
        managedProviders.removeAll { $0.id == id }
        persistManagedProviders()
    }

    func resetToDefaults() {
        managedProviders = Self.defaultProviders.map {
            ManagedDoHProvider(name: $0.name, url: $0.url, isEnabled: true, isDefault: true)
        }
        persistManagedProviders()
    }

    func enableAll() {
        for i in managedProviders.indices {
            managedProviders[i].isEnabled = true
        }
        persistManagedProviders()
    }

    private func persistManagedProviders() {
        let data = managedProviders.map { ["name": $0.name, "url": $0.url, "enabled": $0.isEnabled ? "1" : "0", "default": $0.isDefault ? "1" : "0"] }
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    private func loadManagedProviders() {
        if let saved = UserDefaults.standard.array(forKey: persistKey) as? [[String: String]] {
            managedProviders = saved.map {
                ManagedDoHProvider(
                    name: $0["name"] ?? "Unknown",
                    url: $0["url"] ?? "",
                    isEnabled: $0["enabled"] == "1",
                    isDefault: $0["default"] == "1"
                )
            }
        } else {
            managedProviders = Self.defaultProviders.map {
                ManagedDoHProvider(name: $0.name, url: $0.url, isEnabled: true, isDefault: true)
            }
        }
    }
}
