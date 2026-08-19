// SPDX-License-Identifier: MIT
import Foundation
import CoreFoundation

public struct OpenLocalImportResult: Equatable, Sendable {
    public let tasks: [RuntimeTask]
    public let preservedDetailCount: Int
    public let sourceSchema: Int

    public init(
        tasks: [RuntimeTask],
        preservedDetailCount: Int,
        sourceSchema: Int
    ) {
        self.tasks = tasks
        self.preservedDetailCount = preservedDetailCount
        self.sourceSchema = sourceSchema
    }
}

public enum OpenLocalImportError: Error, Equatable, Sendable {
    case invalidExport
    case unsupportedVersion
    case destinationNotEmpty
    case tooLarge

    public var userMessage: String {
        switch self {
        case .destinationNotEmpty:
            return "Import works before adding Apple app tasks. Nothing changed."
        case .unsupportedVersion:
            return "Update the Apple app before importing this Open Local export."
        case .tooLarge:
            return "That export is too large to import safely. Nothing changed."
        case .invalidExport:
            return "That file is not a valid Hob Open Local export. Nothing changed."
        }
    }
}

public enum OpenLocalExportImporter {
    public static let maximumBytes = 10_000_000
    public static let maximumSchema = 11

    public static func parse(_ data: Data) throws -> OpenLocalImportResult {
        guard data.count <= maximumBytes else { throw OpenLocalImportError.tooLarge }
        let root: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw OpenLocalImportError.invalidExport }
            root = value
        } catch let error as OpenLocalImportError {
            throw error
        } catch {
            throw OpenLocalImportError.invalidExport
        }
        guard let schema = integer(root["schema_version"]), schema > 0 else {
            throw OpenLocalImportError.invalidExport
        }
        guard schema <= maximumSchema else {
            throw OpenLocalImportError.unsupportedVersion
        }
        guard let items = root["items"] as? [[String: Any]],
              root["action_log"] is [Any],
              root["digests"] is [Any],
              root["meta"] is [String: Any],
              items.count <= 10_000 else {
            throw OpenLocalImportError.invalidExport
        }

        var identifiers: Set<String> = []
        var preserved = 0
        let tasks = try items.map { item -> RuntimeTask in
            guard let id = text(item, "id", maximum: 128),
                  identifiers.insert(id).inserted,
                  let raw = text(item, "raw_text", maximum: 20_000),
                  let task = text(item, "task", maximum: 10_000),
                  let status = text(item, "status", maximum: 16),
                  ["open", "done", "dropped"].contains(status),
                  let created = text(item, "created_at", maximum: 64),
                  let updated = text(item, "updated_at", maximum: 64),
                  ISO8601DateFormatter().date(from: created) != nil,
                  ISO8601DateFormatter().date(from: updated) != nil else {
                throw OpenLocalImportError.invalidExport
            }
            let archived: String
            do {
                let archivedData = try JSONSerialization.data(
                    withJSONObject: item,
                    options: [.sortedKeys]
                )
                guard archivedData.count <= 20_000,
                      let value = String(data: archivedData, encoding: .utf8) else {
                    throw OpenLocalImportError.tooLarge
                }
                archived = value
            } catch let error as OpenLocalImportError {
                throw error
            } catch {
                throw OpenLocalImportError.invalidExport
            }
            preserved += advancedDetailCount(item)
            return RuntimeTask(
                id: id,
                rawText: raw,
                task: task,
                dueDate: optionalText(item, "due_date", maximum: 10),
                dueTime: optionalText(item, "due_time", maximum: 5),
                deadlineDate: optionalText(item, "deadline_date", maximum: 10),
                durationMinutes: optionalInteger(item["duration_minutes"]),
                priority: optionalText(item, "priority", maximum: 16) ?? "normal",
                status: status,
                createdAt: created,
                updatedAt: updated,
                sourceArchive: archived
            )
        }
        do {
            _ = try RuntimePersistentState(tasks: tasks, undoSnapshots: []).validated()
        } catch {
            throw OpenLocalImportError.invalidExport
        }
        return OpenLocalImportResult(
            tasks: tasks.sorted { $0.id < $1.id },
            preservedDetailCount: preserved,
            sourceSchema: schema
        )
    }

    private static func text(
        _ object: [String: Any],
        _ key: String,
        maximum: Int
    ) -> String? {
        guard let value = object[key] as? String,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximum else { return nil }
        return value
    }

    private static func optionalText(
        _ object: [String: Any],
        _ key: String,
        maximum: Int
    ) -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let string = value as? String, string.utf8.count <= maximum else {
            return "__invalid__"
        }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        return number.doubleValue == Double(integer) ? integer : nil
    }

    private static func optionalInteger(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        return integer(value) ?? Int.min
    }

    private static func advancedDetailCount(_ item: [String: Any]) -> Int {
        let keys = [
            "repeat", "tag", "snooze_until", "note", "waiting_since",
            "duration_confidence", "earliest_start", "preferred_window",
            "parent_id", "recurrence",
        ]
        var count = keys.count { meaningful(item[$0]) }
        if (item["schedule_kind"] as? String).map({ $0 != "flexible" }) == true {
            count += 1
        }
        if (item["splittable"] as? Bool) == true { count += 1 }
        for key in ["depends_on", "reminder_offsets", "reminded_offsets"] {
            if let values = item[key] as? [Any], !values.isEmpty { count += 1 }
        }
        return count
    }

    private static func meaningful(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let string = value as? String { return !string.isEmpty }
        if let values = value as? [Any] { return !values.isEmpty }
        if let values = value as? [String: Any] { return !values.isEmpty }
        return true
    }
}
