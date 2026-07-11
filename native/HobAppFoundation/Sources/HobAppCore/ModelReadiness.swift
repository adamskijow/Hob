// SPDX-License-Identifier: MIT
import Foundation

public enum ModelReadinessState: String, Codable, Equatable, Sendable {
    case notChecked
    case checking
    case available
    case unavailable
    case toolMissing
    case timedOut
    case invalidResponse

    public var isReady: Bool { self == .available }

    public var title: String {
        switch self {
        case .notChecked: return "Not checked"
        case .checking: return "Checking"
        case .available: return "Ready"
        case .unavailable: return "Unavailable"
        case .toolMissing: return "Model tool missing"
        case .timedOut: return "Check timed out"
        case .invalidResponse: return "Check failed"
        }
    }

    public var guidance: String {
        switch self {
        case .notChecked:
            return "Check the on-device model before relying on Hob."
        case .checking:
            return "Hob is asking Apple's on-device model for a harmless readiness response."
        case .available:
            return "Apple Intelligence completed a real on-device generation."
        case .unavailable:
            return "Turn on Apple Intelligence and allow its model assets to finish downloading, then check again."
        case .toolMissing:
            return "This build is missing Hob's signed on-device model tool."
        case .timedOut:
            return "The model did not respond within 30 seconds. Check again before finishing setup."
        case .invalidResponse:
            return "The model tool returned an invalid readiness response. Update or reinstall Hob before relying on it."
        }
    }
}
