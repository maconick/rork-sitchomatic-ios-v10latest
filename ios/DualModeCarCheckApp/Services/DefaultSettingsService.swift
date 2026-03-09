import Foundation

@MainActor
class DefaultSettingsService {
    static let shared = DefaultSettingsService()
    private let appliedKey = "default_settings_applied_v2"

    var hasAppliedDefaults: Bool {
        UserDefaults.standard.bool(forKey: appliedKey)
    }

    func applyDefaultsIfNeeded() {
        guard !hasAppliedDefaults else { return }

        let urlService = LoginURLRotationService.shared
        let proxyService = ProxyRotationService.shared
        let blacklistService = BlacklistService.shared

        let disabledJoeURLs: Set<String> = [
            "https://static.joefortune.com/login",
            "https://static.joefortune.eu/login",
            "https://static.joefortune.club/login",
            "https://static.joefortune.eu.com/login",
            "https://static.joefortune.fun/login",
            "https://static.joefortune.lv/login",
            "https://static.joefortune.ooo/login",
            "https://joefortune24.com/login",
            "https://static.joefortuneonlinepokies.com/login",
            "https://static.joefortuneonlinepokies.eu/login",
            "https://static.joefortuneonlinepokies.net/login",
            "https://static.joefortunepokies.com/login",
            "https://static.joefortunepokies.eu/login",
            "https://static.joefortunepokies.net/login",
        ]

        for url in urlService.joeURLs {
            if disabledJoeURLs.contains(url.urlString) {
                urlService.toggleURL(id: url.id, enabled: false)
            }
        }

        proxyService.setConnectionMode(.wireguard, for: .joe)
        proxyService.setConnectionMode(.wireguard, for: .ignition)
        proxyService.setConnectionMode(.dns, for: .ppsr)

        // IMPORTANT: These are default/example WireGuard configs bundled for first-run convenience.
    // Keys and endpoints below are placeholder values that ship in the binary.
    let defaultWGConfigs: [(fileName: String, rawContent: String)] = [
            ("au645.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 103.137.14.171:51820\nPersistentKeepalive = 25"),
            ("au765.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 103.137.15.43:51820\nPersistentKeepalive = 25"),
            ("au833.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 94.156.206.3:51820\nPersistentKeepalive = 25"),
            ("au844.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 94.156.206.25:51820\nPersistentKeepalive = 25"),
            ("au690.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 103.137.15.27:51820\nPersistentKeepalive = 25"),
            ("au835.nordvpn.com", "[Interface]\nPrivateKey = VNGYDvHtqrtvTreejavzR19/bvMVwTlTPOfEt1xew94=\nAddress = 10.5.0.2/32\nDNS = 103.86.96.100, 103.86.99.100\n\n[Peer]\nPublicKey = f+xo9hOjVEkHVkGJowuRGU5UEESXCpiI3wYCQZPSils=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 94.156.206.7:51820\nPersistentKeepalive = 25"),
        ]

        var wgConfigs: [WireGuardConfig] = []
        for wg in defaultWGConfigs {
            if let config = WireGuardConfig.parse(fileName: wg.fileName, content: wg.rawContent) {
                wgConfigs.append(config)
            }
        }
        if !wgConfigs.isEmpty {
            for config in wgConfigs {
                proxyService.importWGConfig(config, for: .joe)
            }
        }

        blacklistService.autoExcludeBlacklist = true
        blacklistService.autoBlacklistNoAcc = true

        UserDefaults.standard.set(true, forKey: appliedKey)
    }
}
