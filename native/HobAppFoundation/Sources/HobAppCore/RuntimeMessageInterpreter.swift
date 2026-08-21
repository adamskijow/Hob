// SPDX-License-Identifier: MIT
import Foundation

public protocol RuntimeMessageInterpreting: Sendable {
    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction]
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
            ].joined(separator: "|")
        }
        return Set(signatures).count == signatures.count
    }
}
