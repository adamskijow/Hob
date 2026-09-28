// SPDX-License-Identifier: MIT
import Foundation

/// Product behavior, not parser examples. New interactive surfaces must declare
/// an entry here and acquire contract coverage before passing the release gate.
public enum RuntimeInteraction: String, CaseIterable, Codable, Sendable {
    case taskReview, chooseTask, chooseDate, longRangeApproval, eveningRecap
    case reminderDone, reminderSnooze, reminderReplan, taskEdit, scheduleApproval
    case freeform, setupRecovery

    public var offeredReplies: [String] {
        switch self {
        case .taskReview: return ["stays", "moves", "drop"]
        case .chooseTask: return ["a task name", "cancel"]
        case .chooseDate: return ["a date", "cancel"]
        case .longRangeApproval: return ["Yes", "Cancel"]
        case .eveningRecap: return ["done", "nothing", "a new task"]
        case .reminderDone: return ["Done"]
        case .reminderSnooze: return ["Snooze"]
        case .reminderReplan: return ["what changed"]
        case .taskEdit: return ["Close to save", "Swipe down to save", "Mark done"]
        case .scheduleApproval: return ["Adopt", "Dismiss"]
        case .freeform: return ["task", "change", "question", "conversation"]
        case .setupRecovery: return ["Back", "Close", "Start using Hob"]
        }
    }

    public static func reviewText(task: String, days: Int) -> String {
        "“\(task)” has been on deck \(days) days. Tell Hob naturally whether it stays, moves, or gets dropped."
    }
    public static let dateQuestion = "Which day should I use?"
    public static let moveDateQuestion = "When should I move it to?"
    public static let taskQuestion = "Which task do you mean?"
}

public struct RuntimeQuestionRequest: Equatable, Sendable {
    public let kind: RuntimeInteraction
    public let text: String
    public let taskIDs: [String]
    public init(kind: RuntimeInteraction, text: String, taskIDs: [String] = []) {
        self.kind = kind
        self.text = text
        self.taskIDs = taskIDs
    }
}

/// The exact question presented, including its task revisions and local day.
/// Never silently retarget a pending answer when the underlying tasks change.
public struct RuntimePendingQuestion: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: RuntimeInteraction
    public let text: String
    public let originalMessage: String
    public let taskIDs: [String]
    public let taskRevisions: [RuntimeTask]
    public let day: String
    public let timezone: String

    public init(
        kind: RuntimeInteraction, text: String, originalMessage: String = "",
        taskIDs: [String], tasks: [RuntimeTask], day: String, timezone: String
    ) {
        id = UUID()
        self.kind = kind
        self.text = text
        self.originalMessage = String(originalMessage.prefix(2_000))
        self.taskIDs = taskIDs
        self.day = day
        self.timezone = timezone
        taskRevisions = tasks.filter { taskIDs.contains($0.id) }
    }
    public func isValid(tasks: [RuntimeTask], day: String, timezone: String) -> Bool {
        self.day == day && self.timezone == timezone
            && taskRevisions.count == taskIDs.count
            && taskRevisions.allSatisfy { old in tasks.contains(old) && old.status == "open" }
    }
}

public struct RuntimeConversationState: Codable, Equatable, Sendable {
    public var pending: RuntimePendingQuestion?
    public var recent: RuntimePendingQuestion?
    public init(pending: RuntimePendingQuestion? = nil, recent: RuntimePendingQuestion? = nil) {
        self.pending = pending
        self.recent = recent
    }
    public mutating func validate(tasks: [RuntimeTask], day: String, timezone: String) {
        if pending?.isValid(tasks: tasks, day: day, timezone: timezone) == false { pending = nil }
        if recent?.isValid(tasks: tasks, day: day, timezone: timezone) == false { recent = nil }
    }
}
