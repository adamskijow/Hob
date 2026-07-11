// SPDX-License-Identifier: MIT
import Foundation

public enum BackgroundServiceState: String, Codable, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    public var isApproved: Bool { self == .enabled }

    public var title: String {
        switch self {
        case .notRegistered: return "Off"
        case .enabled: return "On"
        case .requiresApproval: return "Needs approval"
        case .notFound: return "Helper unavailable"
        case .unknown: return "Status unavailable"
        }
    }

    public var guidance: String {
        switch self {
        case .notRegistered:
            return "Hob will not run after you close the app."
        case .enabled:
            return "Hob can deliver approved digests, reminders, and plan nudges while the app is closed."
        case .requiresApproval:
            return "Approve Hob in System Settings under Login Items to finish enabling background delivery."
        case .notFound:
            return "This build does not contain the signed Hob background helper."
        case .unknown:
            return "Hob could not determine the background service state. Try again before relying on reminders."
        }
    }
}

public struct AgentHealth: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let state: String
    public let updatedAt: Date

    public init(protocolVersion: Int = 1, state: String, updatedAt: Date) {
        self.protocolVersion = protocolVersion
        self.state = state
        self.updatedAt = updatedAt
    }
}
