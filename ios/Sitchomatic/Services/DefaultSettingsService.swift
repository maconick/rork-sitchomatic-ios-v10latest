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

        urlService.enableAllURLs()

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
