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
    public let taskRevision: String?

    public init(
        id: String,
        action: RuntimeNotificationAction,
        notificationID: String,
        proposalID: String,
        blockID: String,
        taskID: String,
        task: String,
        receivedAt: String,
        taskRevision: String? = nil
    ) {
        self.id = id
        self.action = action
        self.notificationID = notificationID
        self.proposalID = proposalID
        self.blockID = blockID
        self.taskID = taskID
        self.task = task
        self.receivedAt = receivedAt
        self.taskRevision = taskRevision
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
            && (taskRevision.map(RuntimeTask.isValidRevision) ?? true)
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

/// The current task state is the source of truth for notifications. Explicit
/// times do not depend on work hours, Calendar availability, or plan adoption.
public struct RuntimeTaskReminder: Equatable, Sendable {
    public let identifier: String
    public let taskID: String
    public let task: String
    public let revision: String
    public let fireAt: Date
    public let timezone: String
    public let proposalID: String
    public let blockID: String
    public let duration: Int?

    public static func build(tasks: [RuntimeTask], adopted: RuntimeAdoptedSchedule?, timezone: TimeZone) -> [Self] {
        let open = tasks.filter { $0.status == "open" && !$0.isWaiting }
        var result: [Self] = []
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        for task in open {
            if let time = task.dueTime,
                let date = formatter.date(from: "\(task.dueDate ?? String(task.createdAt.prefix(10))) \(time)")
            {
                result.append(
                    Self(
                        identifier: "hob.reminder.\(task.id)", taskID: task.id,
                        task: task.task, revision: task.revision, fireAt: date, timezone: timezone.identifier,
                        proposalID: "reminder", blockID: task.id, duration: task.durationMinutes))
            } else if task.dueTime == nil, let proposal = adopted?.proposal,
                proposal.taskVersions[task.id] == task.revision,
                proposal.plannedUntimedTaskIDs.contains(task.id)
            {
                for block in proposal.blocks where block.taskID == task.id {
                    guard let date = ISO8601DateFormatter().date(from: block.startAt) else { continue }
                    result.append(
                        Self(
                            identifier: "hob.\(proposal.id).\(block.id)", taskID: task.id,
                            task: task.task, revision: task.revision, fireAt: date, timezone: proposal.timezone,
                            proposalID: proposal.id, blockID: block.id, duration: block.durationMinutes))
                }
            }
        }
        return result.sorted { ($0.fireAt, $0.identifier) < ($1.fireAt, $1.identifier) }
    }
}

@MainActor
public protocol RuntimeNotificationScheduling: AnyObject {
    var authorization: RuntimeNotificationAuthorization { get }

    func refreshAuthorization() async -> RuntimeNotificationAuthorization
    func requestAccess() async throws -> RuntimeNotificationAuthorization
    func replaceTaskReminders(_ reminders: [RuntimeTaskReminder], now: Date) async throws
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
    func replaceEveningRecaps(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws
    func cancelEveningRecaps() async
    func snooze(
        response: RuntimeNotificationResponse,
        minutes: Int
    ) async throws
    func cancel(notificationIDs: [String])
    func setActionHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                RuntimeNotificationResponse
            ) async -> Void
    )
}
