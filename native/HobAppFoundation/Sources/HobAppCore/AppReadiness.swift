// SPDX-License-Identifier: MIT
import Foundation

public enum DistributionEdition: String, Codable, Sendable {
    case appStore
    case openLocal
}

public enum ModelBackend: String, Codable, Sendable {
    case appleFoundationModels
    case ollama
}

public struct AppReadiness: Equatable, Sendable {
    public let edition: DistributionEdition
    public let modelBackend: ModelBackend
    public let ownerPaired: Bool
    public let backgroundServiceApproved: Bool
    public let modelAvailable: Bool
    public let storageAvailable: Bool

    public init(
        edition: DistributionEdition,
        modelBackend: ModelBackend,
        ownerPaired: Bool,
        backgroundServiceApproved: Bool,
        modelAvailable: Bool,
        storageAvailable: Bool = true
    ) {
        self.edition = edition
        self.modelBackend = modelBackend
        self.ownerPaired = ownerPaired
        self.backgroundServiceApproved = backgroundServiceApproved
        self.modelAvailable = modelAvailable
        self.storageAvailable = storageAvailable
    }

    public var blockers: [ReadinessBlocker] {
        var result: [ReadinessBlocker] = []
        if edition == .appStore && modelBackend != .appleFoundationModels {
            result.append(.unsupportedModelBackend)
        }
        if !modelAvailable {
            result.append(.modelUnavailable)
        }
        if !ownerPaired {
            result.append(.ownerNotPaired)
        }
        if !storageAvailable {
            result.append(.taskStorageUnavailable)
        }
        if !backgroundServiceApproved {
            result.append(.backgroundServiceNotApproved)
        }
        return result
    }

    public var canRun: Bool { blockers.isEmpty }
}

public enum ReadinessBlocker: String, Equatable, Sendable {
    case unsupportedModelBackend
    case modelUnavailable
    case ownerNotPaired
    case taskStorageUnavailable
    case backgroundServiceNotApproved

    public var userMessage: String {
        switch self {
        case .unsupportedModelBackend:
            return "The App Store edition uses Apple's on-device model."
        case .modelUnavailable:
            return "Turn on Apple Intelligence to use Hob's on-device understanding."
        case .ownerNotPaired:
            return "Connect the private Telegram chat Hob should answer."
        case .taskStorageUnavailable:
            return "Resolve local task storage before relying on Hob."
        case .backgroundServiceNotApproved:
            return "Allow Hob to run in the background so reminders arrive reliably."
        }
    }
}

public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome
    case model
    case telegram
    case schedule
    case calendar
    case backgroundService
    case ready

    public var title: String {
        switch self {
        case .welcome: return "Meet Hob"
        case .model: return "Private intelligence"
        case .telegram: return "Connect Telegram"
        case .schedule: return "Set your working rhythm"
        case .calendar: return "Protect busy time"
        case .backgroundService: return "Deliver reliably"
        case .ready: return "Ready for tomorrow"
        }
    }
}
