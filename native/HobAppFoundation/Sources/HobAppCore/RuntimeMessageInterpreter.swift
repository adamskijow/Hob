// SPDX-License-Identifier: MIT
import Foundation

public protocol RuntimeMessageInterpreting: Sendable {
    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction]

    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask],
        context: RuntimeConversationContext
    ) async throws -> [RuntimeAction]
}

public extension RuntimeMessageInterpreting {
    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask],
        context: RuntimeConversationContext
    ) async throws -> [RuntimeAction] {
        try await interpret(message: message, now: now, timezone: timezone, tasks: tasks)
    }
}

public struct RuntimeConversationContext: Equatable, Sendable {
    public let focusedTaskIDs: [String]
    public let unresolvedMessage: String?

    public init(focusedTaskIDs: [String] = [], unresolvedMessage: String? = nil) {
        self.focusedTaskIDs = Array(focusedTaskIDs.prefix(8))
        self.unresolvedMessage = unresolvedMessage.flatMap {
            let clean = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : String(clean.prefix(2_000))
        }
    }

    public static let empty = RuntimeConversationContext()
}

public enum RuntimeInterpretationError: Error, Equatable, Sendable {
    case modelUnavailable
    case unsupportedMessage
    case invalidOutput
}

public enum RuntimeGeneratedClock {
    /// Canonicalize a model-rendered clock value before strict runtime
    /// validation. The model still owns the semantic AM/PM decision; this only
    /// accepts equivalent representations of that decision.
    public static func normalize(_ value: String) -> String? {
        var text = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
        guard !text.isEmpty else { return nil }

        let meridiem: String?
        if text.hasSuffix("am") {
            meridiem = "am"
            text.removeLast(2)
        } else if text.hasSuffix("pm") {
            meridiem = "pm"
            text.removeLast(2)
        } else {
            meridiem = nil
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let hour: Int
        let minute: Int
        if text.contains(":") {
            let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let parsedHour = Int(pieces[0]),
                  let parsedMinute = Int(pieces[1]),
                  pieces[1].count == 2 else { return nil }
            hour = parsedHour
            minute = parsedMinute
        } else {
            guard text.allSatisfy(\.isNumber), (1...4).contains(text.count) else {
                return nil
            }
            if text.count <= 2 {
                guard let parsedHour = Int(text) else { return nil }
                hour = parsedHour
                minute = 0
            } else {
                let minuteStart = text.index(text.endIndex, offsetBy: -2)
                guard let parsedHour = Int(text[..<minuteStart]),
                      let parsedMinute = Int(text[minuteStart...]) else { return nil }
                hour = parsedHour
                minute = parsedMinute
            }
        }

        guard (0...59).contains(minute) else { return nil }
        var canonicalHour = hour
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" {
                canonicalHour = hour == 12 ? 0 : hour
            } else {
                canonicalHour = hour == 12 ? 12 : hour + 12
            }
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        return String(format: "%02d:%02d", canonicalHour, minute)
    }

    /// Canonicalize clock text copied from the message. The model supplies only
    /// the semantic AM/PM choice; code preserves and validates the written time.
    public static func normalizeEvidence(
        _ value: String,
        interpretation: String,
        in message: String
    ) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RuntimeConstraintEvidence.contains(text, in: message) else {
            return nil
        }
        let lower = text.lowercased().replacingOccurrences(of: ".", with: "")
        let writtenMeridiem: String?
        if lower.hasSuffix("am") {
            writtenMeridiem = "am"
        } else if lower.hasSuffix("pm") {
            writtenMeridiem = "pm"
        } else {
            writtenMeridiem = nil
        }

        if let writtenMeridiem {
            guard interpretation == writtenMeridiem else {
                return nil
            }
            return normalize(text)
        }
        if let normalized = normalize(text),
           let hour = Int(normalized.prefix(2)),
           hour > 12 {
            guard interpretation == "am" || interpretation == "pm" else {
                return nil
            }
            return normalized
        }
        if interpretation == "am" || interpretation == "pm" {
            return normalize("\(text)\(interpretation)")
        }
        return nil
    }
}

public enum RuntimeConstraintEvidence {
    public static func contains(_ evidence: String, in message: String) -> Bool {
        let clean = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.lowercased() != "none" else { return false }
        return message.range(
            of: clean,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    public static func isSupportedDuration(
        _ evidence: String,
        in message: String
    ) -> Bool {
        guard contains(evidence, in: message) else { return false }
        let words = evidence
            .lowercased()
            .split { !$0.isLetter }
        return words.contains { word in
            word == "m" || word == "min" || word == "mins"
                || word == "minute" || word == "minutes"
                || word == "h" || word == "hr" || word == "hrs"
                || word == "hour" || word == "hours"
        }
    }
}

public enum RuntimeGeneratedActions {
    public static func areDistinct(_ actions: [RuntimeAction]) -> Bool {
        let signatures = actions.map { action in
            [
                action.type,
                action.target ?? "",
                action.task?.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ) ?? "",
                action.priority ?? "",
                action.durationMinutes.map(String.init) ?? "",
                action.clearFields?.joined(separator: ",") ?? "",
                action.note ?? "",
            ].joined(separator: "|")
        }
        return Set(signatures).count == signatures.count
    }
}
