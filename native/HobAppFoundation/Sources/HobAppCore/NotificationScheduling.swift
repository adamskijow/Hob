// SPDX-License-Identifier: MIT
import Foundation

public enum RuntimeNotificationAuthorization: String, Codable, Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

public enum RuntimeNotificationAction: String, Codable, Equatable, Sendable {
    case done
    case snooze
    case replan
}

public struct RuntimeNotificationResponse: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let action: RuntimeNotificationAction
    public let notificationID: String
    public let proposalID: String
    public let blockID: String
    public let taskID: String
    public let task: String
    public let receivedAt: String

    public init(
        id: String,
        action: RuntimeNotificationAction,
        notificationID: String,
        proposalID: String,
        blockID: String,
        taskID: String,
        task: String,
        receivedAt: String
    ) {
        self.id = id
        self.action = action
        self.notificationID = notificationID
        self.proposalID = proposalID
        self.blockID = blockID
        self.taskID = taskID
        self.task = task
        self.receivedAt = receivedAt
    }

    public var isValid: Bool {
        validIdentifier(id, maximum: 128)
            && validIdentifier(notificationID, maximum: 512)
            && validIdentifier(proposalID, maximum: 128)
            && validIdentifier(blockID, maximum: 300)
            && validIdentifier(taskID, maximum: 128)
            && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && task.utf8.count <= 10_000
            && ISO8601DateFormatter().date(from: receivedAt) != nil
    }

    private func validIdentifier(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed && !value.isEmpty && value.utf8.count <= maximum
    }
}

public enum RuntimeNotificationError: Error, Equatable, Sendable {
    case permissionDenied
    case invalidRequest
    case schedulingFailed
}

@MainActor
public protocol RuntimeNotificationScheduling: AnyObject {
    var authorization: RuntimeNotificationAuthorization { get }

    func refreshAuthorization() async -> RuntimeNotificationAuthorization
    func requestAccess() async throws -> RuntimeNotificationAuthorization
    func schedule(
        proposal: RuntimeScheduleProposal,
        now: Date
    ) async throws -> [String]
    func replaceMorningDigests(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws
    func cancelMorningDigests() async
    func snooze(
        response: RuntimeNotificationResponse,
        minutes: Int
    ) async throws
    func cancel(notificationIDs: [String])
    func setActionHandler(
        _ handler: @escaping @MainActor @Sendable (
            RuntimeNotificationResponse
        ) async -> Void
    )
}
