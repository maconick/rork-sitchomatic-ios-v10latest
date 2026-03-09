import Foundation

nonisolated let kDefaultNickKey = "68b9f594ef76d1ec4ef82eb3e0c0a93dfe0ad4bd091a38965218d1f23340c78d"
nonisolated let kDefaultPoliKey = "e9f2ab075820d8ccc3362eadc4bbadb335571961002b5d5d606cbe4083680625"

@MainActor
class NordVPNKeyStore {
    static let shared = NordVPNKeyStore()

    private let nickKeyStorageKey = "nordvpn_nick_access_key_v2"
    private let poliKeyStorageKey = "nordvpn_poli_access_key_v2"

    static let defaultNickKey = kDefaultNickKey
    static let defaultPoliKey = kDefaultPoliKey

    var nickKey: String {
        get { UserDefaults.standard.string(forKey: nickKeyStorageKey) ?? Self.defaultNickKey }
        set { UserDefaults.standard.set(newValue, forKey: nickKeyStorageKey) }
    }

    var poliKey: String {
        get { UserDefaults.standard.string(forKey: poliKeyStorageKey) ?? Self.defaultPoliKey }
        set { UserDefaults.standard.set(newValue, forKey: poliKeyStorageKey) }
    }

    func keyForProfile(_ profile: NordKeyProfile) -> String {
        switch profile {
        case .nick: nickKey
        case .poli: poliKey
        }
    }

    func updateKey(_ key: String, for profile: NordKeyProfile) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch profile {
        case .nick: nickKey = trimmed
        case .poli: poliKey = trimmed
        }
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: nickKeyStorageKey)
        UserDefaults.standard.removeObject(forKey: poliKeyStorageKey)
    }
}
