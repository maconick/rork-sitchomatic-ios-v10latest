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
            "https://static.joefortune.eu/login",
            "https://static.joefortune.club/login",
            "https://static.joefortune.eu.com/login",
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
        proxyService.setConnectionMode(.wireguard, for: .ppsr)
        proxyService.setUnifiedConnectionMode(.wireguard)

        let deviceProxy = DeviceProxyService.shared
        deviceProxy.ipRoutingMode = .appWideUnited
        deviceProxy.rotationInterval = .everyBatch
        deviceProxy.rotateOnBatchStart = false
        deviceProxy.localProxyEnabled = true

        blacklistService.autoExcludeBlacklist = true
        blacklistService.autoBlacklistNoAcc = true

        UserDefaults.standard.set(true, forKey: appliedKey)
    }
}
