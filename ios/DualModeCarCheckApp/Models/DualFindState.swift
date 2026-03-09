import Foundation

nonisolated struct DualFindResumePoint: Codable, Sendable {
    let emailIndex: Int
    let passwordIndex: Int
    let emails: [String]
    let passwords: [String]
    let sessionCount: Int
    let timestamp: Date
    let disabledEmails: [String]
    let foundLogins: [DualFindHit]
}

nonisolated struct DualFindHit: Codable, Sendable, Identifiable {
    let id: String
    let email: String
    let password: String
    let platform: String
    let timestamp: Date

    init(email: String, password: String, platform: String) {
        self.id = UUID().uuidString
        self.email = email
        self.password = password
        self.platform = platform
        self.timestamp = Date()
    }
}

nonisolated struct DualFindSessionInfo: Identifiable, Sendable {
    let id: String
    let index: Int
    let platform: String
    var currentEmail: String
    var status: String
    var isActive: Bool

    init(index: Int, platform: String) {
        self.id = "\(platform)_\(index)"
        self.index = index
        self.platform = platform
        self.currentEmail = ""
        self.status = "Idle"
        self.isActive = false
    }
}

nonisolated enum DualFindSessionCount: Int, CaseIterable, Sendable {
    case four = 4
    case six = 6

    var label: String {
        switch self {
        case .four: "4 Sessions (2+2)"
        case .six: "6 Sessions (3+3)"
        }
    }

    var perSite: Int {
        switch self {
        case .four: 2
        case .six: 3
        }
    }
}
