import SwiftUI

nonisolated enum ProductMode: String, CaseIterable, Sendable {
    case ppsr = "PPSR CarCheck"
    case joe = "Joe Fortune"
    case ignition = "Ignition Casino"
    case dual = "Dual Mode"

    var title: String { rawValue }

    var isLoginMode: Bool {
        switch self {
        case .joe, .ignition, .dual: return true
        case .ppsr: return false
        }
    }

    var baseURL: String {
        switch self {
        case .ppsr: return "https://transact.ppsr.gov.au/CarCheck/"
        case .joe: return "https://joefortune24.com/login"
        case .ignition: return "https://static.ignitioncasino.lat/?overlay=login"
        case .dual: return "https://joefortune24.com/login"
        }
    }
}
