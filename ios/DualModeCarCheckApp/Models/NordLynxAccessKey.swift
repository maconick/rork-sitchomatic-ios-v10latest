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
        key: "e9f2ab92d0403a4715baf19e67d70b5ebc2b860c4f17bb5396085bb10dedf579",
        isPreset: true
    )

    static let presets: [NordLynxAccessKey] = [.nick, .poli]
}
