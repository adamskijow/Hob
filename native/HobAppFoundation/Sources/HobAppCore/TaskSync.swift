// SPDX-License-Identifier: MIT
import Foundation

public struct RuntimeTaskOperation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let occurredAt: String
    public let sequence: Int
    public let task: RuntimeTask?

    public init(
        id: String,
        taskID: String,
        occurredAt: String,
        sequence: Int = 0,
        task: RuntimeTask?
    ) {
        self.id = id
        self.taskID = taskID
        self.occurredAt = occurredAt
        self.sequence = sequence
        self.task = task
    }

    public var isValid: Bool {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id == cleanID
            && !id.isEmpty
            && id.utf8.count <= 300
            && taskID == cleanTaskID
            && !taskID.isEmpty
            && taskID.utf8.count <= 128
            && sequence >= 0
            && ISO8601DateFormatter().date(from: occurredAt) != nil
            && (task.map { validTask($0) && $0.id == taskID
                && $0.updatedAt == occurredAt } ?? true)
    }

    private func validTask(_ value: RuntimeTask) -> Bool {
        !value.rawText.isEmpty
            && value.rawText.utf8.count <= 20_000
            && !value.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.task.utf8.count <= 10_000
            && ["open", "done", "dropped"].contains(value.status)
            && ISO8601DateFormatter().date(from: value.createdAt) != nil
            && validDate(value.dueDate)
            && validTime(value.dueTime)
            && validDate(value.deadlineDate)
            && (value.durationMinutes.map { (5...480).contains($0) } ?? true)
            && (value.priority.map { ["high", "normal", "low"].contains($0) }
                ?? true)
            && (value.sourceArchive.map { $0.utf8.count <= 20_000 } ?? true)
            && (value.dueDate == nil || value.deadlineDate == nil
                || value.dueDate! <= value.deadlineDate!)
    }

    private func validDate(_ value: String?) -> Bool {
        guard let value else { return true }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value }
            == true
    }

    private func validTime(_ value: String?) -> Bool {
        guard let value else { return true }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2
            && parts[0].count == 2
            && parts[1].count == 2
            && Int(parts[0]).map { (0...23).contains($0) } == true
            && Int(parts[1]).map { (0...59).contains($0) } == true
    }
}

public enum RuntimeTaskSyncAvailability: String, Codable, Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case unavailable
}

public enum RuntimeTaskSyncError: Error, Equatable, Sendable {
    case accountUnavailable
    case invalidRemoteData
    case conflict
    case transportFailed
}

@MainActor
public protocol RuntimeTaskSyncing: AnyObject {
    var availability: RuntimeTaskSyncAvailability { get }

    func refreshAvailability() async -> RuntimeTaskSyncAvailability
    func exchange(
        localOperations: [RuntimeTaskOperation]
    ) async throws -> [RuntimeTaskOperation]
}

public enum RuntimeTaskOperationMerge {
    public static func merge(
        local: [RuntimeTaskOperation],
        remote: [RuntimeTaskOperation]
    ) throws -> [RuntimeTaskOperation] {
        var byID: [String: RuntimeTaskOperation] = [:]
        for operation in local + remote {
            guard operation.isValid else {
                throw RuntimeTaskSyncError.invalidRemoteData
            }
            if let existing = byID[operation.id], existing != operation {
                throw RuntimeTaskSyncError.conflict
            }
            byID[operation.id] = operation
        }
        return byID.values.sorted(by: order)
    }

    public static func tasks(
        from operations: [RuntimeTaskOperation]
    ) throws -> [RuntimeTask] {
        let merged = try merge(local: operations, remote: [])
        var latest: [String: RuntimeTaskOperation] = [:]
        for operation in merged {
            if let current = latest[operation.taskID],
               !order(current, operation) {
                continue
            }
            latest[operation.taskID] = operation
        }
        return latest.values.compactMap(\.task).sorted { $0.id < $1.id }
    }

    private static func order(
        _ lhs: RuntimeTaskOperation,
        _ rhs: RuntimeTaskOperation
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt < rhs.occurredAt
        }
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.id < rhs.id
    }
}
