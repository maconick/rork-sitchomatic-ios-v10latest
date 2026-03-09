import Foundation

nonisolated struct NordLynxAccessKey: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let key: String
    let isPreset: Bool

    static let nick = NordLynxAccessKey(
        id: "nick",
        name: "Nick",
        key: "68b9f594ef76d1ec4ef82eb3e0c0a93dfe0ad4bd091a38965218d1f23340c78d",
        isPreset: true
    )

    static let poli = NordLynxAccessKey(
        id: "poli",
        name: "Poli",
        key: "e9f2ab075820d8ccc3362eadc4bbadb335571961002b5d5d606cbe4083680625",
        isPreset: true
    )

    static let presets: [NordLynxAccessKey] = [.nick, .poli]
}
