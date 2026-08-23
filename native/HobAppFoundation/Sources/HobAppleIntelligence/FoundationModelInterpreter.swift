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
            let open = tasks.filter { $0.status == "open" }.sorted { $0.id < $1.id }
            let prompt = """
            Current instant: \(now)
            Timezone: \(timezone)
            Open tasks: \(open.enumerated().map { "\($0.offset + 1). \($0.element.task)" })
            User message: \(clean)
            """
            let expectedActionCount: Int
            do {
                expectedActionCount = try await Self.generateActionCount(prompt: prompt)
            } catch {
                throw RuntimeInterpretationError.invalidOutput
            }
            let repairPrompt = """
            Start over from the original request. A previous result failed
            validation. Check every field before returning it:
            - use capture with target 0 for each genuinely new task
            - return one action per distinct task and preserve shared context
            - copy each clock expression exactly into clockText
            - choose am or pm for every copied clock expression
            - use duration 0 and durationEvidence none when effort is unstated
            - never turn a planned day into a deadline

            Expected action count: \(expectedActionCount)
            \(prompt)
            """
            let attempts = [
                "Expected action count: \(expectedActionCount)\n\(prompt)",
                repairPrompt,
                "Final validation attempt.\n\(repairPrompt)",
            ]
            for candidate in attempts {
                do {
                    return try await Self.generateActions(
                        session: LanguageModelSession(instructions: Self.instructions),
                        prompt: candidate,
                        originalMessage: clean,
                        openTaskCount: open.count,
                        expectedActionCount: expectedActionCount
                    )
                } catch {
                    continue
                }
            }
            throw RuntimeInterpretationError.invalidOutput
        }
        #endif
        throw RuntimeInterpretationError.modelUnavailable
    }

    private static let instructions = """
    Convert one natural-language message into explicit planner actions. Capture
    genuinely new tasks. Match completion, drop, move, or rename statements to
    the numbered open task. Use replan when circumstances changed but no task
    itself changed. Never turn an explanation about an open task into a new task.
    Separate several explicit actions when present. Produce exactly one action
    per distinct task. Never enumerate alternative interpretations or times.
    A schedule day says when the person intends to do the task. A deadline is
    introduced by wording such as "by Friday" or "due Friday". Never convert a
    deadline into a schedule day. Return semantic date kinds; code owns date math.
    Copy clock text exactly from the person's message and choose its single most
    plausible am or pm meaning from the current instant and ordinary context.
    Preserve an AM/PM marker or unambiguous 24-hour text exactly as written. Use
    duration 0 and duration evidence none when effort is unstated.
    Evidence must be an exact excerpt from the message. Use priority normal unless
    the person clearly says high/urgent or low. Do not answer the person and do not
    invent tasks, changes, or constraints.
    """

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "Count of distinct requested planner actions")
    struct GeneratedActionCount {
        @Guide(description: "One per distinct task or planning action; from 1 through 16")
        var count: Int
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "All explicit task or planning actions in one message")
    struct GeneratedCaptureTurn {
        @Guide(description: "From 1 through 16 entries; exactly one per distinct task, never alternatives or duplicates")
        var tasks: [GeneratedCaptureTask]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "One task and its explicitly stated planning constraints")
    struct GeneratedCaptureTask {
        @Guide(
            description: "Requested planner operation",
            .anyOf(["capture", "complete", "drop", "reschedule", "amend", "replan"])
        )
        var operation: String

        @Guide(description: "1-based numbered open task, or 0 for capture or general replan")
        var targetIndex: Int

        @Guide(description: "Short actionable task label without date, clock, priority, or duration words")
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

        @Guide(description: "Estimated minutes from 5 through 480, or 0 when unstated")
        var durationMinutes: Int

        @Guide(description: "Exact effort words copied from the message, or none when unstated")
        var durationEvidence: String

        @Guide(
            description: "Explicit importance",
            .anyOf(["high", "normal", "low"])
        )
        var priority: String

        @Guide(description: "Exact clock text copied from the message, or none when unstated")
        var clockText: String

        @Guide(
            description: "am or pm meaning for the copied clock; none when unstated",
            .anyOf(["none", "am", "pm"])
        )
        var clockInterpretation: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func generateActionCount(prompt: String) async throws -> Int {
        let session = LanguageModelSession(instructions: """
        Count the distinct planner actions the person requests. Coordinated tasks
        count separately. Context, dates, times, and explanations do not add actions.
        Count a combined update to one existing task once. Do not perform or describe
        the actions.
        """)
        return try await session.respond(
            to: prompt,
            generating: GeneratedActionCount.self
        ).content.count
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func generateActions(
        session: LanguageModelSession,
        prompt: String,
        originalMessage: String,
        openTaskCount: Int,
        expectedActionCount: Int
    ) async throws -> [RuntimeAction] {
        let response = try await session.respond(
            to: prompt,
            generating: GeneratedCaptureTurn.self
        )
        let actions = try response.content.tasks.map {
            try action(
                from: $0,
                originalMessage: originalMessage,
                openTaskCount: openTaskCount
            )
        }
        guard !actions.isEmpty,
              actions.count == expectedActionCount,
              actions.count <= 16 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        guard RuntimeGeneratedActions.areDistinct(actions) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return actions
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func action(
        from generated: GeneratedCaptureTask,
        originalMessage: String,
        openTaskCount: Int
    ) throws -> RuntimeAction {
        let task = generated.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if generated.operation == "replan" {
            return RuntimeAction(type: "replan")
        }
        if generated.operation != "capture" {
            guard (1...openTaskCount).contains(generated.targetIndex) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            let target = String(generated.targetIndex)
            switch generated.operation {
            case "complete", "drop":
                return RuntimeAction(type: generated.operation, target: target)
            case "amend":
                guard !task.isEmpty, task.utf8.count <= 10_000 else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                return RuntimeAction(type: "amend", task: task, target: target)
            case "reschedule":
                let time = try normalizedTime(
                    text: generated.clockText,
                    interpretation: generated.clockInterpretation,
                    originalMessage: originalMessage
                )
                return RuntimeAction(
                    type: "reschedule",
                    target: target,
                    when: try dateIntent(
                        kind: generated.scheduleKind,
                        weekday: generated.scheduleWeekday,
                        which: generated.scheduleWhich
                    ),
                    time: time,
                    confidence: 1
                )
            default:
                throw RuntimeInterpretationError.invalidOutput
            }
        }
        guard !task.isEmpty, task.utf8.count <= 10_000 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let duration: Int?
        if generated.durationMinutes == 0 {
            duration = nil
        } else if (5...480).contains(generated.durationMinutes) {
            duration = RuntimeConstraintEvidence.isSupportedDuration(
                generated.durationEvidence,
                in: originalMessage
            ) ? generated.durationMinutes : nil
        } else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let time = try normalizedTime(
            text: generated.clockText,
            interpretation: generated.clockInterpretation,
            originalMessage: originalMessage
        )
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

    private static func normalizedTime(
        text: String,
        interpretation: String,
        originalMessage: String
    ) throws -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "none",
           interpretation == "none" {
            return nil
        }
        guard let normalized = RuntimeGeneratedClock.normalizeEvidence(
            text,
            interpretation: interpretation,
            in: originalMessage
        ) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return normalized
    }
}
