// SPDX-License-Identifier: MIT
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(HobAppCore)
import HobAppCore
#endif

public struct AppleFoundationInterpreter: RuntimeMessageInterpreting {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    public func probe() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard isAvailable else { throw RuntimeInterpretationError.modelUnavailable }
            let session = LanguageModelSession(
                instructions: "Return only the requested readiness word."
            )
            _ = try await session.respond(to: "Return READY.")
            return
        }
        #endif
        throw RuntimeInterpretationError.modelUnavailable
    }

    public func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction] {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 20_000 else {
            throw RuntimeInterpretationError.unsupportedMessage
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard isAvailable else { throw RuntimeInterpretationError.modelUnavailable }
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            Current instant: \(now)
            Timezone: \(timezone)
            Open task labels: \(tasks.filter { $0.status == "open" }.map(\.task))
            User message: \(clean)
            """
            do {
                let response = try await session.respond(
                    to: prompt,
                    generating: GeneratedCaptureTurn.self
                )
                let actions = try response.content.tasks.map {
                    try Self.action(from: $0, originalMessage: clean)
                }
                guard !actions.isEmpty, actions.count <= 16 else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                return actions
            } catch let error as RuntimeInterpretationError {
                throw error
            } catch {
                throw RuntimeInterpretationError.invalidOutput
            }
        }
        #endif
        throw RuntimeInterpretationError.modelUnavailable
    }

    private static let instructions = """
    Extract new tasks from one natural-language message for a private planner.
    Preserve what the person needs to do. Separate several tasks when present.
    A schedule day says when the person intends to do the task. A deadline is
    introduced by wording such as "by Friday" or "due Friday". Never convert a
    deadline into a schedule day. Return semantic date kinds; code owns date math.
    Use duration 0 when unstated. Use time "none" when unstated. Use priority
    normal unless the person clearly says high/urgent or low. Do not answer the
    person and do not invent tasks or constraints.
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "All new tasks explicitly requested in one message")
    struct GeneratedCaptureTurn {
        @Guide(description: "One entry per distinct task", .count(1...16))
        var tasks: [GeneratedCaptureTask]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "One task and its explicitly stated planning constraints")
    struct GeneratedCaptureTask {
        @Guide(description: "Short actionable task label without date, priority, or duration words")
        var task: String

        @Guide(
            description: "Planned day kind; weekday means a named weekday",
            .anyOf(["none", "today", "tomorrow", "weekday"])
        )
        var scheduleKind: String

        @Guide(
            description: "Named planned weekday, otherwise none",
            .anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        )
        var scheduleWeekday: String

        @Guide(
            description: "this for this weekday, next for next weekday, otherwise none",
            .anyOf(["none", "this", "next"])
        )
        var scheduleWhich: String

        @Guide(
            description: "Hard deadline kind; weekday means a named deadline weekday",
            .anyOf(["none", "today", "tomorrow", "weekday"])
        )
        var deadlineKind: String

        @Guide(
            description: "Named deadline weekday, otherwise none",
            .anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        )
        var deadlineWeekday: String

        @Guide(
            description: "this for this deadline weekday, next for next weekday, otherwise none",
            .anyOf(["none", "this", "next"])
        )
        var deadlineWhich: String

        @Guide(description: "Estimated minutes, or 0 when unstated", .range(0...480))
        var durationMinutes: Int

        @Guide(
            description: "Explicit importance",
            .anyOf(["high", "normal", "low"])
        )
        var priority: String

        @Guide(description: "Explicit 24-hour HH:MM start time, or none")
        var time: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func action(
        from generated: GeneratedCaptureTask,
        originalMessage: String
    ) throws -> RuntimeAction {
        let task = generated.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.utf8.count <= 10_000 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let duration: Int?
        if generated.durationMinutes == 0 {
            duration = nil
        } else if (5...480).contains(generated.durationMinutes) {
            duration = generated.durationMinutes
        } else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let time = generated.time == "none" ? nil : generated.time
        if let time, !validTime(time) {
            throw RuntimeInterpretationError.invalidOutput
        }
        return RuntimeAction(
            type: "capture",
            task: task,
            raw: originalMessage,
            when: try dateIntent(
                kind: generated.scheduleKind,
                weekday: generated.scheduleWeekday,
                which: generated.scheduleWhich
            ),
            deadline: try dateIntent(
                kind: generated.deadlineKind,
                weekday: generated.deadlineWeekday,
                which: generated.deadlineWhich
            ),
            time: time,
            durationMinutes: duration,
            priority: generated.priority,
            confidence: 1
        )
    }
    #endif

    private static func dateIntent(
        kind: String,
        weekday: String,
        which: String
    ) throws -> RuntimeDateIntent? {
        if kind == "none" { return nil }
        if kind == "today" || kind == "tomorrow" {
            return RuntimeDateIntent(kind: kind)
        }
        guard kind == "weekday",
              ["mon", "tue", "wed", "thu", "fri", "sat", "sun"].contains(weekday),
              ["this", "next"].contains(which) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return RuntimeDateIntent(kind: "weekday", which: which, day: weekday)
    }

    private static func validTime(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        return pieces.count == 2
            && pieces[0].count == 2
            && pieces[1].count == 2
            && Int(pieces[0]).map { (0...23).contains($0) } == true
            && Int(pieces[1]).map { (0...59).contains($0) } == true
    }
}
