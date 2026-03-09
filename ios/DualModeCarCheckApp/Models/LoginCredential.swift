import Foundation
import Observation

nonisolated enum CredentialStatus: String, Sendable, Codable, CaseIterable {
    case untested = "Untested"
    case testing = "Testing"
    case working = "Working"
    case noAcc = "No Acc"
    case permDisabled = "Perm Disabled"
    case tempDisabled = "Temp Disabled"
    case unsure = "Unsure"
}

@Observable
class LoginCredential: Identifiable {
    private(set) var id: String
    let username: String
    let password: String
    var status: CredentialStatus
    var addedAt: Date
    var notes: String
    var testResults: [LoginTestResult]
    var assignedPasswords: [String] = []
    var nextPasswordIndex: Int = 0
    var lastTempDisabledCheck: Date?

    var displayStatus: String { status.rawValue }
    var isWorking: Bool { status == .working }
    var totalTests: Int { testResults.count }
    var successCount: Int { testResults.filter { $0.success }.count }
    var failureCount: Int { testResults.filter { !$0.success }.count }

    var successRate: Double {
        guard totalTests > 0 else { return 0 }
        return Double(successCount) / Double(totalTests)
    }

    var lastTestedAt: Date? { testResults.first?.timestamp }
    var lastTestSuccess: Bool? { testResults.first?.success }

    var maskedPassword: String {
        String(repeating: "•", count: min(password.count, 12))
    }

    var exportFormat: String {
        "\(username):\(password)"
    }

    var untestedPasswordCount: Int {
        max(0, assignedPasswords.count - nextPasswordIndex)
    }

    init(username: String, password: String) {
        self.id = UUID().uuidString
        self.username = username
        self.password = password
        self.status = .untested
        self.addedAt = Date()
        self.notes = ""
        self.testResults = []
    }

    func overrideId(_ newId: String) { id = newId }
    func overrideAddedAt(_ date: Date) { addedAt = date }

    func recordResult(success: Bool, duration: TimeInterval, error: String? = nil, detail: String? = nil) {
        let result = LoginTestResult(success: success, duration: duration, errorMessage: error, responseDetail: detail)
        testResults.insert(result, at: 0)
        if success {
            status = .working
        } else if detail?.lowercased().contains("perm disabled") == true || detail?.lowercased().contains("permanently") == true || detail?.lowercased().contains("blacklist") == true {
            status = .permDisabled
        } else if detail?.lowercased().contains("temp disabled") == true || detail?.lowercased().contains("temporarily") == true {
            status = .tempDisabled
        } else if detail?.lowercased().contains("no account") == true || detail?.lowercased().contains("incorrect") == true {
            status = .noAcc
        } else {
            status = .unsure
        }
    }

    func getNextPasswordBatch(count: Int = 3) -> [String] {
        guard nextPasswordIndex < assignedPasswords.count else { return [] }
        let end = min(nextPasswordIndex + count, assignedPasswords.count)
        let batch = Array(assignedPasswords[nextPasswordIndex..<end])
        return batch
    }

    func advancePasswordIndex(by count: Int) {
        nextPasswordIndex = min(nextPasswordIndex + count, assignedPasswords.count)
    }

    static func smartParse(_ input: String) -> [LoginCredential] {
        let lines = input.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.compactMap { parseLine($0) }
    }

    static func parseLine(_ line: String) -> LoginCredential? {
        let separators: [String] = [":", "|", ";", ",", "\t"]
        for sep in separators {
            let parts = line.components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                let username = parts[0]
                let password = parts[1]
                guard !username.isEmpty, !password.isEmpty else { continue }
                guard username.count >= 3 else { continue }
                return LoginCredential(username: username, password: password)
            }
        }
        return nil
    }
}
