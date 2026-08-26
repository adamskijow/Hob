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
        if #available(iOS 26.0, macOS 26.0, *),
           case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    public func probe() async throws {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard isAvailable else { throw RuntimeInterpretationError.modelUnavailable }
            _ = try await LanguageModelSession(
                instructions: "Return only the requested readiness word."
            ).respond(to: "Return READY.")
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
        try await interpret(
            message: message,
            now: now,
            timezone: timezone,
            tasks: tasks,
            context: .empty
        )
    }

    public func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask],
        context: RuntimeConversationContext
    ) async throws -> [RuntimeAction] {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 20_000 else {
            throw RuntimeInterpretationError.unsupportedMessage
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard isAvailable else { throw RuntimeInterpretationError.modelUnavailable }
            let open = tasks.filter { $0.status == "open" }.sorted { $0.id < $1.id }
            return try await Self.callTools(
                message: clean,
                now: now,
                timezone: timezone,
                open: open,
                recentChange: Self.hasRecentChange(tasks: tasks, now: now),
                context: context
            )
        }
        #endif
        throw RuntimeInterpretationError.modelUnavailable
    }

    #if canImport(FoundationModels)
    private actor CompactGenerationGate {
        private var lastFinished: ContinuousClock.Instant?

        func begin() async {
            guard let lastFinished else { return }
            let elapsed = lastFinished.duration(to: .now)
            let cooldown = Duration.milliseconds(500)
            if elapsed < cooldown {
                try? await Task.sleep(for: cooldown - elapsed)
            }
        }

        func finish() { lastFinished = .now }
    }

    private static let compactGenerationGate = CompactGenerationGate()

    @available(iOS 26.0, macOS 26.0, *)
    private static func generateCompact(
        prompt: String,
        instructions: String
    ) async throws -> CompactTurn {
        await compactGenerationGate.begin()
        do {
            let result = try await LanguageModelSession(
                instructions: instructions
            ).respond(to: prompt, generating: CompactTurn.self).content
            await compactGenerationGate.finish()
            return result
        } catch {
            await compactGenerationGate.finish()
            throw error
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func callTools(
        message: String,
        now: String,
        timezone: String,
        open: [RuntimeTask],
        recentChange: Bool,
        context: RuntimeConversationContext
    ) async throws -> [RuntimeAction] {
        let focusedIndices = Set(context.focusedTaskIDs.compactMap { id in
            open.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        })
        let prompt = unifiedPrompt(
            message: message,
            now: now,
            timezone: timezone,
            open: open,
            recentChange: recentChange,
            context: context
        )
        let first: CompactTurn
        do {
            first = try await generateCompact(
                prompt: prompt, instructions: unifiedInstructions
            )
        } catch {
            if let recovery = deterministicGenerationFailureRecovery(
                message: message, open: open, recentChange: recentChange,
                focusedIndices: focusedIndices
            ) { return recovery }
            throw RuntimeInterpretationError.invalidOutput
        }
        do {
            return try validateHolistic(
                compactAsHolistic(first, message: message),
                message: message,
                open: open,
                recentChange: recentChange,
                focusedIndices: focusedIndices
            )
        } catch {
            let repaired: CompactTurn
            do {
                repaired = try await generateCompact(
                    prompt: "Repair only the grounded parse. Problem: "
                        + holisticRepairHint(
                            compactAsHolistic(first, message: message), open: open
                        )
                        + "\n" + prompt,
                    instructions: unifiedRepairInstructions
                )
            } catch {
                if let recovery = deterministicGenerationFailureRecovery(
                    message: message, open: open, recentChange: recentChange,
                    focusedIndices: focusedIndices
                ) { return recovery }
                throw RuntimeInterpretationError.invalidOutput
            }
            return try validateHolistic(
                compactAsHolistic(repaired, message: message),
                message: message,
                open: open,
                recentChange: recentChange,
                focusedIndices: focusedIndices
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func legacyCallTools(
        message: String,
        now: String,
        timezone: String,
        open: [RuntimeTask],
        recentChange: Bool,
        context: RuntimeConversationContext
    ) async throws -> [RuntimeAction] {
        let intent = try? await classifyIntent(message)
        let changeKind = try? await classifyChange(message)
        if ["resume", "other"].contains(changeKind),
           open.contains(where: \.isWaiting) {
            let resumeCollector = Collector()
            _ = try? await LanguageModelSession(
                tools: [Resume(collector: resumeCollector)],
                instructions: """
                Call resume_waiting only when the user's own words say a waiting
                task's blocker cleared or ask to put it back into active work.
                Do not call it for questions, new scheduling, or other edits.
                Copy exact targeting words.
                """
            ).respond(to: """
                Waiting tasks: \(open.enumerated().filter { $0.element.isWaiting }.map { "\($0.offset + 1). \($0.element.task)" })
                User message: \(message)
                """)
            let proposals = await resumeCollector.values()
            if !proposals.isEmpty {
                return try await validate(
                    proposals, message: message, open: open,
                    recentChange: recentChange,
                    focusedIndices: Set(context.focusedTaskIDs.compactMap { id in
                        open.firstIndex(where: { $0.id == id }).map { $0 + 1 }
                    })
                )
            }
        }
        if changeKind == "other",
           let dateQuery = try? await extractDateQuery(message) {
            return [dateQuery]
        }
        if changeKind == "other",
           let dateQuery = try? await recoverRelativeDateQuery(message) {
            return [dateQuery]
        }
        let couldBeNewTask = changeKind == nil || changeKind == "other"
        var newObligationConfirmed = false
        if couldBeNewTask && (intent == "new_task" || intent == "social") {
            newObligationConfirmed = (try? await confirmsNewObligation(
                message,
                minimumVotes: intent == "social" ? 4 : 3
            )) == true
        }
        if newObligationConfirmed {
            if let captures = try? await extractNewCaptures(
                message: message, now: now, timezone: timezone
            ), !captures.isEmpty {
                do {
                    let actions = try await validate(
                        captures.map(Proposal.capture), message: message,
                        open: open, recentChange: recentChange,
                        newObligationConfirmed: true
                    )
                    return actions
                } catch {}
            }
            if let recovered = try? await recoverNewCaptureActions(message: message),
               !recovered.isEmpty {
                return recovered
            }
            return [RuntimeAction(
                type: "capture", task: String(message.prefix(10_000)), raw: message,
                priority: "normal", confidence: 1
            )]
        }
        var socialConfirmed = intent == "social"
        if !socialConfirmed {
            socialConfirmed = (try? await confirmsSocial(message)) == true
        }
        if socialConfirmed {
            let reply = (try? await socialReply(to: message)) ?? "Anytime."
            return [RuntimeAction(type: "social", reply: reply)]
        }
        var isRetrieval = false
        if intent == "retrieval", changeKind == "other" {
            isRetrieval = (try? await confirmsRetrieval(message)) == true
        }
        if isRetrieval {
            if let query = try? await extractQuery(message),
               let actions = try? await validate(
                    [.query(query)], message: message, open: open,
                    recentChange: recentChange
               ) {
                return actions
            }
            if let action = try? await extractSimpleQuery(message) {
                return [action]
            }
        }
        let collector = Collector()
        let isChange = intent == "change"
            || (changeKind != nil && changeKind != "other")
        var tools: [any Tool] = [Undo(collector: collector)]
        if !isChange {
            tools += [
                Acknowledge(collector: collector),
                Replan(collector: collector), Capture(collector: collector),
            ]
        }
        if !open.isEmpty {
            if isChange {
                switch changeKind {
                case "metadata":
                    tools += [
                        SetPriority(collector: collector),
                        SetDuration(collector: collector),
                        ClearField(collector: collector),
                    ]
                case "note": tools.append(Note(collector: collector))
                case "wait": tools.append(Wait(collector: collector))
                case "resume": tools.append(Resume(collector: collector))
                case "move": tools.append(Move(collector: collector))
                case "rename": tools.append(Amend(collector: collector))
                case "drop": tools.append(Drop(collector: collector))
                case "keep": tools.append(Keep(collector: collector))
                case "recurrence": tools.append(Recurrence(collector: collector))
                default:
                    tools += [
                        Drop(collector: collector), Move(collector: collector),
                        Amend(collector: collector),
                        SetPriority(collector: collector),
                        SetDuration(collector: collector),
                        ClearField(collector: collector), Note(collector: collector),
                        Wait(collector: collector), Resume(collector: collector),
                        Keep(collector: collector), Recurrence(collector: collector),
                    ]
                }
            } else {
                tools += [
                    Progress(collector: collector),
                    BulkComplete(collector: collector),
                    BulkMove(collector: collector), Complete(collector: collector),
                    Drop(collector: collector), Move(collector: collector),
                    Amend(collector: collector), Note(collector: collector),
                    Wait(collector: collector), Resume(collector: collector),
                    Keep(collector: collector), Recurrence(collector: collector),
                ]
            }
        }
        let prompt = """
        Current instant: \(now)
        Timezone: \(timezone)
        Recent undo available: \(recentChange)
        Open tasks: \(open.enumerated().map {
            let details = [
                $0.element.dueDate.map { "date=\($0)" },
                $0.element.dueTime.map { "time=\($0)" },
                $0.element.deadlineDate.map { "deadline=\($0)" },
                $0.element.durationMinutes.map { "duration=\($0)m" },
                $0.element.priority.map { "priority=\($0)" },
                $0.element.waitingSince.map { _ in "waiting" },
            ].compactMap { $0 }.joined(separator: ", ")
            return "\($0.offset + 1). \($0.element.task)\(details.isEmpty ? "" : " [\(details)]")"
        })
        Focused task numbers: \(context.focusedTaskIDs.compactMap { id in
            open.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        })
        Earlier unresolved message: \(context.unresolvedMessage ?? "none")
        User message: \(message)
        """
        let instructions = """
        Translate the user's task-planning message into tool calls. The numbered
        open-task list is context, never user text. Respect tense, coordination,
        negation, exclusions, dates, clocks, idioms, and slang. Shared completion
        wording applies to each named object. Work or progress without clear
        completion stays open. A negated task is not dropped. A report of no
        accomplishments changes no task. In an all/everything report, excluded
        tasks remain open. Scheduling existing work moves it; scheduling a new
        obligation adds it. Call each necessary tool once. Never invent effects.
        Compact coordination can state several obligations. Create one tool call
        per distinct appointment or task. Pair coordinated people or objects with
        coordinated dates and clocks in order, including pairings expressed with
        "respectively". Keep every other obligation and its clock out of each
        individual task label.
        Use focused task numbers to resolve words such as it, that, the second
        one, or a bare follow-up change. The earlier unresolved message is
        context only; combine it with the current answer without treating it as
        a new instruction. Use query_tasks for questions asking to retrieve or
        search task state or completion history. Use revise_task for changes to
        an existing task's title, date, clock, deadline, estimate, or priority.
        Use add_note, park_waiting, and resume_waiting for durable task
        details and blocked work.
        """
        var succeeded = false
        for _ in 0..<2 where !succeeded {
            do {
                _ = try await LanguageModelSession(
                    tools: tools, instructions: instructions
                ).respond(to: prompt)
                succeeded = true
            } catch {}
        }
        if !succeeded {
            guard intent == "planning" else {
                throw RuntimeInterpretationError.invalidOutput
            }
            if let analysis = try? await extractAnalysis(
                message: message, open: open
            ) {
                return try await validate(
                    [.analysis(analysis)], message: message, open: open,
                    recentChange: recentChange
                )
            }
            throw RuntimeInterpretationError.invalidOutput
        }
        let firstPass = await collector.values()
        if changeKind == "metadata" {
            _ = try? await LanguageModelSession(
                tools: [SetPriority(collector: collector)],
                instructions: "Call set_task_priority once only when the user explicitly sets an existing task's priority."
            ).respond(to: prompt)
            _ = try? await LanguageModelSession(
                tools: [SetDuration(collector: collector)],
                instructions: "Call set_task_estimate once only when the user explicitly sets an existing task's estimated duration."
            ).respond(to: prompt)
        }
        if intent == "report", !open.isEmpty,
           !firstPass.contains(where: {
               switch $0 {
               case .bulkComplete, .bulkMove, .acknowledge, .analysis, .recurrence:
                   return true
               default: return false
               }
           }) {
            _ = try? await LanguageModelSession(
                tools: [Complete(collector: collector)],
                instructions: """
                Find every existing open task the user clearly reports fully
                finished. Call complete_task once for each. Respect shared tense,
                negation, exclusions, and partial progress. Call no tool if none.
                """
            ).respond(to: prompt)
        }
        let canHaveMissingCapture = firstPass.contains {
            if case .complete = $0 { return true }; return false
        } && !firstPass.contains {
            switch $0 {
            case .acknowledge, .progress, .drop, .move, .keep,
                 .bulkComplete, .bulkMove, .analysis, .recurrence: return true
            default: return false
            }
        }
        if canHaveMissingCapture,
           !firstPass.contains(where: {
               if case .capture = $0 { return true }; return false
           }) {
            for _ in 0..<2 {
                _ = try? await LanguageModelSession(
                    tools: [Capture(collector: collector)],
                    instructions: """
                    Extract every genuinely new obligation from the user message.
                    Call add_new_tasks once with one item per distinct task or
                    appointment. Preserve ordered pairings between coordinated
                    people, objects, dates, and clocks. Existing-task effects,
                    reports, replies, and bulk instructions are not new tasks.
                    Copy supporting evidence only from the user message. Call no
                    tool if there is no new task.
                    """
                ).respond(to: prompt)
            }
        }
        var reviewed = await collector.values()
        if reviewed.isEmpty, intent == "planning",
           let analysis = try? await extractAnalysis(
            message: message, open: open
           ) {
            reviewed = [.analysis(analysis)]
        }
        var captures = reviewed.compactMap { proposal -> CaptureArgs? in
            if case .capture(let value) = proposal { return value }
            return nil
        }
        if captures.isEmpty, open.isEmpty {
            captures = try await extractNewCaptures(
                message: message, now: now, timezone: timezone
            )
            if !captures.isEmpty {
                reviewed = captures.map(Proposal.capture)
            }
        }
        if let first = captures.first,
           clockCandidateCount(in: message) >= 2,
           coordinatedCapturesNeedReview(captures) {
            if let refined = try await refineCoordinatedCapture(
                first, message: message, now: now, timezone: timezone
            ) {
                reviewed.removeAll {
                    if case .capture = $0 { return true }; return false
                }
                reviewed += refined.map(Proposal.capture)
            } else {
                throw RuntimeInterpretationError.invalidOutput
            }
        }
        do {
            return try await validate(
                reviewed, message: message, open: open,
                recentChange: recentChange,
                focusedIndices: Set(context.focusedTaskIDs.compactMap { id in
                    open.firstIndex(where: { $0.id == id }).map { $0 + 1 }
                })
            )
        } catch {
            guard open.isEmpty else { throw error }
            return try await recoverNewCaptureActions(message: message)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static var unifiedInstructions: String {
        """
        Interpret ordinary speech as the smallest complete action list. Activities are captures; constraints stay attached. Split obligations. Edit only identified saved work. Past completion closes work; future intent and progress do not. Zero-work reports acknowledge. Conversation stays social. Fit, why, and what-if are analysis. Copy evidence exactly; invent nothing. Examples: “cake before tomorrow” is capture; “how is tomorrow?” is query; “thanks” is social.
        """
    }

    private static var unifiedRepairInstructions: String {
        """
        Repair the grounded interpretation once. Return the smallest complete action list. Copy evidence exactly and target only numbered tasks. Activities are captures; their constraints stay attached. Never turn future intent into completion, a date into recurrence, conversation into work, or new work into an edit. Invent nothing.
        """
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func holisticRepairHint(
        _ turn: HolisticTurn,
        open: [RuntimeTask]
    ) -> String {
        if turn.actions.contains(where: { action in
            if case .complete = action { return true }
            return false
        }), !completionEvidenceIsSupported(
            turn.actions.compactMap { action -> String? in
                if case .complete(let value) = action { return value.evidence }
                return nil
            }.joined(separator: " ")
        ) {
            return "Complete is unsupported: the user did not report past completion. Interpret the actual request; questions stay read-only and conversational messages are social."
        }
        if open.isEmpty, turn.actions.contains(where: { action in
            switch action {
            case .complete, .drop, .keep, .wait, .resume, .progress,
                 .move, .revise, .note, .bulkComplete, .bulkMove, .recurrence:
                return true
            default:
                return false
            }
        }) {
            return "There are no open tasks, so an existing-task effect is impossible. A named activity to do is capture."
        }
        return "The first output was not grounded in the message or numbered tasks. Correct only that error."
    }

    private static func completionEvidenceIsSupported(_ message: String) -> Bool {
        let tokens = Set(words(message))
        if !tokens.isDisjoint(with: [
            "done", "did", "finished", "completed", "handled", "accomplished",
        ]) { return true }
        let lower = message.lowercased()
        return lower.contains("took care of") || lower.contains("got done")
    }

    private static func isInterrogative(_ message: String) -> Bool {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasSuffix("?") { return true }
        guard let first = words(clean).first else { return false }
        return [
            "what", "whats", "when", "where", "why", "who", "how",
            "will", "would", "could", "can", "should", "is", "are", "do", "does",
        ].contains(first)
    }

    private static func isWhatIfQuestion(_ message: String) -> Bool {
        let tokens = words(message)
        return tokens.count >= 2 && tokens[0] == "what" && tokens[1] == "if"
    }

    private static func capacityEvidenceIsSupported(_ message: String) -> Bool {
        let tokens = Set(words(message))
        return !tokens.isDisjoint(with: [
            "fit", "fits", "capacity", "overloaded", "overload", "realistic",
        ])
    }

    private static func waitingEvidenceIsSupported(_ message: String) -> Bool {
        let tokens = Set(words(message))
        return !tokens.isDisjoint(with: [
            "wait", "waiting", "blocked", "blocker", "pending",
        ])
    }

    private static func zeroCompletionReportIsSupported(_ message: String) -> Bool {
        let ordered = words(message)
        let tokens = Set(ordered)
        if ordered.count == 1,
           ["nothing", "none", "nada", "zero"].contains(ordered[0]) {
            return true
        }
        let completion = !tokens.isDisjoint(with: [
            "done", "did", "finish", "finished", "complete", "completed",
            "accomplished", "achieved",
        ]) || message.lowercased().contains("got done")
        if completion,
           !tokens.isDisjoint(with: ["nothing", "none", "nada", "zero"]) {
            return true
        }
        let lower = message.lowercased()
        if completion && (lower.contains("jack shit") || lower.contains("didn't do anything")
            || lower.contains("did not do anything")) {
            return true
        }
        return lower.contains("today was a wash") || lower.contains("day was a wash")
    }

    private static func taskQueryEvidenceIsSupported(_ message: String) -> Bool {
        let tokens = Set(words(message))
        return !tokens.isDisjoint(with: [
            "task", "tasks", "list", "schedule", "plan", "today", "tomorrow",
            "week", "overdue", "waiting", "blocked", "done", "finish", "finished",
        ])
    }

    private static func clearConversationEvidence(_ message: String) -> Bool {
        let tokens = Set(words(message))
        guard tokens.count <= 4 else { return false }
        let conversational = Set([
            "thanks", "thank", "bro", "bud", "cool", "okay", "ok", "got",
            "it", "sounds", "good", "great", "nice", "awesome", "yep", "yeah",
        ])
        return !tokens.isEmpty && tokens.isSubset(of: conversational)
    }

    private static func deterministicGenerationFailureRecovery(
        message: String,
        open: [RuntimeTask],
        recentChange: Bool,
        focusedIndices: Set<Int> = []
    ) -> [RuntimeAction]? {
        if zeroCompletionReportIsSupported(message) {
            return [RuntimeAction(type: "acknowledge")]
        }
        if clearConversationEvidence(message) {
            return [RuntimeAction(type: "social", reply: "Anytime.")]
        }
        if recentChange, words(message) == ["undo"] {
            return [RuntimeAction(type: "undo")]
        }
        let supplied = Set(words(message))
        if focusedIndices.count == 1,
           !supplied.isDisjoint(with: ["that", "it"]),
           let time = deterministicSingleClock(in: message),
           let target = focusedIndices.first {
            return [RuntimeAction(
                type: "reschedule", target: String(target), time: time
            )]
        }
        if focusedIndices.count == 1,
           !supplied.isDisjoint(with: ["stay", "stays", "keep", "keeping"]),
           let target = focusedIndices.first {
            return [RuntimeAction(type: "keep", target: String(target))]
        }
        if isInterrogative(message), let date = deterministicDateIntent(in: message) {
            return [RuntimeAction(type: "query", when: date, queryKind: "date")]
        }
        if isInterrogative(message), capacityEvidenceIsSupported(message) {
            return [RuntimeAction(
                type: "analysis", analysisKind: "capacity", horizonDays: 7
            )]
        }
        if open.isEmpty, !isInterrogative(message),
           let task = deterministicFallbackCaptureLabel(in: message) {
            let recurrence = holisticRecurrence(evidence: message, message: message)
            let date = deterministicDateIntent(in: message)
            let hasDeadline = message.range(
                of: #"\b(?:by|before|due)\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return [RuntimeAction(
                type: "capture", task: task, raw: message,
                when: hasDeadline ? nil : (date ?? recurrenceInitialDate(recurrence)),
                deadline: hasDeadline ? date : nil,
                time: deterministicSingleClock(in: message),
                durationMinutes: deterministicDurationMinutes(in: message),
                priority: deterministicPriority(in: message) ?? "normal",
                recurrence: recurrence, confidence: 1
            )]
        }
        return nil
    }

    private static func deterministicFallbackCaptureLabel(in message: String) -> String? {
        var label = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let removals = [
            #"^(?:today|tomorrow)\s*,?\s*"#,
            #"^(?:please\s+)?(?:set\s+(?:a\s+)?reminder\s+to|remind\s+me\s+to)\s+"#,
            #"^(?:i\s+)?(?:gotta|got\s+to|have\s+to|need\s+to|want\s+to)\s+"#,
        ]
        for pattern in removals {
            label = label.replacingOccurrences(
                of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        label = label.replacingOccurrences(
            of: #"\s+(?:by|before|due\s+by|today|tomorrow|every\s+\w+|at\s+\d{1,2}(?::?\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)?)\b.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 200,
              label.contains(where: \.isLetter) else { return nil }
        return label
    }

    private static func mentionedOpenTaskIndices(
        in message: String,
        open: [RuntimeTask]
    ) -> [Int] {
        let ignored = Set([
            "the", "and", "for", "with", "from", "that", "this", "need",
            "needs", "did", "done", "finish", "finished", "complete", "completed",
            "make", "made", "have", "has", "had", "get", "got",
        ])
        let supplied = Set(words(message)).subtracting(ignored)
        return open.enumerated().compactMap { index, task in
            let identifying = Set(words(task.task).filter { word in
                word.count >= 3 && !ignored.contains(word)
            })
            guard !identifying.isEmpty else { return nil }
            let overlap = identifying.intersection(supplied).count
            let required = identifying.count == 1 ? 1 : 2
            return overlap >= required ? index + 1 : nil
        }
    }

    private static func deterministicDurationMinutes(in message: String) -> Int? {
        let tokens = words(message)
        let names = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        for index in tokens.indices where index + 1 < tokens.count {
            guard let amount = Int(tokens[index]) ?? names[tokens[index]] else { continue }
            let unit = tokens[index + 1]
            if unit == "hour" || unit == "hours" { return amount * 60 }
            if ["minute", "minutes", "min", "mins"].contains(unit) { return amount }
        }
        return nil
    }

    private static func deterministicPriority(in message: String) -> String? {
        let tokens = Set(words(message))
        if !tokens.isDisjoint(with: ["urgent", "critical", "important", "high"]) {
            return "high"
        }
        if !tokens.isDisjoint(with: ["low", "whenever", "optional"]) { return "low" }
        if tokens.contains("normal") { return "normal" }
        return nil
    }

    private static func deterministicClearFields(in message: String) -> [String] {
        let lower = message.lowercased()
        guard lower.contains("clear") || lower.contains("remove")
                || lower.contains("no longer") || lower.contains("unset")
                || lower.contains("no ") else { return [] }
        let tokens = Set(words(lower))
        var result: [String] = []
        if !tokens.isDisjoint(with: ["date", "day"]) { result.append("date") }
        if !tokens.isDisjoint(with: ["time", "clock"]) { result.append("time") }
        if tokens.contains("deadline") || tokens.contains("due") {
            result.append("deadline")
        }
        if !tokens.isDisjoint(with: ["duration", "estimate", "minutes", "hours"]) {
            result.append("duration")
        }
        if tokens.contains("priority") { result.append("priority") }
        if !tokens.isDisjoint(with: ["note", "notes"]) { result.append("note") }
        return result
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func inferredTargetIndex(
        from turn: HolisticTurn,
        message: String,
        open: [RuntimeTask]
    ) -> Int? {
        let messageWords = Set(words(message).filter { $0.count >= 3 })
        if let match = open.enumerated().max(by: { left, right in
            Set(words(left.element.task)).intersection(messageWords).count
                < Set(words(right.element.task)).intersection(messageWords).count
        }), !Set(words(match.element.task)).intersection(messageWords).isEmpty {
            return match.offset + 1
        }
        for action in turn.actions {
            let candidate: Int?
            switch action {
            case .complete(let value), .drop(let value), .keep(let value),
                 .wait(let value), .resume(let value):
                candidate = value.targetIndex
            case .analysis(let value): candidate = value.targetIndex
            case .move(let value): candidate = value.targetIndex
            case .revise(let value): candidate = value.targetIndex
            case .progress(let value), .note(let value): candidate = value.targetIndex
            case .recurrence(let value): candidate = value.targetIndex
            default: candidate = nil
            }
            if let candidate, (1...open.count).contains(candidate) { return candidate }
        }
        return nil
    }

    private static func unifiedPrompt(
        message: String,
        now: String,
        timezone: String,
        open: [RuntimeTask],
        recentChange: Bool,
        context: RuntimeConversationContext
    ) -> String {
        let listed = open.enumerated().map { index, task in
            let details = [
                task.dueDate.map { "date=\($0)" },
                task.dueTime.map { "time=\($0)" },
                task.deadlineDate.map { "deadline=\($0)" },
                task.durationMinutes.map { "duration=\($0)m" },
                task.priority.map { "priority=\($0)" },
                task.isWaiting ? "waiting" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            return "\(index + 1). \(task.task)\(details.isEmpty ? "" : " [\(details)]")"
        }.joined(separator: "\n")
        let focused = context.focusedTaskIDs.compactMap { id in
            open.firstIndex(where: { $0.id == id }).map { String($0 + 1) }
        }.joined(separator: ", ")
        return """
        Now: \(now), \(timezone). Undo: \(recentChange).
        Tasks:
        \(listed.isEmpty ? "(none)" : listed)
        Focus: \(focused.isEmpty ? "none" : focused). Earlier: \(context.unresolvedMessage ?? "none").

        User message:
        \(message)
        """
    }

    private static func unifiedDate(
        _ value: DateConstraintArgs,
        message: String
    ) throws -> RuntimeDateIntent? {
        if value.dateKind == "none" { return nil }
        let evidence = normalizedGeneratedEvidence(value.dateEvidence)
        guard RuntimeConstraintEvidence.contains(evidence, in: message)
        else { return nil }
        return try dateIntent(
            kind: value.dateKind,
            weekday: value.dateWeekday,
            which: value.dateWhich,
            n: value.dateN,
            unit: value.dateUnit,
            part: value.datePart,
            anchor: value.dateAnchor,
            year: value.dateYear,
            month: value.dateMonth,
            day: value.dateDay,
            evidence: evidence
        )
    }

    private static func normalizedGeneratedEvidence(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\'", with: "'")
            .replacingOccurrences(of: "\\\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unifiedEvidenceIsGrounded(
        _ evidence: String,
        in message: String
    ) -> Bool {
        RuntimeConstraintEvidence.contains(
            normalizedGeneratedEvidence(evidence), in: message
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func validateHolistic(
        _ turn: HolisticTurn,
        message: String,
        open: [RuntimeTask],
        recentChange: Bool,
        focusedIndices: Set<Int>
    ) throws -> [RuntimeAction] {
        guard !turn.actions.isEmpty, turn.actions.count <= 16 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        if turn.actions.count == 1,
           let continuation = conversationalContinuationCapture(message: message) {
            return [continuation]
        }
        if let coordinated = deterministicCoordinatedCaptures(message: message) {
            return coordinated
        }
        if isInterrogative(message), capacityEvidenceIsSupported(message) {
            return [RuntimeAction(
                type: "analysis", analysisKind: "capacity", horizonDays: 7
            )]
        }
        if isWhatIfQuestion(message),
           let duration = deterministicDurationMinutes(in: message),
           let target = inferredTargetIndex(from: turn, message: message, open: open) {
            return [RuntimeAction(
                type: "analysis", target: String(target),
                analysisKind: "what_if", horizonDays: 7,
                hypotheticalDurationMinutes: duration
            )]
        }
        if clearConversationEvidence(message)
            || (isInterrogative(message) && !taskQueryEvidenceIsSupported(message)) {
            return [RuntimeAction(type: "social", reply: "Anytime.")]
        }
        if zeroCompletionReportIsSupported(message) {
            return [RuntimeAction(type: "acknowledge")]
        }
        if open.isEmpty, !isInterrogative(message),
           deterministicDateIntent(in: message) != nil,
           turn.actions.contains(where: { action in
               switch action {
               case .capture(let value): return !value.task.isEmpty
               case .query(let value): return value.term != "none" && !value.term.isEmpty
               case .note(let value): return !value.note.isEmpty
               default: return false
               }
           }), let recovery = deterministicGenerationFailureRecovery(
               message: message, open: open, recentChange: recentChange
           ) {
            return recovery
        }
        let leadingWords = words(message)
        if leadingWords.first == "note",
           let target = inferredTargetIndex(from: turn, message: message, open: open) {
            let note = message.replacingOccurrences(
                of: #"^\s*note\s+(?:that\s+)?"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { throw RuntimeInterpretationError.invalidOutput }
            return [RuntimeAction(type: "note", target: String(target), note: note)]
        }
        if !isInterrogative(message), waitingEvidenceIsSupported(message),
           let target = inferredTargetIndex(from: turn, message: message, open: open) {
            return [RuntimeAction(type: "wait", target: String(target))]
        }
        let messageWords = Set(leadingWords)
        if completionEvidenceIsSupported(message) {
            let targets = mentionedOpenTaskIndices(in: message, open: open)
            if targets.count > 1 {
                return targets.map {
                    RuntimeAction(type: "complete", target: String($0))
                }
            }
        }
        if focusedIndices.count == 1,
           !messageWords.isDisjoint(with: ["stay", "stays", "keep", "keeping"]),
           let target = focusedIndices.first {
            return [RuntimeAction(type: "keep", target: String(target))]
        }
        if !isInterrogative(message),
           let date = deterministicDateIntent(in: message) {
            let mentioned = mentionedOpenTaskIndices(in: message, open: open)
            let target = mentioned.count == 1
                ? mentioned.first
                : inferredTargetIndex(from: turn, message: message, open: open)
            if let target {
                return [RuntimeAction(
                    type: "reschedule", target: String(target), when: date,
                    time: deterministicSingleClock(in: message)
                )]
            }
        }
        if !isInterrogative(message),
           (!messageWords.isDisjoint(with: ["replied", "cleared", "unblocked", "resume"])
                || message.lowercased().contains("back on deck")),
           let target = inferredTargetIndex(from: turn, message: message, open: open),
           open[target - 1].isWaiting {
            return [RuntimeAction(type: "resume", target: String(target))]
        }
        if focusedIndices.count == 1,
           !messageWords.isDisjoint(with: ["that", "it"]),
           let time = deterministicSingleClock(in: message),
           let target = focusedIndices.first {
            return [RuntimeAction(
                type: "reschedule", target: String(target), time: time
            )]
        }
        if !isInterrogative(message),
           let target = inferredTargetIndex(from: turn, message: message, open: open) {
            let priority = deterministicPriority(in: message)
            let duration = deterministicDurationMinutes(in: message)
            if priority != nil || duration != nil {
                return [RuntimeAction(
                    type: "revise", target: String(target),
                    durationMinutes: duration, priority: priority
                )]
            }
        }
        if isInterrogative(message) {
            let queryWords = Set(words(message))
            if !queryWords.isDisjoint(with: [
                "did", "done", "finish", "finished", "completed",
            ]) {
                return [RuntimeAction(
                    type: "query", queryKind: "done",
                    queryPeriod: queryWords.contains("week") ? "week" : "today"
                )]
            }
            if !queryWords.isDisjoint(with: ["waiting", "blocked"]) {
                return [RuntimeAction(type: "query", queryKind: "waiting")]
            }
        }
        if isInterrogative(message),
           let date = deterministicDateIntent(in: message),
           !capacityEvidenceIsSupported(message) {
            return [RuntimeAction(type: "query", when: date, queryKind: "date")]
        }
        if let capture = turn.actions.compactMap({ action -> HolisticCapture? in
            if case .capture(let value) = action { return value }
            return nil
        }).first,
           turn.actions.allSatisfy({ action in
               switch action {
               case .capture: return true
               case .complete: return !completionEvidenceIsSupported(message)
               default: return false
               }
           }),
           let labels = structurallySeparateCoordinatedLabels(in: message),
           let clocks = coordinatedClockTexts(in: message) {
            let recurrence = holisticRecurrence(
                evidence: capture.recurrenceEvidence, message: message
            ) ?? holisticRecurrence(evidence: message, message: message)
            let when = try groundedHolisticDate(
                capture.dateEvidence, message: message
            ) ?? recurrenceInitialDate(recurrence)
            let deadline = try groundedHolisticDate(
                capture.deadlineEvidence, message: message
            )
            let actions = [labels.0, labels.1].enumerated().map { index, label in
                RuntimeAction(
                    type: "capture", task: label.task, raw: message,
                    when: when, deadline: deadline,
                    time: RuntimeGeneratedClock.normalizeEvidence(
                        clocks[index],
                        interpretation: explicitMeridiem(in: clocks[index])
                            ?? capture.clockInterpretation,
                        in: message
                    ),
                    priority: "normal", recurrence: recurrence, confidence: 1
                )
            }
            guard actions.allSatisfy({ $0.time != nil }) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return actions
        }

        let hasCapture = turn.actions.contains { action in
            if case .capture = action { return true }
            return false
        }
        let possibleActions = turn.actions.filter { action in
            if hasCapture {
                switch action {
                case .social, .acknowledge: return false
                default: break
                }
            }
            if case .complete = action {
                return completionEvidenceIsSupported(message)
            }
            return true
        }
        let actions = open.isEmpty && hasCapture ? possibleActions.filter { action in
            switch action {
            case .complete, .drop, .keep, .wait, .resume, .progress,
                 .move, .revise, .note, .bulkComplete, .bulkMove, .recurrence:
                return false
            default:
                return true
            }
        } : possibleActions
        var result: [RuntimeAction] = []
        var containsExclusive = false
        for action in actions {
            switch action {
            case .capture(let value):
                guard !isInterrogative(message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                let task = value.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty,
                      captureIsNew(task, evidence: message, open: open) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                let recurrence = holisticRecurrence(
                    evidence: value.recurrenceEvidence, message: message
                ) ?? holisticRecurrence(evidence: message, message: message)
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                let priority = ["high", "normal", "low"].contains(value.priority)
                    && unifiedEvidenceIsGrounded(value.priorityEvidence, in: message)
                    ? value.priority : "normal"
                let fallbackDate = deterministicDateIntent(in: message)
                let deadlineLanguage = message.range(
                    of: #"\b(?:by|before|due)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
                result.append(RuntimeAction(
                    type: "capture", task: task, raw: message,
                    when: try groundedHolisticDate(value.dateEvidence, message: message)
                        ?? (deadlineLanguage ? nil : fallbackDate)
                        ?? recurrenceInitialDate(recurrence),
                    deadline: deadlineLanguage ? (try groundedHolisticDate(
                        value.deadlineEvidence, message: message
                    ) ?? fallbackDate) : nil,
                    time: groundedHolisticTime(
                        value.clockText,
                        interpretation: value.clockInterpretation,
                        message: message
                    ) ?? deterministicSingleClock(in: message),
                    durationMinutes: duration, priority: priority,
                    recurrence: recurrence, confidence: 1
                ))
            case .complete(let value):
                result.append(RuntimeAction(type: "complete", target: try holisticTarget(
                    value, message: message, open: open, focused: focusedIndices
                )))
            case .drop(let value):
                result.append(RuntimeAction(type: "drop", target: try holisticTarget(
                    value, message: message, open: open, focused: focusedIndices
                )))
            case .keep(let value):
                result.append(RuntimeAction(type: "keep", target: try holisticTarget(
                    value, message: message, open: open, focused: focusedIndices
                )))
            case .wait(let value):
                guard waitingEvidenceIsSupported(message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(type: "wait", target: try holisticTarget(
                    value, message: message, open: open, focused: focusedIndices
                )))
            case .resume(let value):
                result.append(RuntimeAction(type: "resume", target: try holisticTarget(
                    value, message: message, open: open, focused: focusedIndices
                )))
            case .progress(let value), .note(let value):
                let target = try holisticTarget(
                    TargetArgs(targetIndex: value.targetIndex, evidence: value.evidence),
                    message: message, open: open, focused: focusedIndices
                )
                guard unifiedEvidenceIsGrounded(value.note, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(type: "note", target: target, note: value.note))
            case .move(let value):
                let target = try holisticTarget(
                    TargetArgs(targetIndex: value.targetIndex, evidence: value.evidence),
                    message: message, open: open, focused: focusedIndices
                )
                let date = try groundedHolisticDate(value.dateEvidence, message: message)
                let time = groundedHolisticTime(
                    value.clockText,
                    interpretation: value.clockInterpretation,
                    message: message
                )
                guard date != nil || time != nil else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "reschedule", target: target, when: date, time: time
                ))
            case .revise(let value):
                let target = try holisticTarget(
                    TargetArgs(targetIndex: value.targetIndex, evidence: value.evidence),
                    message: message, open: open, focused: focusedIndices
                )
                let title = unifiedEvidenceIsGrounded(value.taskEvidence, in: message)
                    ? value.task.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                let priority = unifiedEvidenceIsGrounded(
                    value.priorityEvidence, in: message
                ) && ["high", "normal", "low"].contains(value.priority)
                    ? value.priority : nil
                let clear = Array(Set(value.clearFields).intersection([
                    "date", "time", "deadline", "duration", "priority", "note",
                ])).sorted()
                let date = try groundedHolisticDate(value.dateEvidence, message: message)
                let deadline = try groundedHolisticDate(
                    value.deadlineEvidence, message: message
                )
                let time = groundedHolisticTime(
                    value.clockText,
                    interpretation: value.clockInterpretation,
                    message: message
                )
                guard !title.isEmpty || duration != nil || priority != nil || !clear.isEmpty
                        || date != nil || deadline != nil || time != nil else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "revise", task: title.isEmpty ? nil : title,
                    target: target, when: date, deadline: deadline, time: time,
                    durationMinutes: duration, priority: priority,
                    clearFields: clear.isEmpty ? nil : clear
                ))
            case .query(let value):
                containsExclusive = true
                guard unifiedEvidenceIsGrounded(value.evidence, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                if !taskQueryEvidenceIsSupported(message) {
                    result.append(RuntimeAction(
                        type: "social", reply: "I can help with your plan."
                    ))
                    break
                }
                let date = try groundedHolisticDate(
                    value.dateEvidence, message: message
                ) ?? deterministicDateIntent(in: message)
                let term = value.term == "none" ? "" : value.term
                guard value.kind != "date" || date != nil,
                      value.kind != "search" || !term.isEmpty else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                if capacityEvidenceIsSupported(message) {
                    result.append(RuntimeAction(
                        type: "analysis", analysisKind: "capacity", horizonDays: 7
                    ))
                    break
                }
                let derivedKind: String
                let queryWords = Set(words(message))
                if !queryWords.isDisjoint(with: ["done", "finish", "finished", "completed"]) {
                    derivedKind = "done"
                } else if !queryWords.isDisjoint(with: ["waiting", "blocked"]) {
                    derivedKind = "waiting"
                } else { derivedKind = value.kind }
                result.append(RuntimeAction(
                    type: "query", when: date, queryKind: derivedKind,
                    queryTerm: term.isEmpty ? nil : term,
                    queryPeriod: value.period
                ))
            case .analysis(let value):
                containsExclusive = true
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      value.targetIndex == 0 || (1...open.count).contains(value.targetIndex)
                else { throw RuntimeInterpretationError.invalidOutput }
                if value.kind == "what_if" {
                    guard value.targetIndex > 0,
                          RuntimeConstraintEvidence.isSupportedDuration(
                            value.durationEvidence, in: message
                          ) else { throw RuntimeInterpretationError.invalidOutput }
                }
                result.append(RuntimeAction(
                    type: "analysis",
                    target: value.targetIndex > 0 ? String(value.targetIndex) : nil,
                    analysisKind: value.kind,
                    horizonDays: (1...31).contains(value.horizonDays)
                        ? value.horizonDays : 7,
                    budgetMinutes: value.budgetMinutes > 0 ? value.budgetMinutes : nil,
                    hypotheticalDurationMinutes: value.hypotheticalDurationMinutes > 0
                        ? value.hypotheticalDurationMinutes : nil
                ))
            case .bulkComplete(let value):
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      Set(value.excludedTargets).count == value.excludedTargets.count,
                      value.excludedTargets.allSatisfy({ (1...open.count).contains($0) })
                else { throw RuntimeInterpretationError.invalidOutput }
                let excluded = Set(value.excludedTargets)
                result += open.indices.compactMap { index in
                    excluded.contains(index + 1) ? nil
                        : RuntimeAction(type: "complete", target: String(index + 1))
                }
                if result.isEmpty { result = [RuntimeAction(type: "acknowledge")] }
            case .bulkMove(let value):
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      !value.destinations.isEmpty else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                var seen = Set<Int>()
                for destination in value.destinations {
                    guard (1...open.count).contains(destination.targetIndex),
                          seen.insert(destination.targetIndex).inserted,
                          let date = try groundedHolisticDate(
                            destination.dateEvidence, message: message
                          ) else { throw RuntimeInterpretationError.invalidOutput }
                    result.append(RuntimeAction(
                        type: "reschedule", target: String(destination.targetIndex),
                        when: date,
                        time: groundedHolisticTime(
                            destination.clockText,
                            interpretation: destination.clockInterpretation,
                            message: message
                        )
                    ))
                }
            case .recurrence(let value):
                let target = try holisticTarget(
                    TargetArgs(targetIndex: value.targetIndex, evidence: value.evidence),
                    message: message, open: open, focused: focusedIndices
                )
                result.append(RuntimeAction(
                    type: "recurrence", target: target,
                    recurrenceOperation: value.operation
                ))
            case .acknowledge(let value):
                containsExclusive = true
                guard unifiedEvidenceIsGrounded(value.evidence, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                if zeroCompletionReportIsSupported(message) {
                    result.append(RuntimeAction(type: "acknowledge"))
                } else {
                    let reply = value.reply.isEmpty ? "Anytime." : value.reply
                    result.append(RuntimeAction(type: "social", reply: reply))
                }
            case .undo(let value):
                containsExclusive = true
                guard recentChange,
                      unifiedEvidenceIsGrounded(value.evidence, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(type: "undo"))
            case .replan(let value):
                containsExclusive = true
                guard unifiedEvidenceIsGrounded(value.evidence, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(type: "replan"))
            case .social(let value):
                containsExclusive = true
                guard unifiedEvidenceIsGrounded(value.evidence, in: message) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                let reply = value.reply.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard !reply.isEmpty else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(type: "social", reply: String(reply.prefix(120))))
            }
        }
        guard !result.isEmpty, result.count <= 16,
              !(containsExclusive && actions.count > 1),
              RuntimeGeneratedActions.areDistinct(result) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return result
    }

    private static func holisticTarget(
        _ value: TargetArgs,
        message: String,
        open: [RuntimeTask],
        focused: Set<Int>
    ) throws -> String {
        guard !open.isEmpty, (1...open.count).contains(value.targetIndex) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return try unifiedTarget(value, message: message, open: open, focused: focused)
    }

    private static func groundedHolisticDate(
        _ evidence: String,
        message: String
    ) throws -> RuntimeDateIntent? {
        let clean = normalizedGeneratedEvidence(evidence)
        guard clean.lowercased() != "none", !clean.isEmpty else { return nil }
        guard unifiedEvidenceIsGrounded(clean, in: message) else { return nil }
        return deterministicDateIntent(in: clean)
    }

    private static func groundedHolisticTime(
        _ evidence: String,
        interpretation: String,
        message: String
    ) -> String? {
        let clean = normalizedGeneratedEvidence(evidence)
        guard clean.lowercased() != "none" else { return nil }
        return RuntimeGeneratedClock.normalizeEvidence(
            clean,
            interpretation: explicitMeridiem(in: clean) ?? interpretation,
            in: message
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func validateUnified(
        _ turn: UnifiedTurn,
        message: String,
        open: [RuntimeTask],
        recentChange: Bool,
        focusedIndices: Set<Int>
    ) throws -> [RuntimeAction] {
        guard !turn.actions.isEmpty, turn.actions.count <= 16 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        if turn.actions.count == 1,
           let value = turn.actions.first,
           value.kind == "capture",
           let labels = structurallySeparateCoordinatedLabels(in: message),
           let clocks = coordinatedClockTexts(in: message) {
            let recurrence = recurrenceRule(value.recurrence, message: message)
            let sharedWhen = try unifiedDate(value.date, message: message)
                ?? recurrenceInitialDate(recurrence)
            let deadline = try unifiedDate(value.deadline, message: message)
            let captures = [labels.0, labels.1].enumerated().map { index, label in
                RuntimeAction(
                    type: "capture",
                    task: label.task,
                    raw: message,
                    when: sharedWhen,
                    deadline: deadline,
                    time: recoveredTime(
                        task: label.task,
                        evidence: label.evidence,
                        text: clocks[index],
                        interpretation: value.clockInterpretation,
                        originalMessage: message
                    ),
                    priority: "normal",
                    recurrence: recurrence,
                    confidence: 1
                )
            }
            guard captures.allSatisfy({ $0.time != nil }) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return captures
        }
        if turn.actions.count == 1,
           let continuation = conversationalContinuationCapture(
                message: message
           ) {
            return [continuation]
        }
        let exclusiveKinds = Set([
            "social", "acknowledge", "query", "analysis", "undo", "replan",
        ])
        if turn.actions.count > 1,
           turn.actions.contains(where: { exclusiveKinds.contains($0.kind) }) {
            throw RuntimeInterpretationError.invalidOutput
        }
        var result: [RuntimeAction] = []
        for value in turn.actions {
            switch value.kind {
            case "capture":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                let task = value.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty, task.utf8.count <= 10_000,
                      captureIsNew(task, evidence: value.evidence, open: open)
                else { throw RuntimeInterpretationError.invalidOutput }
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                let time = recoveredTime(
                    task: task,
                    evidence: value.evidence,
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                ) ?? deterministicSingleClock(in: message)
                if value.clockText.lowercased() != "none" && time == nil {
                    throw RuntimeInterpretationError.invalidOutput
                }
                let recurrence = recurrenceRule(value.recurrence, message: message)
                if value.recurrence.recurrenceFrequency != "none" && recurrence == nil {
                    throw RuntimeInterpretationError.invalidOutput
                }
                let statedDate = try unifiedDate(value.date, message: message)
                let statedDeadline = try unifiedDate(value.deadline, message: message)
                let fallbackDate = deterministicDateIntent(in: message)
                let deadlineLanguage = message.range(
                    of: #"\b(?:by|before|due)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
                result.append(RuntimeAction(
                    type: "capture",
                    task: task,
                    raw: message,
                    when: statedDate
                        ?? (deadlineLanguage ? nil : fallbackDate)
                        ?? recurrenceInitialDate(recurrence),
                    deadline: statedDeadline
                        ?? (deadlineLanguage ? fallbackDate : nil),
                    time: time,
                    durationMinutes: duration,
                    priority: ["high", "normal", "low"].contains(value.priority)
                            && unifiedEvidenceIsGrounded(
                                value.priorityEvidence, in: message
                            ) ? value.priority : "normal",
                    recurrence: recurrence,
                    confidence: 1
                ))
            case "complete":
                result.append(RuntimeAction(
                    type: "complete",
                    target: try unifiedTarget(
                        value.target,
                        message: message, open: open, focused: focusedIndices
                    )
                ))
            case "drop":
                result.append(RuntimeAction(
                    type: "drop",
                    target: try unifiedTarget(
                        value.target,
                        message: message, open: open, focused: focusedIndices
                    )
                ))
            case "keep":
                result.append(RuntimeAction(
                    type: "keep",
                    target: try unifiedTarget(
                        value.target,
                        message: message, open: open, focused: focusedIndices
                    )
                ))
            case "wait":
                result.append(RuntimeAction(
                    type: "wait",
                    target: try unifiedTarget(
                        value.target,
                        message: message, open: open, focused: focusedIndices
                    )
                ))
            case "resume":
                result.append(RuntimeAction(
                    type: "resume",
                    target: try unifiedTarget(
                        value.target,
                        message: message, open: open, focused: focusedIndices
                    )
                ))
            case "progress":
                let target = try unifiedTarget(
                    value.target,
                    message: message, open: open, focused: focusedIndices
                )
                guard unifiedEvidenceIsGrounded(value.note, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(type: "note", target: target, note: value.note))
            case "move":
                let target = try unifiedTarget(
                    value.target,
                    message: message, open: open, focused: focusedIndices
                )
                let when = try unifiedDate(value.date, message: message)
                let time = recoveredTime(
                    task: open[Int(target)! - 1].task,
                    evidence: value.target.evidence,
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                )
                guard when != nil || time != nil else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "reschedule", target: target, when: when, time: time
                ))
            case "revise":
                let target = try unifiedTarget(
                    value.target,
                    message: message, open: open, focused: focusedIndices
                )
                let title = unifiedEvidenceIsGrounded(
                    value.evidence, in: message
                ) ? value.task.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                let priority = unifiedEvidenceIsGrounded(
                    value.priorityEvidence, in: message
                ) && ["high", "normal", "low"].contains(value.priority)
                    ? value.priority : nil
                let time = recoveredTime(
                    task: open[Int(target)! - 1].task,
                    evidence: value.target.evidence,
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                )
                let allowedClear = Set(["date", "time", "deadline", "duration", "priority", "note"])
                let clear = Array(Set(value.clearFields).intersection(allowedClear)).sorted()
                let date = try unifiedDate(value.date, message: message)
                let deadline = try unifiedDate(value.deadline, message: message)
                guard !title.isEmpty || date != nil || deadline != nil || time != nil
                        || duration != nil || priority != nil || !clear.isEmpty else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "revise",
                    task: title.isEmpty ? nil : title,
                    target: target,
                    when: date,
                    deadline: deadline,
                    time: time,
                    durationMinutes: duration,
                    priority: priority,
                    clearFields: clear.isEmpty ? nil : clear
                ))
            case "note":
                let target = try unifiedTarget(
                    value.target,
                    message: message, open: open, focused: focusedIndices
                )
                guard unifiedEvidenceIsGrounded(value.note, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(type: "note", target: target, note: value.note))
            case "query":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      ["today", "date", "all", "overdue", "week", "search", "done", "waiting"].contains(value.queryKind)
                else { throw RuntimeInterpretationError.invalidOutput }
                let term = value.queryTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                let date = try unifiedDate(value.date, message: message)
                    ?? deterministicDateIntent(in: message)
                guard value.queryKind != "date" || date != nil,
                      value.queryKind != "search" || !term.isEmpty else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "query", when: date, queryKind: value.queryKind,
                    queryTerm: term.isEmpty ? nil : term,
                    queryPeriod: ["today", "week", "all"].contains(value.queryPeriod)
                        ? value.queryPeriod : nil
                ))
            case "analysis":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      ["capacity", "explain", "what_if"].contains(value.analysisKind),
                      value.targetIndex == 0 || (1...open.count).contains(value.targetIndex)
                else { throw RuntimeInterpretationError.invalidOutput }
                if value.analysisKind == "what_if" {
                    guard value.targetIndex > 0,
                          (5...480).contains(value.hypotheticalDurationMinutes),
                          RuntimeConstraintEvidence.isSupportedDuration(
                            value.durationEvidence, in: message
                          ) else { throw RuntimeInterpretationError.invalidOutput }
                }
                result.append(RuntimeAction(
                    type: "analysis",
                    target: value.targetIndex > 0 ? String(value.targetIndex) : nil,
                    analysisKind: value.analysisKind,
                    horizonDays: (1...31).contains(value.horizonDays)
                        ? value.horizonDays : 7,
                    budgetMinutes: (5...10_080).contains(value.budgetMinutes)
                        ? value.budgetMinutes : nil,
                    hypotheticalDurationMinutes: (5...480).contains(
                        value.hypotheticalDurationMinutes
                    ) ? value.hypotheticalDurationMinutes : nil
                ))
            case "bulk_complete":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      Set(value.excludedTargets).count == value.excludedTargets.count,
                      value.excludedTargets.allSatisfy({ (1...open.count).contains($0) })
                else { throw RuntimeInterpretationError.invalidOutput }
                let excluded = Set(value.excludedTargets)
                result += open.indices.compactMap { index in
                    excluded.contains(index + 1) ? nil
                        : RuntimeAction(type: "complete", target: String(index + 1))
                }
                if result.isEmpty { result = [RuntimeAction(type: "acknowledge")] }
            case "bulk_move":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      !value.destinations.isEmpty else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                var seen = Set<Int>()
                for destination in value.destinations {
                    guard (1...open.count).contains(destination.targetIndex),
                          seen.insert(destination.targetIndex).inserted else {
                        throw RuntimeInterpretationError.invalidOutput
                    }
                    result.append(try moveAction(destination, message: message))
                }
            case "recurrence":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message),
                      ["skip", "stop"].contains(value.recurrenceOperation),
                      (1...open.count).contains(value.targetIndex) else {
                    throw RuntimeInterpretationError.invalidOutput
                }
                result.append(RuntimeAction(
                    type: "recurrence", target: String(value.targetIndex),
                    recurrenceOperation: value.recurrenceOperation
                ))
            case "acknowledge":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                if value.responseKind == "conversation" {
                    let reply = value.reply == "none" || value.reply.isEmpty
                        ? "Anytime." : value.reply
                    result.append(RuntimeAction(type: "social", reply: reply))
                } else {
                    result.append(RuntimeAction(type: "acknowledge"))
                }
            case "undo":
                guard recentChange,
                      unifiedEvidenceIsGrounded(value.evidence, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(type: "undo"))
            case "replan":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(type: "replan"))
            case "social":
                guard unifiedEvidenceIsGrounded(value.evidence, in: message)
                else { throw RuntimeInterpretationError.invalidOutput }
                let reply = value.reply.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard !reply.isEmpty else { throw RuntimeInterpretationError.invalidOutput }
                result.append(RuntimeAction(
                    type: "social", reply: String(reply.prefix(120))
                ))
            default:
                throw RuntimeInterpretationError.invalidOutput
            }
        }
        result.sort { lhs, rhs in
            guard lhs.type == "capture", rhs.type == "capture",
                  let left = lhs.task, let right = rhs.task else { return false }
            return taskPosition(left, in: message) < taskPosition(right, in: message)
        }
        guard !result.isEmpty, result.count <= 16,
              RuntimeGeneratedActions.areDistinct(result) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return result
    }

    private static func unifiedTarget(
        _ value: TargetArgs,
        message: String,
        open: [RuntimeTask],
        focused: Set<Int>
    ) throws -> String {
        let grounded = TargetArgs(
            targetIndex: value.targetIndex,
            evidence: normalizedGeneratedEvidence(value.evidence)
        )
        guard let target = resolvedTarget(
            grounded, message: message, open: open, focused: focused
        ) else { throw RuntimeInterpretationError.invalidOutput }
        return String(target)
    }

    private static func validate(
        _ rawProposals: [Proposal],
        message: String,
        open: [RuntimeTask],
        recentChange: Bool,
        focusedIndices: Set<Int> = [],
        newObligationConfirmed: Bool = false
    ) async throws -> [RuntimeAction] {
        guard !rawProposals.isEmpty, rawProposals.count <= 32 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let proposals = rawProposals.sorted { lhs, rhs in
            guard case .capture(let left) = lhs, case .capture(let right) = rhs,
                  let leftRange = message.range(
                    of: left.evidence, options: [.caseInsensitive, .diacriticInsensitive]
                  ),
                  let rightRange = message.range(
                    of: right.evidence, options: [.caseInsensitive, .diacriticInsensitive]
                  ) else { return false }
            return leftRange.lowerBound < rightRange.lowerBound
        }
        if let query = proposals.compactMap({ proposal -> QueryArgs? in
            if case .query(let value) = proposal { return value }
            return nil
        }).first {
            guard RuntimeConstraintEvidence.contains(query.evidence, in: message),
                  ["today", "date", "all", "overdue", "week", "search", "done", "waiting"].contains(query.kind)
            else { throw RuntimeInterpretationError.invalidOutput }
            let term = query.term.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.kind == "search" && term.isEmpty {
                throw RuntimeInterpretationError.invalidOutput
            }
            let when = RuntimeConstraintEvidence.contains(
                query.date.dateEvidence, in: message
            ) ? try dateIntent(
                kind: query.date.dateKind,
                weekday: query.date.dateWeekday,
                which: query.date.dateWhich,
                n: query.date.dateN,
                unit: query.date.dateUnit,
                part: query.date.datePart,
                anchor: query.date.dateAnchor,
                year: query.date.dateYear,
                month: query.date.dateMonth,
                day: query.date.dateDay,
                evidence: query.date.dateEvidence
            ) : nil
            guard query.kind != "date" || when != nil else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return [RuntimeAction(
                type: "query",
                when: when,
                queryKind: query.kind,
                queryTerm: term.isEmpty ? nil : term,
                queryPeriod: ["today", "week", "all"].contains(query.period)
                    ? query.period : nil
            )]
        }
        if let analysis = proposals.compactMap({ proposal -> AnalysisArgs? in
            if case .analysis(let value) = proposal { return value }
            return nil
        }).first {
            guard RuntimeConstraintEvidence.contains(analysis.evidence, in: message),
                  ["capacity", "explain", "what_if"].contains(analysis.kind),
                  (analysis.budgetMinutes == 0
                    || (5...10_080).contains(analysis.budgetMinutes)),
                  (analysis.targetIndex == 0
                    || (1...open.count).contains(analysis.targetIndex))
            else { throw RuntimeInterpretationError.invalidOutput }
            let hypothetical = analysis.hypotheticalDurationMinutes
            if analysis.kind == "what_if" {
                guard analysis.targetIndex > 0,
                      (5...480).contains(hypothetical),
                      RuntimeConstraintEvidence.isSupportedDuration(
                        analysis.durationEvidence, in: message
                      ) else { throw RuntimeInterpretationError.invalidOutput }
            }
            let horizon = (1...31).contains(analysis.horizonDays)
                ? analysis.horizonDays : 7
            return [RuntimeAction(
                type: "analysis",
                target: analysis.kind == "capacity" ? nil
                    : (analysis.targetIndex > 0 ? String(analysis.targetIndex) : nil),
                analysisKind: analysis.kind,
                horizonDays: horizon,
                budgetMinutes: analysis.budgetMinutes > 0
                    ? analysis.budgetMinutes : nil,
                hypotheticalDurationMinutes: hypothetical > 0 ? hypothetical : nil
            )]
        }
        if let bulk = proposals.compactMap({ proposal -> BulkCompleteArgs? in
            if case .bulkComplete(let value) = proposal { return value }
            return nil
        }).first, try await bulkCompletionAudit(message) {
            guard RuntimeConstraintEvidence.contains(bulk.evidence, in: message),
                  Set(bulk.excludedTargets).count == bulk.excludedTargets.count,
                  bulk.excludedTargets.allSatisfy({ (1...open.count).contains($0) })
            else { throw RuntimeInterpretationError.invalidOutput }
            let written = explicitNumbers(in: bulk.evidence)
            let excluded = written.isEmpty ? Set(bulk.excludedTargets) : written
            let result = open.indices.compactMap { index in
                excluded.contains(index + 1) ? nil
                    : RuntimeAction(type: "complete", target: String(index + 1))
            }
            return result.isEmpty ? [RuntimeAction(type: "acknowledge")] : result
        }
        let individualCompletions = proposals.compactMap { proposal -> TargetArgs? in
            if case .complete(let value) = proposal { return value }; return nil
        }
        if individualCompletions.count >= 2 {
            let referenced = explicitNumbers(in: message).filter {
                (1...open.count).contains($0)
            }
            if !referenced.isEmpty {
                let result = open.indices.compactMap { index in
                    referenced.contains(index + 1) ? nil
                        : RuntimeAction(type: "complete", target: String(index + 1))
                }
                if !result.isEmpty { return result }
            }
        }
        if let bulk = proposals.compactMap({ proposal -> BulkMoveArgs? in
            if case .bulkMove(let value) = proposal { return value }
            return nil
        }).first {
            let destinations = bulk.destinations.filter {
                (1...open.count).contains($0.targetIndex)
            }
            guard RuntimeConstraintEvidence.contains(bulk.evidence, in: message),
                  !destinations.isEmpty
            else { throw RuntimeInterpretationError.invalidOutput }
            var used = Set<Int>()
            let result = try destinations.filter {
                used.insert($0.targetIndex).inserted
            }.map { value in
                return try moveAction(value, message: message)
            }
            guard result.allSatisfy({ $0.when != nil || $0.time != nil }) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return result
        }

        var result: [RuntimeAction] = []
        var harmless = false
        for proposal in proposals {
            switch proposal {
            case .acknowledge, .progress:
                harmless = true
            case .undo:
                if recentChange { result.append(RuntimeAction(type: "undo")) }
                else { harmless = true }
            case .replan:
                result.append(RuntimeAction(type: "replan"))
            case .capture(let value):
                guard RuntimeConstraintEvidence.contains(value.evidence, in: message) else {
                    continue
                }
                let task = value.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty, task.utf8.count <= 10_000,
                      captureIsNew(
                        task, evidence: value.evidence, open: open,
                        allowSemanticEvidence: newObligationConfirmed
                      )
                else { continue }
                if !open.isEmpty, !newObligationConfirmed {
                    let approved = try await captureAudit(
                        task: task, evidence: value.evidence, message: message
                    )
                    if !approved { continue }
                }
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                // Foundation Models may serialize generations internally. Keep
                // these small semantic passes ordered so one cannot starve the
                // other and silently discard a date or recurrence.
                let refinedDate = try? await refineOccurrenceDate(message)
                let refinedRecurrence = try? await refineRecurrence(message)
                var recurrence = recurrenceRule(value, message: message)
                if recurrence == nil, let refined = refinedRecurrence {
                    recurrence = recurrenceRule(refined, message: message)
                }
                if recurrence == nil {
                    recurrence = try? await auditedRecurrenceRule(message)
                }
                let statedWhen: RuntimeDateIntent?
                if RuntimeConstraintEvidence.contains(
                    value.scheduleEvidence, in: message
                ) {
                    statedWhen = try dateIntent(
                        kind: value.scheduleKind, weekday: value.scheduleWeekday,
                        which: value.scheduleWhich, n: value.scheduleN,
                        unit: value.scheduleUnit, part: value.schedulePart,
                        anchor: value.scheduleAnchor, year: value.scheduleYear,
                        month: value.scheduleMonth, day: value.scheduleDay,
                        evidence: value.scheduleEvidence
                    )
                } else if let refined = refinedDate,
                          RuntimeConstraintEvidence.contains(
                            refined.dateEvidence, in: message
                          ) {
                    statedWhen = try? dateIntent(
                        kind: refined.dateKind, weekday: refined.dateWeekday,
                        which: refined.dateWhich, n: refined.dateN,
                        unit: refined.dateUnit, part: refined.datePart,
                        anchor: refined.dateAnchor, year: refined.dateYear,
                        month: refined.dateMonth, day: refined.dateDay,
                        evidence: refined.dateEvidence
                    )
                } else {
                    statedWhen = nil
                }
                var recoveredClock = recoveredTime(
                    task: task, evidence: value.evidence,
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                )
                if explicitMeridiem(in: message) == nil {
                    if let auditedClock = try? await refineSingleClock(message) {
                        recoveredClock = auditedClock
                    }
                } else if recoveredClock == nil {
                    recoveredClock = try? await refineSingleClock(message)
                }
                result.append(RuntimeAction(
                    type: "capture", task: task, raw: message,
                    when: statedWhen ?? recurrenceInitialDate(recurrence),
                    deadline: RuntimeConstraintEvidence.contains(
                        value.deadlineEvidence, in: message
                    ) ? try dateIntent(
                        kind: value.deadlineKind, weekday: value.deadlineWeekday,
                        which: value.deadlineWhich, n: value.deadlineN,
                        unit: value.deadlineUnit, part: value.deadlinePart,
                        anchor: value.deadlineAnchor, year: value.deadlineYear,
                        month: value.deadlineMonth, day: value.deadlineDay,
                        evidence: value.deadlineEvidence
                    ) : nil,
                    time: recoveredClock,
                    durationMinutes: duration,
                    priority: ["high", "normal", "low"].contains(value.priority)
                        ? value.priority : "normal",
                    recurrence: recurrence,
                    confidence: 1
                ))
            case .complete(let value):
                guard let target = resolvedTarget(
                    value, message: message, open: open, focused: focusedIndices
                ), !hasConflictingProposal(
                    target: target, proposals: proposals,
                    message: message, open: open
                ),
                      try await audit(
                        "fully completed", target: target,
                        message: message, open: open
                      ) else { continue }
                result.append(RuntimeAction(
                    type: "complete", target: String(target)
                ))
            case .drop(let value):
                guard let target = resolvedTarget(
                    value, message: message, open: open, focused: focusedIndices
                ) else { continue }
                let explicit = explicitReferencedTarget(
                    value.evidence, openCount: open.count
                ) == target
                var approved = explicit
                if !approved {
                    approved = try await audit(
                        "explicitly requested to be dropped, removed, deleted, or cancelled",
                        target: target, message: message, open: open
                    )
                }
                guard approved else { continue }
                result.append(RuntimeAction(type: "drop", target: String(target)))
            case .move(let value):
                guard let target = resolvedTarget(
                    value.target, message: message, open: open, focused: focusedIndices
                ) else { continue }
                let focusedFollowUp = focusedIndices.contains(target)
                    && !Set(["it", "that", "this"])
                        .isDisjoint(with: Set(words(message)))
                let moveApproved: Bool
                if focusedFollowUp {
                    moveApproved = true
                } else {
                    moveApproved = try await audit(
                        "scheduled or moved to a stated date or time",
                        target: target, message: message, open: open
                    )
                }
                guard moveApproved else { continue }
                var destination = value.destination
                destination.targetIndex = target
                if destination.scheduleKind != "none",
                   !RuntimeConstraintEvidence.contains(
                    destination.dateEvidence, in: message
                   ) { continue }
                let initial = try moveAction(destination, message: message)
                let recovered = initial.time ?? recoveredTime(
                        task: open[target - 1].task,
                        evidence: value.target.evidence,
                        text: destination.clockText,
                        interpretation: destination.clockInterpretation,
                        originalMessage: message
                    )
                let action = RuntimeAction(
                    type: initial.type, target: initial.target,
                    when: initial.when, time: recovered,
                    confidence: initial.confidence
                )
                guard action.when != nil || action.time != nil else { continue }
                result.append(action)
            case .amend(let value):
                guard supports(
                    value.target, message: message, open: open,
                    focused: focusedIndices
                ) else { continue }
                let task = value.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { continue }
                result.append(RuntimeAction(
                    type: "amend", task: task, target: String(value.target.targetIndex)
                ))
            case .revise(let value):
                guard supports(
                    value.target, message: message, open: open,
                    focused: focusedIndices
                ), RuntimeConstraintEvidence.contains(value.evidence, in: message)
                else { continue }
                let title = RuntimeConstraintEvidence.contains(
                    value.taskEvidence, in: message
                ) ? value.task.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let occurrence = RuntimeConstraintEvidence.contains(
                    value.date.dateEvidence, in: message
                ) ? try dateIntent(
                    kind: value.date.dateKind, weekday: value.date.dateWeekday,
                    which: value.date.dateWhich, n: value.date.dateN,
                    unit: value.date.dateUnit, part: value.date.datePart,
                    anchor: value.date.dateAnchor, year: value.date.dateYear,
                    month: value.date.dateMonth, day: value.date.dateDay,
                    evidence: value.date.dateEvidence
                ) : nil
                let deadline = RuntimeConstraintEvidence.contains(
                    value.deadline.dateEvidence, in: message
                ) ? try dateIntent(
                    kind: value.deadline.dateKind,
                    weekday: value.deadline.dateWeekday,
                    which: value.deadline.dateWhich,
                    n: value.deadline.dateN,
                    unit: value.deadline.dateUnit,
                    part: value.deadline.datePart,
                    anchor: value.deadline.dateAnchor,
                    year: value.deadline.dateYear,
                    month: value.deadline.dateMonth,
                    day: value.deadline.dateDay,
                    evidence: value.deadline.dateEvidence
                ) : nil
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                let time = recoveredTime(
                    task: open[value.target.targetIndex - 1].task,
                    evidence: value.evidence,
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                )
                let priority = RuntimeConstraintEvidence.contains(
                    value.priorityEvidence, in: message
                ) && ["high", "normal", "low"].contains(value.priority)
                    ? value.priority : nil
                let allowedClear = Set(["date", "time", "deadline", "duration", "priority", "note"])
                let clear = Array(Set(value.clearFields).intersection(allowedClear)).sorted()
                guard !title.isEmpty || occurrence != nil || deadline != nil
                        || duration != nil || time != nil || priority != nil
                        || !clear.isEmpty else { continue }
                result.append(RuntimeAction(
                    type: "revise",
                    task: title.isEmpty ? nil : title,
                    target: String(value.target.targetIndex),
                    when: occurrence,
                    deadline: deadline,
                    time: time,
                    durationMinutes: duration,
                    priority: priority,
                    clearFields: clear
                ))
            case .priority(let value):
                let target = uniquelyGroundedTarget(message: message, open: open)
                    ?? value.target.targetIndex
                guard (uniquelyGroundedTarget(message: message, open: open) != nil
                        || supports(
                            value.target, message: message, open: open,
                            focused: focusedIndices
                        )),
                      (RuntimeConstraintEvidence.contains(value.evidence, in: message)
                        || Set(words(message)).contains(value.level)),
                      ["high", "normal", "low"].contains(value.level)
                else { continue }
                result.append(RuntimeAction(
                    type: "revise", target: String(target),
                    priority: value.level
                ))
            case .duration(let value):
                let target = uniquelyGroundedTarget(message: message, open: open)
                    ?? value.target.targetIndex
                guard (uniquelyGroundedTarget(message: message, open: open) != nil
                        || supports(
                            value.target, message: message, open: open,
                            focused: focusedIndices
                        )), (5...480).contains(value.minutes),
                      (RuntimeConstraintEvidence.isSupportedDuration(
                        value.evidence, in: message
                      ) || groundedDuration(value.minutes, in: message))
                else { continue }
                result.append(RuntimeAction(
                    type: "revise", target: String(target),
                    durationMinutes: value.minutes
                ))
            case .clearField(let value):
                guard supports(
                    value.target, message: message, open: open,
                    focused: focusedIndices
                ), RuntimeConstraintEvidence.contains(value.evidence, in: message),
                      ["date", "time", "deadline", "duration", "priority", "note"].contains(value.field)
                else { continue }
                result.append(RuntimeAction(
                    type: "revise", target: String(value.target.targetIndex),
                    clearFields: [value.field]
                ))
            case .note(let value):
                let target = uniquelyGroundedTarget(message: message, open: open)
                    ?? value.target.targetIndex
                guard (uniquelyGroundedTarget(message: message, open: open) != nil
                    || supports(
                    value.target, message: message, open: open,
                    focused: focusedIndices
                )), RuntimeConstraintEvidence.contains(value.text, in: message)
                else { continue }
                let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result.append(RuntimeAction(
                        type: "note", target: String(target), note: text
                    ))
                }
            case .wait(let value):
                let target = uniquelyGroundedTarget(message: message, open: open)
                    ?? value.targetIndex
                guard (uniquelyGroundedTarget(message: message, open: open) != nil
                    || supports(
                    value, message: message, open: open,
                    focused: focusedIndices
                )) else { continue }
                result.append(RuntimeAction(type: "wait", target: String(target)))
            case .resume(let value):
                let target = uniquelyGroundedTarget(message: message, open: open)
                    ?? value.targetIndex
                guard (uniquelyGroundedTarget(message: message, open: open) != nil
                    || supports(
                    value, message: message, open: open,
                    focused: focusedIndices
                )), (1...open.count).contains(target), open[target - 1].isWaiting
                else { continue }
                result.append(RuntimeAction(type: "resume", target: String(target)))
            case .keep(let value):
                guard supports(value, message: message, open: open) else { continue }
                result.append(RuntimeAction(type: "keep", target: String(value.targetIndex)))
            case .recurrence(let value):
                guard RuntimeConstraintEvidence.contains(value.evidence, in: message),
                      (1...open.count).contains(value.targetIndex),
                      open[value.targetIndex - 1].recurrence != nil,
                      ["skip", "stop"].contains(value.operation) else { continue }
                result.append(RuntimeAction(
                    type: "recurrence", target: String(value.targetIndex),
                    recurrenceOperation: value.operation
                ))
            case .bulkComplete, .bulkMove, .analysis, .query:
                break
            }
        }
        if result.contains(where: { ["undo", "replan"].contains($0.type) }),
           result.count != 1 { throw RuntimeInterpretationError.invalidOutput }
        if result.isEmpty, harmless {
            let progress = proposals.compactMap { proposal -> TargetArgs? in
                if case .progress(let value) = proposal { return value }; return nil
            }
            if recentChange, !progress.isEmpty,
               progress.allSatisfy({ !hasTaskWord($0.evidence, open: open) }),
               try await retractionAudit(message) {
                return [RuntimeAction(type: "undo")]
            }
            return [RuntimeAction(type: "acknowledge")]
        }
        var seen = Set<String>()
        result = result.filter { action in
            var parts = [
                action.type, action.target ?? "", action.task ?? "",
                action.when.map(String.init(describing:)) ?? "",
                action.deadline.map(String.init(describing:)) ?? "",
                action.time ?? "",
            ]
            parts.append(action.durationMinutes.map(String.init) ?? "")
            parts.append(action.priority ?? "")
            parts.append(action.note ?? "")
            parts.append(action.clearFields?.joined(separator: ",") ?? "")
            let signature = parts.joined(separator: "|")
            return seen.insert(signature).inserted
        }
        result.sort { lhs, rhs in
            guard lhs.type == "capture", rhs.type == "capture",
                  let left = lhs.task, let right = rhs.task else { return false }
            return taskPosition(left, in: message) < taskPosition(right, in: message)
        }
        guard !result.isEmpty, result.count <= 16,
              RuntimeGeneratedActions.areDistinct(result) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return result
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func audit(
        _ operation: String,
        target: Int,
        message: String,
        open: [RuntimeTask]
    ) async throws -> Bool {
        guard (1...open.count).contains(target) else { return false }
        for _ in 0..<2 {
            let response = try await LanguageModelSession(instructions: """
            Independently verify one proposed task effect. Reply exactly YES only
            if the user's own words clearly say the current task was \(operation).
            Reply NO for progress, negation, exclusion, scheduling, mention,
            ambiguity, or any other meaning. Respect shared grammar and numbers.
            """).respond(to: """
            Open tasks: \(open.enumerated().map { "\($0.offset + 1). \($0.element.task)" })
            Current task: \(target). \(open[target - 1].task)
            User message: \(message)
            """)
            let firstWord = response.content.uppercased().split {
                !$0.isLetter
            }.first.map(String.init)
            if firstWord != "YES" { return false }
        }
        return true
    }

    private static func supports(
        _ value: TargetArgs,
        message: String,
        open: [RuntimeTask],
        focused: Set<Int> = []
    ) -> Bool {
        guard (1...open.count).contains(value.targetIndex) else { return false }
        let messageWords = Set(informativeWords(message))
        let groundedMatches = open.indices.filter { index in
            let taskWords = Set(informativeWords(open[index].task))
            return !taskWords.isDisjoint(with: messageWords)
        }
        if groundedMatches == [value.targetIndex - 1] { return true }
        guard RuntimeConstraintEvidence.contains(value.evidence, in: message)
        else { return false }
        if open.count == 1 { return true }
        let evidence = Set(words(value.evidence))
        let task = Set(informativeWords(open[value.targetIndex - 1].task))
        if !task.isDisjoint(with: evidence) { return true }
        if evidence.contains(String(value.targetIndex)) { return true }
        let deictic = !Set(["it", "that", "this", "one", "them"])
            .isDisjoint(with: evidence)
        if deictic && focused.contains(value.targetIndex) { return true }
        let ordinals = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
        ]
        return ordinals[value.targetIndex].map(evidence.contains) ?? false
    }

    private static func uniquelyGroundedTarget(
        message: String,
        open: [RuntimeTask]
    ) -> Int? {
        let messageWords = Set(informativeWords(message))
        let matches = open.indices.filter { index in
            let taskWords = Set(informativeWords(open[index].task))
            return !taskWords.isDisjoint(with: messageWords)
        }
        return matches.count == 1 ? matches[0] + 1 : nil
    }

    private static func informativeWords(_ text: String) -> [String] {
        let ignored = Set([
            "the", "and", "for", "with", "from", "that", "this", "then",
            "into", "onto", "task", "item", "one",
        ])
        return words(text).filter { $0.count >= 3 && !ignored.contains($0) }
    }

    private static func resolvedTarget(
        _ value: TargetArgs,
        message: String,
        open: [RuntimeTask],
        focused: Set<Int> = []
    ) -> Int? {
        let evidenceWords = Set(words(value.evidence))
        let ordinals = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
        ]
        let explicit = (1...min(open.count, 10)).filter { index in
            evidenceWords.contains(String(index))
                || ordinals[index].map(evidenceWords.contains) == true
        }
        if explicit.count == 1 { return explicit[0] }
        let deicticWords = evidenceWords.union(words(message))
        let deictic = !Set(["it", "that", "this", "one", "them"])
            .isDisjoint(with: deicticWords)
        if deictic, focused.count == 1 { return focused.first }
        if supports(
            value, message: message, open: open, focused: focused
        ) { return value.targetIndex }
        guard RuntimeConstraintEvidence.contains(value.evidence, in: message) else {
            return nil
        }
        let evidence = Set(words(value.evidence))
        let matches = open.indices.filter { index in
            let task = Set(words(open[index].task).filter { $0.count >= 3 })
            return !task.isDisjoint(with: evidence)
        }
        return matches.count == 1 ? matches[0] + 1 : nil
    }

    private static func explicitReferencedTarget(
        _ evidence: String,
        openCount: Int
    ) -> Int? {
        let evidenceWords = Set(words(evidence))
        let ordinals = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
        ]
        let matches = (1...min(openCount, 10)).filter { index in
            evidenceWords.contains(String(index))
                || ordinals[index].map(evidenceWords.contains) == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func hasConflictingProposal(
        target: Int,
        proposals: [Proposal],
        message: String,
        open: [RuntimeTask]
    ) -> Bool {
        proposals.contains { proposal in
            let candidate: TargetArgs?
            switch proposal {
            case .progress(let value), .drop(let value), .keep(let value): candidate = value
            case .move(let value): candidate = value.target
            case .amend(let value): candidate = value.target
            default: candidate = nil
            }
            return candidate.flatMap {
                resolvedTarget($0, message: message, open: open)
            } == target
        }
    }

    private static func captureIsNew(
        _ task: String,
        evidence: String,
        open: [RuntimeTask],
        allowSemanticEvidence: Bool = false
    ) -> Bool {
        let taskWords = Set(words(task).filter { $0.count >= 3 })
        let evidenceWords = Set(words(evidence).filter { $0.count >= 3 })
        guard !taskWords.isEmpty,
              allowSemanticEvidence || !taskWords.isDisjoint(with: evidenceWords) else {
            return false
        }
        return !open.contains { existing in
            let existingWords = Set(words(existing.task).filter { $0.count >= 3 })
            return !taskWords.isEmpty && taskWords.isSubset(of: existingWords)
        }
    }

    private static func explicitNumbers(in text: String) -> Set<Int> {
        Set(text.split { !$0.isNumber }.compactMap { Int($0) })
    }

    private static func groundedDuration(_ minutes: Int, in message: String) -> Bool {
        let tokens = Set(words(message))
        let hasUnit = !Set([
            "m", "min", "mins", "minute", "minutes",
            "h", "hr", "hrs", "hour", "hours",
        ]).isDisjoint(with: tokens)
        return hasUnit && explicitNumbers(in: message).contains(minutes)
    }

    private static func hasTaskWord(_ evidence: String, open: [RuntimeTask]) -> Bool {
        let evidenceWords = Set(words(evidence))
        return open.contains { task in
            !Set(words(task.task).filter { $0.count >= 3 }).isDisjoint(with: evidenceWords)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func retractionAudit(_ message: String) async throws -> Bool {
        let response = try await LanguageModelSession().respond(to: """
        The task assistant just made the user's requested change. Does this next
        message withdraw that request and ask to undo it? Answer yes or no, then
        explain briefly. User message: \(message)
        """)
        return response.content.uppercased().split { !$0.isLetter }.first
            .map(String.init) == "YES"
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func captureAudit(
        task: String,
        evidence: String,
        message: String
    ) async throws -> Bool {
        for _ in 0..<2 {
            let response = try await LanguageModelSession().respond(to: """
            Does the user's message clearly express a genuinely new actionable
            obligation matching "\(task)"? Answer yes or no, then explain. A
            status report, slang reaction, existing-task effect, or quoted context
            is not a new obligation.
            User message: \(message)
            Proposed supporting words: \(evidence)
            """)
            if response.content.uppercased().split(whereSeparator: {
                !$0.isLetter
            }).first.map(String.init) != "YES" { return false }
        }
        return true
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractNewCaptures(
        message: String,
        now: String,
        timezone: String
    ) async throws -> [CaptureArgs] {
        for _ in 0..<2 {
            do {
                let response = try await LanguageModelSession(
                    instructions: """
                    Extract every genuinely new obligation into the returned
                    list, with one item per distinct task or appointment. Pair
                    coordinated people or objects with coordinated dates and
                    clocks in order. Preserve the user's spelling in each task
                    label; do not correct or paraphrase it. Keep conjunctions,
                    dates, clocks, and other constraints out of task labels.
                    Return an empty list for a question, reply, status report,
                    or replan request.
                    """
                ).respond(to: """
                    Current instant: \(now)
                    Timezone: \(timezone)
                    User message: \(message)
                    """, generating: CaptureBatchArgs.self)
                let result = response.content.tasks
                if !result.isEmpty { return result }
            } catch {}
        }
        return []
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func refineCoordinatedCapture(
        _ initial: CaptureArgs,
        message: String,
        now: String,
        timezone: String
    ) async throws -> [CaptureArgs]? {
        if clockCandidateCount(in: message) == 2 {
            var confirmedPair: CoordinatedClockPairArgs?
            for _ in 0..<4 {
                do {
                    let response = try await LanguageModelSession(
                        instructions: """
                        Classify how two clock expressions work in the user's
                        sentence. A time range belongs to one obligation. Two
                        coordinated appointments paired in order, including with
                        "respectively", are two obligations. For two appointments,
                        isolate each label and its exact single clock. Never put
                        both people, both objects, or both clocks in one label.
                        """
                    ).respond(to: """
                        Current instant: \(now)
                        Timezone: \(timezone)
                        User message: \(message)
                        Initial merged task: \(initial.task)
                        """, generating: CoordinatedClockPairArgs.self)
                    if response.content.kind == "one_time_range" { continue }
                    let pair = response.content
                    confirmedPair = pair
                    if let labels = structurallySeparateCoordinatedLabels(in: message) {
                        let items = [
                            CaptureDecompositionItem(
                                task: labels.0.task,
                                evidence: labels.0.evidence,
                                clockText: pair.firstClockText,
                                clockInterpretation: pair.firstClockInterpretation
                            ),
                            CaptureDecompositionItem(
                                task: labels.1.task,
                                evidence: labels.1.evidence,
                                clockText: pair.secondClockText,
                                clockInterpretation: pair.secondClockInterpretation
                            ),
                        ]
                        let result = items.map { capture($0, inheriting: initial) }
                        if coordinatedCapturesAreOrdered(result, message: message),
                           !coordinatedCapturesNeedReview(result) {
                            return result
                        }
                    }
                    guard let firstLabel = try await isolateCoordinatedLabel(
                        position: "first", message: message
                    ), let secondLabel = try await isolateCoordinatedLabel(
                        position: "second", message: message
                    ), coordinatedLabelsAreOrdered(
                        firstLabel, secondLabel: secondLabel, message: message
                    ) else { continue }
                    let labels = separateCoordinatedLabels(
                        firstLabel, secondLabel: secondLabel, message: message
                    )
                    let items = [
                        CaptureDecompositionItem(
                            task: labels.0.task,
                            evidence: labels.0.evidence,
                            clockText: pair.firstClockText,
                            clockInterpretation: pair.firstClockInterpretation
                        ),
                        CaptureDecompositionItem(
                            task: labels.1.task,
                            evidence: labels.1.evidence,
                            clockText: pair.secondClockText,
                            clockInterpretation: pair.secondClockInterpretation
                        ),
                    ]
                    let result = items.map {
                        capture($0, inheriting: initial)
                    }
                    if !coordinatedCapturesNeedReview(result) { return result }
                } catch {}
            }
            if let pair = confirmedPair,
               let labels = structurallySeparateCoordinatedLabels(in: message) {
                let items = [
                    CaptureDecompositionItem(
                        task: labels.0.task,
                        evidence: labels.0.evidence,
                        clockText: pair.firstClockText,
                        clockInterpretation: pair.firstClockInterpretation
                    ),
                    CaptureDecompositionItem(
                        task: labels.1.task,
                        evidence: labels.1.evidence,
                        clockText: pair.secondClockText,
                        clockInterpretation: pair.secondClockInterpretation
                    ),
                ]
                let result = items.map { capture($0, inheriting: initial) }
                if coordinatedCapturesAreOrdered(result, message: message),
                   !coordinatedCapturesNeedReview(result) {
                    return result
                }
            }
        }
        for _ in 0..<4 {
            do {
                let response = try await LanguageModelSession(
                    instructions: """
                    Audit a possibly merged new-task extraction. Return the
                    complete final set of distinct obligations. A clause shaped
                    like "meet A and B at X and Y
                    respectively" contains two appointments: A at X, then B at
                    Y. Apply that grammar generally. Keep constraints out of task
                    labels. A real time range can remain one task. Never invent.
                    """
                ).respond(to: """
                    Current instant: \(now)
                    Timezone: \(timezone)
                    User message: \(message)
                    Initial task: \(initial.task)
                    Initial clock: \(initial.clockText)
                    """, generating: CaptureDecompositionArgs.self)
                let result = response.content.tasks.map {
                    capture($0, inheriting: initial)
                }
                if result.count == 2,
                   coordinatedCapturesAreOrdered(result, message: message),
                   !coordinatedCapturesNeedReview(result) { return result }
            } catch {}
        }
        return nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func isolateCoordinatedLabel(
        position: String,
        message: String
    ) async throws -> GroundedCaptureLabel? {
        for _ in 0..<4 {
            do {
                let response = try await LanguageModelSession(
                    instructions: """
                    The sentence contains two coordinated appointments in order.
                    Return only the \(position) appointment's short action label
                    and exact naming words. In "meet A and B at X and Y
                    respectively", the first label is "Meet A" and the second is
                    "Meet B". Exclude the other appointment and every clock.
                    """
                ).respond(
                    to: "User message: \(message)",
                    generating: CaptureLabelArgs.self
                )
                let task = response.content.task.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if let grounded = groundedLabel(task, in: message),
                   clockCandidateCount(in: task) == 0 {
                    return grounded
                }
            } catch {}
        }
        return nil
    }

    private static func groundedLabel(
        _ task: String,
        in message: String
    ) -> GroundedCaptureLabel? {
        let taskWords = words(task).filter { $0.count >= 3 }
        guard !taskWords.isEmpty else { return nil }
        let matches = taskWords.compactMap { word -> (String.Index, String)? in
            guard let range = message.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive]
            ) else { return nil }
            return (range.lowerBound, String(message[range]))
        }
        guard matches.count * 2 >= taskWords.count,
              let anchor = matches.max(by: { $0.0 < $1.0 })?.1
        else { return nil }
        return GroundedCaptureLabel(task: task, evidence: anchor)
    }

    private static func coordinatedLabelsAreOrdered(
        _ firstLabel: GroundedCaptureLabel,
        secondLabel: GroundedCaptureLabel,
        message: String
    ) -> Bool {
        guard let firstRange = message.range(
            of: firstLabel.evidence,
            options: [.caseInsensitive, .diacriticInsensitive]
        ), let secondRange = message.range(
            of: secondLabel.evidence,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return false }
        return firstRange.lowerBound < secondRange.lowerBound
    }

    private static func separateCoordinatedLabels(
        _ firstLabel: GroundedCaptureLabel,
        secondLabel: GroundedCaptureLabel,
        message: String
    ) -> (GroundedCaptureLabel, GroundedCaptureLabel) {
        let firstWords = words(firstLabel.task).filter { $0.count >= 3 }
        let secondWords = words(secondLabel.task).filter { $0.count >= 3 }
        var sharedPrefixCount = 0
        while sharedPrefixCount < min(firstWords.count, secondWords.count),
              firstWords[sharedPrefixCount] == secondWords[sharedPrefixCount] {
            sharedPrefixCount += 1
        }
        let distinctiveSecondWords = Set(secondWords.dropFirst(sharedPrefixCount))
        guard !distinctiveSecondWords.isEmpty else {
            return (firstLabel, secondLabel)
        }
        let matches = distinctiveSecondWords.compactMap { word in
            firstLabel.task.range(
                of: word, options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        guard matches.count * 2 >= distinctiveSecondWords.count,
              let cut = matches.min(by: { $0.lowerBound < $1.lowerBound })?.lowerBound,
              cut > firstLabel.task.startIndex
        else { return (firstLabel, secondLabel) }
        let candidate = String(firstLabel.task[..<cut])
            .replacingOccurrences(
                of: #"\b(?:and|then|plus)\s*$"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let grounded = groundedLabel(candidate, in: message) else {
            return (firstLabel, secondLabel)
        }
        return (grounded, secondLabel)
    }

    private static func structurallySeparateCoordinatedLabels(
        in message: String
    ) -> (GroundedCaptureLabel, GroundedCaptureLabel)? {
        let clockPattern = #"\b(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))\b"#
        guard let clockRegex = try? NSRegularExpression(
            pattern: clockPattern, options: [.caseInsensitive]
        ) else { return nil }
        let nsMessage = message as NSString
        let clockMatches = clockRegex.matches(
            in: message,
            range: NSRange(location: 0, length: nsMessage.length)
        )
        guard clockMatches.count == 2 else { return nil }
        var subjects = nsMessage.substring(
            with: NSRange(location: 0, length: clockMatches[0].range.location)
        )
        subjects = subjects.replacingOccurrences(
            of: #"\b(?:at|around|about|by)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = try? NSRegularExpression(
            pattern: #"\s+(?:and|then|&)\s+"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsSubjects = subjects as NSString
        guard let split = separator.matches(
            in: subjects,
            range: NSRange(location: 0, length: nsSubjects.length)
        ).last else { return nil }
        let firstTask = nsSubjects.substring(
            with: NSRange(location: 0, length: split.range.location)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondStart = NSMaxRange(split.range)
        let secondTask = nsSubjects.substring(
            with: NSRange(location: secondStart, length: nsSubjects.length - secondStart)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstTask.isEmpty, !secondTask.isEmpty,
              clockCandidateCount(in: firstTask) == 0,
              clockCandidateCount(in: secondTask) == 0,
              let firstRange = message.range(
                of: firstTask, options: [.caseInsensitive, .diacriticInsensitive]
              ),
              let secondRange = message.range(
                of: secondTask, options: [.caseInsensitive, .diacriticInsensitive]
              ),
              firstRange.lowerBound < secondRange.lowerBound
        else { return nil }
        return (
            GroundedCaptureLabel(task: firstTask, evidence: String(message[firstRange])),
            GroundedCaptureLabel(task: secondTask, evidence: String(message[secondRange]))
        )
    }

    private static func deterministicCoordinatedCaptures(
        message: String
    ) -> [RuntimeAction]? {
        guard let labels = structurallySeparateCoordinatedLabels(in: message),
              let clocks = coordinatedClockTexts(in: message) else { return nil }
        let recurrence = holisticRecurrence(evidence: message, message: message)
        let date = deterministicDateIntent(in: message)
            ?? recurrenceInitialDate(recurrence)
        let hasDeadline = message.range(
            of: #"\b(?:by|before|due)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let actions = [labels.0.task, labels.1.task].enumerated().map { index, task in
            RuntimeAction(
                type: "capture", task: task, raw: message,
                when: hasDeadline ? nil : date,
                deadline: hasDeadline ? date : nil,
                time: RuntimeGeneratedClock.normalizeEvidence(
                    clocks[index],
                    interpretation: explicitMeridiem(in: clocks[index])
                        ?? inferredMeridiem(for: clocks[index]),
                    in: message
                ),
                priority: "normal", recurrence: recurrence, confidence: 1
            )
        }
        return actions.allSatisfy { $0.time != nil } ? actions : nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func capture(
        _ item: CaptureDecompositionItem,
        inheriting initial: CaptureArgs
    ) -> CaptureArgs {
        CaptureArgs(
            task: item.task,
            evidence: item.evidence,
            scheduleKind: initial.scheduleKind,
            scheduleEvidence: initial.scheduleEvidence,
            scheduleWeekday: initial.scheduleWeekday,
            scheduleWhich: initial.scheduleWhich,
            scheduleN: initial.scheduleN,
            scheduleUnit: initial.scheduleUnit,
            schedulePart: initial.schedulePart,
            scheduleAnchor: initial.scheduleAnchor,
            scheduleYear: initial.scheduleYear,
            scheduleMonth: initial.scheduleMonth,
            scheduleDay: initial.scheduleDay,
            deadlineKind: initial.deadlineKind,
            deadlineEvidence: initial.deadlineEvidence,
            deadlineWeekday: initial.deadlineWeekday,
            deadlineWhich: initial.deadlineWhich,
            deadlineN: initial.deadlineN,
            deadlineUnit: initial.deadlineUnit,
            deadlinePart: initial.deadlinePart,
            deadlineAnchor: initial.deadlineAnchor,
            deadlineYear: initial.deadlineYear,
            deadlineMonth: initial.deadlineMonth,
            deadlineDay: initial.deadlineDay,
            durationMinutes: initial.durationMinutes,
            durationEvidence: initial.durationEvidence,
            priority: initial.priority,
            clockText: item.clockText,
            clockInterpretation: item.clockInterpretation,
            recurrenceFrequency: initial.recurrenceFrequency,
            recurrenceInterval: initial.recurrenceInterval,
            recurrenceWeekdays: initial.recurrenceWeekdays,
            recurrenceMonthDay: initial.recurrenceMonthDay,
            recurrenceMonth: initial.recurrenceMonth,
            recurrenceAnchor: initial.recurrenceAnchor,
            recurrenceCount: initial.recurrenceCount,
            recurrenceEvidence: initial.recurrenceEvidence
        )
    }

    private static func clockCandidateCount(in text: String) -> Int {
        let pattern = #"\b(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return 0 }
        return regex.numberOfMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private static func coordinatedClockTexts(in text: String) -> [String]? {
        let pattern = #"\b(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let source = text as NSString
        let values = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).map { source.substring(with: $0.range) }
        return values.count == 2 ? values : nil
    }

    private static func conversationalContinuationCapture(
        message: String
    ) -> RuntimeAction? {
        let lowered = message.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lowered.hasPrefix("and "),
              !words(message).contains(where: { ["it", "that", "this"].contains($0) }),
              let clock = singleClockText(in: message)
        else { return nil }
        guard let clockRange = message.range(
            of: clock, options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return nil }
        let label = String(message[..<clockRange.lowerBound]).replacingOccurrences(
            of: #"^\s*and\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).replacingOccurrences(
            of: #"\s+(?:at|around|about|by)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let interpretation = explicitMeridiem(in: clock)
            ?? inferredMeridiem(for: clock)
        guard let time = recoveredTime(
            task: label,
            evidence: message,
            text: clock,
            interpretation: interpretation,
            originalMessage: message
        ) else { return nil }
        return RuntimeAction(
            type: "capture", task: label, raw: message,
            time: time, priority: "normal", confidence: 1
        )
    }

    private static func singleClockText(in text: String) -> String? {
        let pattern = #"\b(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let source = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: source.length)
        )
        guard matches.count == 1, let match = matches.first else { return nil }
        return source.substring(with: match.range)
    }

    private static func inferredMeridiem(for clock: String) -> String {
        let digits = clock.filter(\.isNumber)
        let hour: Int
        if clock.contains(":"), let first = clock.split(separator: ":").first {
            hour = Int(first) ?? 0
        } else if digits.count >= 3 {
            hour = Int(digits.dropLast(2)) ?? 0
        } else {
            hour = Int(digits) ?? 0
        }
        return (1...6).contains(hour) || hour == 12 ? "pm" : "am"
    }

    private static func deterministicSingleClock(in message: String) -> String? {
        guard let clock = singleClockText(in: message) else { return nil }
        return RuntimeGeneratedClock.normalizeEvidence(
            clock,
            interpretation: explicitMeridiem(in: clock)
                ?? inferredMeridiem(for: clock),
            in: message
        )
    }

    private static func deterministicDateIntent(
        in message: String
    ) -> RuntimeDateIntent? {
        let tokens = words(message)
        let tokenSet = Set(tokens)
        if tokenSet.contains("tomorrow") { return RuntimeDateIntent(kind: "tomorrow") }
        if tokenSet.contains("today") { return RuntimeDateIntent(kind: "today") }

        let weekdays: [(String, Set<String>)] = [
            ("mon", ["mon", "monday"]), ("tue", ["tue", "tuesday"]),
            ("wed", ["wed", "wednesday"]), ("thu", ["thu", "thursday"]),
            ("fri", ["fri", "friday"]), ("sat", ["sat", "saturday"]),
            ("sun", ["sun", "sunday"]),
        ]
        if let day = weekdays.first(where: { !$0.1.isDisjoint(with: tokenSet) })?.0 {
            return RuntimeDateIntent(
                kind: "weekday",
                which: tokenSet.contains("next") ? "next" : "this",
                day: day
            )
        }

        let numberWords = [
            "one": 1, "two": 2, "couple": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10,
        ]
        if let index = tokens.firstIndex(of: "in"), index + 2 < tokens.count {
            let amount = Int(tokens[index + 1]) ?? numberWords[tokens[index + 1]]
            let unitToken = tokens[index + 2]
            let unit = [
                "day": "day", "days": "day", "week": "week", "weeks": "week",
                "month": "month", "months": "month", "year": "year", "years": "year",
            ][unitToken]
            if let amount, amount > 0, let unit {
                return RuntimeDateIntent(kind: "offset", n: amount, unit: unit)
            }
        }
        if tokens.count >= 2 {
            let amount = Int(tokens[0]) ?? numberWords[tokens[0]]
            let unit = [
                "day": "day", "days": "day", "week": "week", "weeks": "week",
                "month": "month", "months": "month", "year": "year", "years": "year",
            ][tokens[1]]
            if let amount, amount > 0, let unit {
                return RuntimeDateIntent(kind: "offset", n: amount, unit: unit)
            }
        }
        if tokenSet.contains("couple"),
           !tokenSet.isDisjoint(with: ["day", "days"]) {
            return RuntimeDateIntent(kind: "offset", n: 2, unit: "day")
        }
        return nil
    }

    private static func holisticRecurrence(
        evidence: String,
        message: String
    ) -> RuntimeRecurrenceRule? {
        let clean = normalizedGeneratedEvidence(evidence)
        guard clean.lowercased() != "none",
              unifiedEvidenceIsGrounded(clean, in: message),
              RuntimeRecurrenceEvidence.isExplicit(in: clean) else { return nil }
        let tokens = words(clean)
        let tokenSet = Set(tokens)
        let weekdays = groundedRecurrenceWeekdays([], evidence: clean)
        let numberWords = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        var interval = 1
        if let every = tokens.firstIndex(of: "every"), every + 1 < tokens.count {
            interval = Int(tokens[every + 1]) ?? numberWords[tokens[every + 1]] ?? 1
        }
        let frequency: String
        if !weekdays.isEmpty { frequency = "week" }
        else if !tokenSet.isDisjoint(with: ["daily", "day", "days"]) { frequency = "day" }
        else if !tokenSet.isDisjoint(with: ["weekly", "week", "weeks"]) { frequency = "week" }
        else if !tokenSet.isDisjoint(with: ["monthly", "month", "months"]) { frequency = "month" }
        else if !tokenSet.isDisjoint(with: ["yearly", "annual", "year", "years"]) { frequency = "year" }
        else { return nil }
        var count: Int?
        if let after = tokens.firstIndex(of: "after"), after + 1 < tokens.count {
            count = Int(tokens[after + 1]) ?? numberWords[tokens[after + 1]]
        }
        let rule = RuntimeRecurrenceRule(
            frequency: frequency, interval: max(1, interval),
            weekdays: weekdays,
            anchor: tokenSet.contains("finish") || tokenSet.contains("completion")
                ? "completion" : "fixed",
            count: count
        )
        return rule.isValid ? rule : nil
    }

    private static func coordinatedCapturesNeedReview(
        _ captures: [CaptureArgs]
    ) -> Bool {
        guard captures.count > 1 else { return true }
        if captures.contains(where: { clockCandidateCount(in: $0.task) > 0 }) {
            return true
        }
        let tokenSets = captures.map {
            Set(words($0.task).filter { $0.count >= 3 })
        }
        for left in tokenSets.indices {
            for right in tokenSets.indices where right > left {
                let union = tokenSets[left].union(tokenSets[right])
                guard !union.isEmpty else { return true }
                let overlap = tokenSets[left].intersection(tokenSets[right]).count
                let smallerCount = min(tokenSets[left].count, tokenSets[right].count)
                if smallerCount == 0
                    || Double(overlap) / Double(smallerCount) >= 0.75 {
                    return true
                }
            }
        }
        return false
    }

    private static func coordinatedCapturesAreOrdered(
        _ captures: [CaptureArgs],
        message: String
    ) -> Bool {
        guard captures.count == 2,
              let firstRange = message.range(
                of: captures[0].evidence,
                options: [.caseInsensitive, .diacriticInsensitive]
              ),
              let secondRange = message.range(
                of: captures[1].evidence,
                options: [.caseInsensitive, .diacriticInsensitive]
              )
        else { return false }
        return firstRange.lowerBound < secondRange.lowerBound
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func bulkCompletionAudit(_ message: String) async throws -> Bool {
        for _ in 0..<2 {
            let response = try await LanguageModelSession().respond(to: """
            Does the user clearly report that all or nearly all referenced tasks
            were completed, possibly with stated exceptions? Answer yes or no,
            then explain. A report of zero work is NO.
            User message: \(message)
            """)
            if response.content.uppercased().split(whereSeparator: {
                !$0.isLetter
            }).first.map(String.init) != "YES" { return false }
        }
        return true
    }

    private static func taskPosition(_ task: String, in message: String) -> Int {
        words(task).compactMap { word -> Int? in
            guard word.count >= 3,
                  let range = message.range(
                    of: word, options: [.caseInsensitive, .diacriticInsensitive]
                  ) else { return nil }
            return message.distance(from: message.startIndex, to: range.lowerBound)
        }.max() ?? Int.max
    }

    private static func recoveredTime(
        task: String,
        evidence: String,
        text: String,
        interpretation: String,
        originalMessage: String
    ) -> String? {
        if let exact = normalizedTime(
            text: text, interpretation: interpretation,
            originalMessage: originalMessage
        ) { return exact }
        let groundedInterpretation = explicitMeridiem(in: text)
            ?? explicitMeridiem(in: originalMessage) ?? interpretation
        guard groundedInterpretation == "am" || groundedInterpretation == "pm"
        else { return nil }
        let source = RuntimeConstraintEvidence.contains(evidence, in: originalMessage)
            ? evidence : originalMessage
        let pattern = #"\b(?:\d{1,2}:\d{2}|\d{3,4}|\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?))\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let ns = source as NSString
        let matches = regex.matches(
            in: source, range: NSRange(location: 0, length: ns.length)
        )
        let anchor = words(task).filter { $0.count >= 3 }.compactMap { word in
            ns.range(of: word, options: .caseInsensitive).location
        }.filter { $0 != NSNotFound }.max() ?? 0
        let candidate = matches
            .filter { $0.range.location >= anchor }
            .min { $0.range.location < $1.range.location }
            .map { ns.substring(with: $0.range) }
        guard let candidate else { return nil }
        return RuntimeGeneratedClock.normalizeEvidence(
            candidate, interpretation: groundedInterpretation, in: originalMessage
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func refineSingleClock(_ message: String) async throws -> String? {
        guard clockCandidateCount(in: message) == 1 else { return nil }
        var times: [String] = []
        for _ in 0..<5 {
            guard let value = try? await LanguageModelSession(instructions: """
                Extract a clock only when the user's number schedules an
                appointment or action. Infer an unstated AM or PM from the
                activity and ordinary waking-hours context. Only choose an
                overnight reading when the user's activity or words support it;
                bare 1 through 6 o'clock appointments are normally PM. Counts,
                durations, prices, IDs, and codes are not clocks. Copy the clock
                text exactly from the user.
                """).respond(
                to: "User message: \(message)",
                generating: SingleClockArgs.self
            ).content,
                  value.kind == "clock",
                  let time = normalizedTime(
                    text: value.clockText,
                    interpretation: value.clockInterpretation,
                    originalMessage: message
                  ) else { continue }
            times.append(time)
        }
        guard let winner = Dictionary(grouping: times, by: { $0 })
            .max(by: { $0.value.count < $1.value.count }),
              winner.value.count >= 4 else { return nil }
        return winner.key
    }

    private static func explicitMeridiem(in text: String) -> String? {
        let compact = text.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
        if compact.contains("am") { return "am" }
        if compact.contains("pm") { return "pm" }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func moveAction(
        _ value: MoveDestination,
        message: String
    ) throws -> RuntimeAction {
        RuntimeAction(
            type: "reschedule", target: String(value.targetIndex),
            when: try dateIntent(
                kind: value.scheduleKind, weekday: value.scheduleWeekday,
                which: value.scheduleWhich, n: value.scheduleN,
                unit: value.scheduleUnit, part: value.schedulePart,
                anchor: value.scheduleAnchor, year: value.scheduleYear,
                month: value.scheduleMonth, day: value.scheduleDay,
                evidence: value.dateEvidence
            ),
            time: normalizedTime(
                text: value.clockText,
                interpretation: value.clockInterpretation,
                originalMessage: message
            ), confidence: 1
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func recurrenceRule(
        _ value: CaptureArgs,
        message: String
    ) -> RuntimeRecurrenceRule? {
        guard RuntimeRecurrenceEvidence.isExplicit(in: message),
              value.recurrenceFrequency != "none",
              RuntimeConstraintEvidence.contains(
                value.recurrenceEvidence, in: message
              ) else { return nil }
        let weekdays = groundedRecurrenceWeekdays(
            value.recurrenceWeekdays,
            evidence: value.recurrenceEvidence
        )
        let frequency = weekdays.isEmpty ? value.recurrenceFrequency : "week"
        let rule = RuntimeRecurrenceRule(
            frequency: frequency,
            interval: max(1, value.recurrenceInterval),
            weekdays: weekdays,
            monthDay: value.recurrenceMonthDay > 0
                ? value.recurrenceMonthDay : nil,
            month: value.recurrenceMonth > 0 ? value.recurrenceMonth : nil,
            anchor: value.recurrenceAnchor,
            count: value.recurrenceCount > 0 ? value.recurrenceCount : nil
        )
        return rule.isValid ? rule : nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func recurrenceRule(
        _ value: RecurrenceConstraintArgs,
        message: String
    ) -> RuntimeRecurrenceRule? {
        guard RuntimeRecurrenceEvidence.isExplicit(in: message),
              value.recurrenceFrequency != "none",
              RuntimeConstraintEvidence.contains(
                value.recurrenceEvidence, in: message
              ) else { return nil }
        let weekdays = groundedRecurrenceWeekdays(
            value.recurrenceWeekdays,
            evidence: value.recurrenceEvidence
        )
        let frequency = weekdays.isEmpty ? value.recurrenceFrequency : "week"
        let rule = RuntimeRecurrenceRule(
            frequency: frequency,
            interval: max(1, value.recurrenceInterval),
            weekdays: weekdays,
            monthDay: value.recurrenceMonthDay > 0
                ? value.recurrenceMonthDay : nil,
            month: value.recurrenceMonth > 0 ? value.recurrenceMonth : nil,
            anchor: value.recurrenceAnchor,
            count: value.recurrenceCount > 0 ? value.recurrenceCount : nil
        )
        return rule.isValid ? rule : nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func refineOccurrenceDate(
        _ message: String
    ) async throws -> DateConstraintArgs {
        var last: DateConstraintArgs?
        for _ in 0..<2 {
            guard let value = try? await LanguageModelSession(instructions: """
                Extract only when this new task is supposed to happen. Copy the date
                evidence exactly. Use none when no occurrence date is stated. A
                relative phrase such as “in 10 years” is offset 10 years. Never
                treat a duration as a date and never invent.
                """).respond(
                    to: "User message: \(message)",
                    generating: DateConstraintArgs.self
                ).content else { continue }
            last = value
            if value.dateKind != "none" { return value }
        }
        guard let last else { throw RuntimeInterpretationError.invalidOutput }
        return last
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func refineRecurrence(
        _ message: String
    ) async throws -> RecurrenceConstraintArgs {
        guard RuntimeRecurrenceEvidence.isExplicit(in: message) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        var last: RecurrenceConstraintArgs?
        for _ in 0..<2 {
            guard let value = try? await LanguageModelSession(instructions: """
                Extract only whether this new task repeats. Copy recurrence evidence
                exactly. Use none when it does not repeat. “Every Monday” is weekly
                on Monday. Never invent recurrence from an ordinary date.
                """).respond(
                    to: "User message: \(message)",
                    generating: RecurrenceConstraintArgs.self
                ).content else { continue }
            last = value
            if value.recurrenceFrequency != "none" { return value }
        }
        guard let last else { throw RuntimeInterpretationError.invalidOutput }
        return last
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func recoverNewCaptureActions(
        message: String
    ) async throws -> [RuntimeAction] {
        let batch = try await LanguageModelSession(instructions: """
            Extract only genuine new obligations. Return one short task per
            obligation and copy its supporting words exactly. Return an empty
            list for questions, replies, reports, or existing-task changes.
            """).respond(
                to: "User message: \(message)",
                generating: SimpleCaptureBatch.self
            ).content
        let items = batch.tasks.filter { item in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            return !task.isEmpty
                && task.utf8.count <= 10_000
                && RuntimeConstraintEvidence.contains(item.evidence, in: message)
                && captureIsNew(task, evidence: item.evidence, open: [])
        }
        guard !items.isEmpty, items.count <= 16 else {
            throw RuntimeInterpretationError.invalidOutput
        }
        if clockCandidateCount(in: message) == 2,
           let labels = structurallySeparateCoordinatedLabels(in: message) {
            for _ in 0..<2 {
                guard let pair = try? await LanguageModelSession(instructions: """
                    Classify two clock expressions. For coordinated appointments,
                    pair each appointment with its clock in order. Interpret an
                    unstated meridiem as a reasonable daytime appointment.
                    """).respond(
                        to: "User message: \(message)",
                        generating: CoordinatedClockPairArgs.self
                    ).content,
                    pair.kind == "two_appointments"
                else { continue }
                return [
                    RuntimeAction(
                        type: "capture", task: labels.0.task, raw: message,
                        time: normalizedTime(
                            text: pair.firstClockText,
                            interpretation: pair.firstClockInterpretation,
                            originalMessage: message
                        ), priority: "normal", confidence: 1
                    ),
                    RuntimeAction(
                        type: "capture", task: labels.1.task, raw: message,
                        time: normalizedTime(
                            text: pair.secondClockText,
                            interpretation: pair.secondClockInterpretation,
                            originalMessage: message
                        ), priority: "normal", confidence: 1
                    ),
                ]
            }
        }
        let refinedDate = try? await refineOccurrenceDate(message)
        let refinedRecurrence = try? await refineRecurrence(message)
        var recurrence = refinedRecurrence.flatMap {
            recurrenceRule($0, message: message)
        }
        if recurrence == nil {
            recurrence = try? await auditedRecurrenceRule(message)
        }
        let when = refinedDate.flatMap { value -> RuntimeDateIntent? in
            guard RuntimeConstraintEvidence.contains(
                value.dateEvidence, in: message
            ) else { return nil }
            return try? dateIntent(
                kind: value.dateKind, weekday: value.dateWeekday,
                which: value.dateWhich, n: value.dateN, unit: value.dateUnit,
                part: value.datePart, anchor: value.dateAnchor,
                year: value.dateYear, month: value.dateMonth,
                day: value.dateDay, evidence: value.dateEvidence
            )
        } ?? recurrenceInitialDate(recurrence)
        return items.map { item in
            RuntimeAction(
                type: "capture",
                task: item.task.trimmingCharacters(in: .whitespacesAndNewlines),
                raw: message, when: when, priority: "normal",
                recurrence: recurrence, confidence: 1
            )
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func auditedRecurrenceRule(
        _ message: String
    ) async throws -> RuntimeRecurrenceRule? {
        guard RuntimeRecurrenceEvidence.isExplicit(in: message) else { return nil }
        let instructions = """
            Decide whether the obligation repeats. A named weekday with “every”
            is weekly. An ordinary date is not recurrence. “Water plants every
            Monday” is weekly. Return only the recurrence frequency.
            """
        var values: [String] = []
        for _ in 0..<5 {
            if let value = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: RecurrenceAuditArgs.self
            ).content.frequency {
                values.append(value)
            }
        }
        guard let frequency = Dictionary(grouping: values, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key
        else { throw RuntimeInterpretationError.invalidOutput }
        guard frequency != "none" else { return nil }
        let weekdays = groundedRecurrenceWeekdays([], evidence: message)
        let normalized = weekdays.isEmpty ? frequency : "week"
        let rule = RuntimeRecurrenceRule(
            frequency: normalized,
            weekdays: normalized == "week" ? weekdays : []
        )
        return rule.isValid ? rule : nil
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractAnalysis(
        message: String,
        open: [RuntimeTask]
    ) async throws -> AnalysisArgs? {
        let result = try await LanguageModelSession(instructions: """
            Classify only read-only planning questions. Capacity asks whether
            work fits. Explain asks why one task has its place. What-if changes
            one duration temporarily. Ordinary task changes are none. Copy
            evidence exactly. Use seven days when no horizon is stated.
            """).respond(
                to: """
                Open tasks: \(open.enumerated().map { "\($0.offset + 1). \($0.element.task)" })
                User message: \(message)
                """,
                generating: AnalysisClassificationArgs.self
            ).content
        guard result.kind != "none" else { return nil }
        return AnalysisArgs(
            kind: result.kind,
            targetIndex: result.targetIndex,
            horizonDays: result.horizonDays,
            budgetMinutes: result.budgetMinutes,
            hypotheticalDurationMinutes: result.hypotheticalDurationMinutes,
            durationEvidence: result.durationEvidence,
            evidence: result.evidence
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func socialReply(to message: String) async throws -> String {
        let response = try await LanguageModelSession(instructions: """
            Reply naturally to a brief social or non-task message. Match the
            user's tone without overdoing it. Answer a general question briefly.
            Use one sentence and no more than 24 words. Do not claim that tasks,
            plans, reminders, or calendars changed.
            """).respond(to: message).content
        let compact = response.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "Anytime." }
        return String(compact.prefix(120))
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func confirmsSocial(_ message: String) async throws -> Bool {
        let instructions = """
        Decide whether the message contains an actual request or statement about
        work. Social includes conversational acknowledgements, thanks, greetings,
        reactions, and general-knowledge questions. A bare acknowledgement of the
        assistant's preceding turn is social; it does not create an obligation.
        Short past-tense confirmations such as “Understood” or “I hear you” are
        acknowledgements, not tasks. Never invent an omitted chore behind a
        pronoun. A task message names work to do, a saved item, or a planning
        operation; ordinary conversational verbs do not qualify by themselves.
        Task includes anything about saved work, a plan, schedule, calendar,
        completion, a date, or adding or changing an obligation. Choose task only
        when the user's words contain that task or planning meaning.
        Common standalone acknowledgements and reactions such as “cool”, “got
        it”, “okay”, and “sounds good” are social, not task labels.
        """
        var modes: [String] = []
        for _ in 0..<5 {
            if let mode = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: SocialAuditArgs.self
            ).content.mode {
                modes.append(mode)
            }
        }
        guard !modes.isEmpty else { return false }
        return modes.count { $0 == "social" } > modes.count / 2
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func classifyIntent(
        _ message: String
    ) async throws -> String {
        let instructions = """
        First classify the user's intent. Retrieval means asking to view, list,
        find, search, or recall saved task state. Change means editing, moving,
        parking, resuming, or annotating a task. Report means saying what
        happened. New task means adding an obligation. Planning means capacity,
        explanation, what-if, or a schedule request. Social means thanks,
        greetings, reactions, casual conversation, or a general question that
        is unrelated to saved tasks. Changing a saved task's
        priority or estimate is change, even when a duration appears. “Make the
        report high priority and 90 minutes” is change. Planning is reserved for
        questions such as “will it fit?” or “what if it takes 90 minutes?” and
        explicit requests to build a schedule. For retrieval only,
        classify the requested saved task state. Use today, date, all, overdue,
        week, search, done, or waiting. Completed-history questions use done.
        Finding words in saved tasks uses search. Copy evidence exactly from the
        user message. For every non-retrieval intent use kind none.
        A short acknowledgement of Hob's preceding turn is social. Do not infer
        an unstated task from conversational words or pronouns. In Hob's task
        entry field, a concise imperative such as “Eat bacon” or a bare task
        label such as “test” is a new task even without “add” or “remember.”
        """
        var results: [IntentClassificationArgs] = []
        for _ in 0..<3 {
            if let value = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: IntentClassificationArgs.self
            ).content {
                results.append(value)
            }
        }
        guard !results.isEmpty else { throw RuntimeInterpretationError.invalidOutput }
        return Dictionary(grouping: results, by: \.intent)
            .max { $0.value.count < $1.value.count }?.key ?? results[0].intent
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func confirmsRetrieval(_ message: String) async throws -> Bool {
        let instructions = """
        Decide whether the user asks Hob to return information from saved tasks.
        Retrieval means the user wants to see, find, list, or recall saved task
        information. New task means adding an obligation, regardless of its
        date. Task change means editing, annotating, moving, parking, resuming,
        completing, or dropping work. Report describes what happened.
        “What did I finish this week?” is retrieval. “Add bananas in ten years”
        is new task. “Note that the gate code is 4412” and “I’m waiting on Sam”
        are task changes.
        """
        var modes: [String] = []
        for _ in 0..<5 {
            if let value = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: RetrievalAuditArgs.self
            ).content.mode {
                modes.append(value)
            }
        }
        guard !modes.isEmpty else { return false }
        return modes.count { $0 == "retrieval" } >= 4
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func confirmsNewObligation(
        _ message: String,
        minimumVotes: Int
    ) async throws -> Bool {
        let instructions = """
        Decide whether the user adds at least one genuinely new obligation.
        A compact conversational continuation may begin with a conjunction and
        contain only an appointment or activity label plus a clock. For example,
        “And dentist at 2:30” is a new obligation. Spelling mistakes do not
        change that intent. Retrieval asks to see saved information. A task
        change affects existing work. A report describes what happened.
        Thanks, acknowledgements, reactions, and general conversation are other.
        A new obligation must name the activity or appointment being added; do
        not invent one from a conversational verb or pronoun. Treat a concise
        imperative with a named object as a new obligation. In Hob's task entry
        field, an isolated activity or task label is also a new obligation even
        when the user omits “add,” “remember,” or a date. “Eat bacon” and “test”
        are new tasks. Common acknowledgements and reactions such as “thanks
        bro”, “cool”, “got it”, “okay”, and “sounds good” are other.
        """
        var modes: [String] = []
        for _ in 0..<5 {
            if let mode = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: NewObligationAuditArgs.self
            ).content.mode {
                modes.append(mode)
            }
        }
        guard !modes.isEmpty else { return false }
        return modes.count { $0 == "new_task" } >= minimumVotes
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func classifyChange(_ message: String) async throws -> String {
        let instructions = """
            Classify an instruction that changes an existing task. Metadata sets
            or removes priority, estimate, deadline, date, clock, or another
            constraint. Note attaches durable detail. Wait parks blocked work.
            Resume returns blocked work to the deck. Move changes its date or
            clock. Rename changes its title. Drop removes it. Keep leaves stale
            work active. Recurrence changes a repeating series. Use other for a
            question, report, new task, planning request, or social message.
            “Note that the gate code is 4412” is note. “I’m waiting on Sam for
            the report” is wait. “Sam replied; put the report back” is resume.
            “Make that 4pm” is move because it changes a clock.
            “What did I finish this week?” and “What is waiting?” are questions,
            so they are other.
            """
        var values: [String] = []
        for _ in 0..<5 {
            if let value = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: ChangeClassificationArgs.self
            ).content.kind {
                values.append(value)
            }
        }
        guard !values.isEmpty else { throw RuntimeInterpretationError.invalidOutput }
        return Dictionary(grouping: values, by: { $0 })
            .max { $0.value.count < $1.value.count }?.key ?? "other"
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractQuery(_ message: String) async throws -> QueryArgs {
        let instructions = """
            Classify a read-only request for saved task state. Completed-history
            questions use status completed. Waiting work uses status waiting.
            The kind describes the time or search scope: today, date, all,
            overdue, week, search, done, or waiting. Questions about how a
            future day is looking ask for open tasks on that date; use kind date
            and status open. Never use completed unless the user asks what was
            done, finished, or completed. Copy evidence exactly.
            """
        var candidates: [QueryArgs] = []
        for _ in 0..<3 {
            guard let result = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: QueryClassificationArgs.self
            ).content else { continue }
            guard result.kind != "none",
                  RuntimeConstraintEvidence.contains(result.evidence, in: message)
            else { continue }
            let kind = result.status == "completed" ? "done"
                : (result.status == "waiting" ? "waiting" : result.kind)
            let candidate = QueryArgs(
                kind: kind,
                date: result.date,
                term: result.term,
                period: result.period,
                evidence: result.evidence
            )
            candidates.append(candidate)
            if kind == "date",
               RuntimeConstraintEvidence.contains(
                result.date.dateEvidence, in: message
               ), (try? dateIntent(
                kind: result.date.dateKind,
                weekday: result.date.dateWeekday,
                which: result.date.dateWhich,
                n: result.date.dateN,
                unit: result.date.dateUnit,
                part: result.date.datePart,
                anchor: result.date.dateAnchor,
                year: result.date.dateYear,
                month: result.date.dateMonth,
                day: result.date.dateDay,
                evidence: result.date.dateEvidence
               )) != nil {
                return candidate
            }
        }
        guard let winner = Dictionary(grouping: candidates, by: \.kind)
            .max(by: { $0.value.count < $1.value.count })?.value.first
        else { throw RuntimeInterpretationError.invalidOutput }
        return winner
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractDateQuery(_ message: String) async throws -> RuntimeAction {
        let instructions = """
            Decide whether this read-only question asks what is scheduled or
            open on one particular day. “How is tomorrow looking?” is a date
            query. Questions about completion history, a whole week, searching,
            or changing work are other. Copy the day words exactly.
            """
        var candidates: [RuntimeDateIntent] = []
        for _ in 0..<5 {
            guard let result = try? await LanguageModelSession(
                instructions: instructions
            ).respond(
                to: "User message: \(message)",
                generating: DateQueryClassificationArgs.self
            ).content,
                  result.mode == "date",
                  RuntimeConstraintEvidence.contains(
                    result.date.dateEvidence, in: message
                  ), let intent = try? dateIntent(
                    kind: result.date.dateKind,
                    weekday: result.date.dateWeekday,
                    which: result.date.dateWhich,
                    n: result.date.dateN,
                    unit: result.date.dateUnit,
                    part: result.date.datePart,
                    anchor: result.date.dateAnchor,
                    year: result.date.dateYear,
                    month: result.date.dateMonth,
                    day: result.date.dateDay,
                    evidence: result.date.dateEvidence
                  ) else { continue }
            candidates.append(intent)
        }
        guard let winner = candidates.first(where: { candidate in
            candidates.count(where: { $0 == candidate }) >= 3
        }) else { throw RuntimeInterpretationError.invalidOutput }
        return RuntimeAction(type: "query", when: winner, queryKind: "date")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func recoverRelativeDateQuery(
        _ message: String
    ) async throws -> RuntimeAction {
        guard let date = try dateIntent(
            kind: "none", weekday: "none", which: "none", evidence: message
        ) else { throw RuntimeInterpretationError.invalidOutput }
        var approvals = 0
        for _ in 0..<3 {
            let response = try await LanguageModelSession().respond(to: """
                Does this message ask to see the user's plan or open tasks for
                the stated day? Answer YES or NO first. Asking how a day looks
                is YES. Adding, moving, completing, or dropping work is NO.
                User message: \(message)
                """)
            if response.content.uppercased().split(whereSeparator: {
                !$0.isLetter
            }).first.map(String.init) == "YES" {
                approvals += 1
            }
        }
        guard approvals >= 2 else { throw RuntimeInterpretationError.invalidOutput }
        return RuntimeAction(type: "query", when: date, queryKind: "date")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func extractSimpleQuery(_ message: String) async throws -> RuntimeAction {
        let result = try await LanguageModelSession(instructions: """
            Classify a confirmed read-only task question. Done means completion
            history. Waiting means blocked tasks. Search means matching task
            text. Week means the coming or current week. Choose only the scope
            the user asked for; do not invent a search term.
            """).respond(
                to: "User message: \(message)",
                generating: SimpleQueryClassificationArgs.self
            ).content
        guard ["today", "all", "overdue", "week", "search", "done", "waiting"]
            .contains(result.kind) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        let term = result.term.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.kind == "search" {
            guard !term.isEmpty,
                  message.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                  ) != nil else { throw RuntimeInterpretationError.invalidOutput }
        }
        return RuntimeAction(
            type: "query", queryKind: result.kind,
            queryTerm: term.isEmpty ? nil : term,
            queryPeriod: ["today", "week", "all"].contains(result.period)
                ? result.period : nil
        )
    }


    private static func recurrenceInitialDate(
        _ rule: RuntimeRecurrenceRule?
    ) -> RuntimeDateIntent? {
        guard let rule else { return nil }
        if rule.frequency == "week", let day = rule.weekdays.first {
            return RuntimeDateIntent(kind: "weekday", which: "this", day: day)
        }
        if rule.frequency == "month", let day = rule.monthDay {
            return RuntimeDateIntent(kind: "ordinal_day", dayNumber: day)
        }
        if rule.frequency == "year", let month = rule.month,
           let day = rule.monthDay {
            return RuntimeDateIntent(kind: "month_day", month: month, dayNumber: day)
        }
        return RuntimeDateIntent(kind: "today")
    }

    private static func groundedRecurrenceWeekdays(
        _ generated: [String],
        evidence: String
    ) -> [String] {
        let valid = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let supplied = generated.filter(valid.contains)
        guard supplied.isEmpty else { return supplied }
        let tokens = Set(words(evidence))
        let names = [
            "sun": ["sun", "sunday"], "mon": ["mon", "monday"],
            "tue": ["tue", "tues", "tuesday"],
            "wed": ["wed", "wednesday"], "thu": ["thu", "thur", "thurs", "thursday"],
            "fri": ["fri", "friday"], "sat": ["sat", "saturday"],
        ]
        return valid.filter { day in
            names[day].map { !Set($0).isDisjoint(with: tokens) } == true
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    actor Collector {
        private var proposals: [Proposal] = []
        func append(_ proposal: Proposal) { proposals.append(proposal) }
        func values() -> [Proposal] { proposals }
    }

    @available(iOS 26.0, macOS 26.0, *)
    enum Proposal: Sendable {
        case acknowledge, undo, replan
        case progress(TargetArgs), capture(CaptureArgs), complete(TargetArgs)
        case drop(TargetArgs), move(MoveArgs), amend(AmendArgs), keep(TargetArgs)
        case revise(ReviseArgs), note(NoteArgs), wait(TargetArgs), resume(TargetArgs)
        case priority(PriorityArgs), duration(DurationEditArgs), clearField(ClearFieldArgs)
        case query(QueryArgs)
        case bulkComplete(BulkCompleteArgs), bulkMove(BulkMoveArgs)
        case recurrence(RecurrenceArgs), analysis(AnalysisArgs)

    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CompactAction {
        @Guide(description: "capture, complete, drop, keep, wait, resume, progress, move, revise, note, query, analysis, recurrence, acknowledge, undo, replan, or social")
        var kind: String
        @Guide(description: "Task label or replacement title")
        var task: String?
        @Guide(description: "1-based saved task number")
        var targetIndex: Int?
        @Guide(description: "Note, search term, or brief reply")
        var detail: String?
        @Guide(description: "Query, analysis, or recurrence subtype")
        var subtype: String?
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CompactTurn {
        var actions: [CompactAction]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    enum HolisticAction {
        case capture(HolisticCapture)
        case complete(TargetArgs)
        case drop(TargetArgs)
        case keep(TargetArgs)
        case wait(TargetArgs)
        case resume(TargetArgs)
        case progress(HolisticNote)
        case move(HolisticMove)
        case revise(HolisticRevision)
        case note(HolisticNote)
        case query(HolisticQuery)
        case analysis(HolisticAnalysis)
        case bulkComplete(HolisticBulkComplete)
        case bulkMove(HolisticBulkMove)
        case recurrence(HolisticRecurrence)
        case acknowledge(HolisticResponse)
        case undo(EvidenceArgs)
        case replan(EvidenceArgs)
        case social(HolisticResponse)
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticTurn {
        @Guide(description: "Complete ordered actions", .maximumCount(16))
        var actions: [HolisticAction]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticCapture {
        @Guide(description: "Short task label without constraints") var task: String
        @Guide(description: "Exact words naming this task") var evidence: String
        @Guide(description: "Exact occurrence-date words, or none") var dateEvidence: String
        @Guide(description: "Exact deadline words, or none") var deadlineEvidence: String
        @Guide(description: "Exact clock words, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
        @Guide(description: "Effort minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["none", "high", "normal", "low"])) var priority: String
        @Guide(description: "Exact priority words, or none") var priorityEvidence: String
        @Guide(description: "Exact repeating words, or none") var recurrenceEvidence: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticMove {
        @Guide(description: "1-based open task number") var targetIndex: Int
        @Guide(description: "Exact targeting words") var evidence: String
        @Guide(description: "Exact new-date words, or none") var dateEvidence: String
        @Guide(description: "Exact new clock words, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticRevision {
        @Guide(description: "1-based open task number") var targetIndex: Int
        @Guide(description: "Exact targeting words") var evidence: String
        @Guide(description: "Replacement title, or none") var task: String
        @Guide(description: "Exact replacement-title words, or none") var taskEvidence: String
        @Guide(description: "Exact date words, or none") var dateEvidence: String
        @Guide(description: "Exact deadline words, or none") var deadlineEvidence: String
        @Guide(description: "Exact clock words, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
        @Guide(description: "Effort minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["none", "high", "normal", "low"])) var priority: String
        @Guide(description: "Exact priority words, or none") var priorityEvidence: String
        @Guide(description: "Fields to clear") var clearFields: [String]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticNote {
        @Guide(description: "1-based open task number") var targetIndex: Int
        @Guide(description: "Exact targeting words") var evidence: String
        @Guide(description: "Exact note or progress words") var note: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticQuery {
        @Guide(.anyOf(["today", "date", "all", "overdue", "week", "search", "done", "waiting"])) var kind: String
        @Guide(description: "Exact question words") var evidence: String
        @Guide(description: "Exact requested-date words, or none") var dateEvidence: String
        @Guide(description: "Search words, or none") var term: String
        @Guide(.anyOf(["today", "week", "all"])) var period: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticAnalysis {
        @Guide(.anyOf(["capacity", "explain", "what_if"])) var kind: String
        @Guide(description: "1-based task number, or 0") var targetIndex: Int
        @Guide(description: "Exact question words") var evidence: String
        @Guide(description: "Horizon days, normally 7") var horizonDays: Int
        @Guide(description: "Available minutes, or 0") var budgetMinutes: Int
        @Guide(description: "Temporary task minutes, or 0") var hypotheticalDurationMinutes: Int
        @Guide(description: "Exact temporary-duration words, or none") var durationEvidence: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticBulkComplete {
        @Guide(description: "Exact all/everything report") var evidence: String
        @Guide(description: "Task numbers explicitly left unfinished") var excludedTargets: [Int]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticDestination {
        @Guide(description: "1-based open task number") var targetIndex: Int
        @Guide(description: "Exact new-date words") var dateEvidence: String
        @Guide(description: "Exact clock words, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticBulkMove {
        @Guide(description: "Exact bulk-move words") var evidence: String
        @Guide(description: "One destination per affected task") var destinations: [HolisticDestination]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticRecurrence {
        @Guide(description: "1-based recurring task number") var targetIndex: Int
        @Guide(description: "Exact targeting words") var evidence: String
        @Guide(.anyOf(["skip", "stop"])) var operation: String
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct HolisticResponse {
        @Guide(description: "Exact user words") var evidence: String
        @Guide(description: "Brief natural reply") var reply: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func compactAsHolistic(
        _ turn: CompactTurn,
        message: String
    ) -> HolisticTurn {
        HolisticTurn(actions: turn.actions.compactMap { value in
            if [
                "complete", "drop", "keep", "wait", "resume", "progress",
                "move", "revise", "note", "recurrence",
            ].contains(value.kind),
               (value.targetIndex ?? 0) == 0,
               !completionEvidenceIsSupported(message),
               let task = value.task, !task.isEmpty,
               task.lowercased() != "social" {
                let clock = singleClockText(in: message)
                return .capture(HolisticCapture(
                    task: task, evidence: message,
                    dateEvidence: message,
                    deadlineEvidence: message,
                    clockText: clock ?? "none",
                    clockInterpretation: clock.map { inferredMeridiem(for: $0) } ?? "none",
                    durationMinutes: 0, durationEvidence: "none",
                    priority: "none", priorityEvidence: "none",
                    recurrenceEvidence: message
                ))
            }
            if (value.targetIndex ?? 0) == 0,
               value.task == nil,
               ["complete", "drop", "keep", "wait", "resume", "progress", "move", "revise", "note"].contains(value.kind),
               let reply = value.detail, !reply.isEmpty {
                return .social(HolisticResponse(
                    evidence: message, reply: reply
                ))
            }
            let target = TargetArgs(
                targetIndex: value.targetIndex ?? 0, evidence: message
            )
            switch value.kind {
            case "capture":
                let clock = singleClockText(in: message)
                let duration = deterministicDurationMinutes(in: message) ?? 0
                let priority = deterministicPriority(in: message) ?? "none"
                return .capture(HolisticCapture(
                    task: value.task ?? "", evidence: message,
                    dateEvidence: message, deadlineEvidence: message,
                    clockText: clock ?? "none",
                    clockInterpretation: clock.map { inferredMeridiem(for: $0) } ?? "none",
                    durationMinutes: duration,
                    durationEvidence: duration > 0 ? message : "none",
                    priority: priority,
                    priorityEvidence: priority == "none" ? "none" : message,
                    recurrenceEvidence: message
                ))
            case "complete": return .complete(target)
            case "drop": return .drop(target)
            case "keep": return .keep(target)
            case "wait": return .wait(target)
            case "resume": return .resume(target)
            case "progress", "note":
                if (value.targetIndex ?? 0) == 0,
                   value.task?.lowercased() == "social" {
                    return .social(HolisticResponse(
                        evidence: message,
                        reply: value.detail ?? "Anytime."
                    ))
                }
                let note = HolisticNote(
                    targetIndex: value.targetIndex ?? 0,
                    evidence: message, note: value.detail ?? ""
                )
                return value.kind == "progress" ? .progress(note) : .note(note)
            case "move":
                return .move(HolisticMove(
                    targetIndex: value.targetIndex ?? 0,
                    evidence: message,
                    dateEvidence: message,
                    clockText: singleClockText(in: message) ?? "none",
                    clockInterpretation: singleClockText(in: message).map {
                        inferredMeridiem(for: $0)
                    } ?? "none"
                ))
            case "revise":
                let duration = deterministicDurationMinutes(in: message) ?? 0
                let priority = deterministicPriority(in: message) ?? "none"
                return .revise(HolisticRevision(
                    targetIndex: value.targetIndex ?? 0,
                    evidence: message, task: value.task ?? "none",
                    taskEvidence: value.task == nil ? "none" : message,
                    dateEvidence: message, deadlineEvidence: message,
                    clockText: singleClockText(in: message) ?? "none",
                    clockInterpretation: singleClockText(in: message).map {
                        inferredMeridiem(for: $0)
                    } ?? "none",
                    durationMinutes: duration,
                    durationEvidence: duration > 0 ? message : "none",
                    priority: priority,
                    priorityEvidence: priority == "none" ? "none" : message,
                    clearFields: deterministicClearFields(in: message)
                ))
            case "query":
                return .query(HolisticQuery(
                    kind: value.subtype ?? "all", evidence: message,
                    dateEvidence: message,
                    term: value.detail ?? "none",
                    period: value.subtype == "week" ? "week" : "all"
                ))
            case "analysis":
                let duration = deterministicDurationMinutes(in: message) ?? 0
                return .analysis(HolisticAnalysis(
                    kind: value.subtype ?? "capacity",
                    targetIndex: value.targetIndex ?? 0,
                    evidence: message, horizonDays: 7, budgetMinutes: 0,
                    hypotheticalDurationMinutes: duration,
                    durationEvidence: duration > 0 ? message : "none"
                ))
            case "recurrence":
                return .recurrence(HolisticRecurrence(
                    targetIndex: value.targetIndex ?? 0,
                    evidence: message,
                    operation: value.subtype ?? "stop"
                ))
            case "acknowledge":
                return .acknowledge(HolisticResponse(
                    evidence: message, reply: value.detail ?? "Okay."
                ))
            case "undo": return .undo(EvidenceArgs(evidence: message))
            case "replan": return .replan(EvidenceArgs(evidence: message))
            case "social":
                return .social(HolisticResponse(
                    evidence: message, reply: value.detail ?? "Anytime."
                ))
            default: return nil
            }
        })
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct UnifiedAction {
        @Guide(.anyOf([
            "capture", "complete", "drop", "keep", "wait", "resume",
            "progress", "move", "revise", "note", "query", "analysis",
            "bulk_complete", "bulk_move", "recurrence", "acknowledge",
            "undo", "replan", "social",
        ])) var kind: String
        @Guide(description: "Exact user words supporting the whole action") var evidence: String
        @Guide(description: "New or replacement task label, or none") var task: String
        @Guide(description: "1-based affected open task number, or 0") var targetIndex: Int
        var date: DateConstraintArgs
        var deadline: DateConstraintArgs
        @Guide(description: "Exact clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
        @Guide(description: "Estimated minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["none", "high", "normal", "low"])) var priority: String
        @Guide(description: "Exact priority words, or none") var priorityEvidence: String
        var recurrence: RecurrenceConstraintArgs
        @Guide(description: "Note or progress detail copied from the user, or none") var note: String
        @Guide(description: "Removed fields: date, time, deadline, duration, priority, or note") var clearFields: [String]
        @Guide(.anyOf(["none", "today", "date", "all", "overdue", "week", "search", "done", "waiting"])) var queryKind: String
        @Guide(description: "Task search words, or none") var queryTerm: String
        @Guide(.anyOf(["today", "week", "all"])) var queryPeriod: String
        @Guide(.anyOf(["none", "capacity", "explain", "what_if"])) var analysisKind: String
        @Guide(description: "Planning horizon days, normally 7") var horizonDays: Int
        @Guide(description: "Available minutes, or 0") var budgetMinutes: Int
        @Guide(description: "Temporary task minutes, or 0") var hypotheticalDurationMinutes: Int
        @Guide(description: "Task numbers excluded from a bulk completion") var excludedTargets: [Int]
        @Guide(description: "One dated destination per task in a bulk move") var destinations: [MoveDestination]
        @Guide(.anyOf(["none", "skip", "stop"])) var recurrenceOperation: String
        @Guide(.anyOf(["none", "zero_report", "conversation"])) var responseKind: String
        @Guide(description: "Brief social reply, or none") var reply: String

        var target: TargetArgs {
            TargetArgs(targetIndex: targetIndex, evidence: evidence)
        }
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct UnifiedTurn {
        @Guide(
            description: "The complete ordered action list for this message",
            .maximumCount(16)
        ) var actions: [UnifiedAction]
    }

    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct EvidenceArgs {
        @Guide(description: "Exact words copied from the user message") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct TargetArgs {
        @Guide(description: "1-based number of the affected open task") var targetIndex: Int
        @Guide(description: "Exact user words proving this effect") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureArgs {
        @Guide(description: "One short actionable new task without dates, clocks, or another coordinated obligation") var task: String
        @Guide(description: "Exact user words supporting this one new task") var evidence: String
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday", "offset", "weekend", "week", "month", "month_day", "ordinal_day", "absolute"])) var scheduleKind: String
        @Guide(description: "Exact planned-day words, or none") var scheduleEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var scheduleWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var scheduleWhich: String
        @Guide(description: "Positive offset amount, or 0") var scheduleN: Int
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var scheduleUnit: String
        @Guide(.anyOf(["none", "start", "early", "mid", "late", "end"])) var schedulePart: String
        @Guide(.anyOf(["none", "start", "end"])) var scheduleAnchor: String
        @Guide(description: "Explicit four-digit year, or 0") var scheduleYear: Int
        @Guide(description: "Explicit month number, or 0") var scheduleMonth: Int
        @Guide(description: "Explicit day of month, or 0") var scheduleDay: Int
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday", "offset", "weekend", "week", "month", "month_day", "ordinal_day", "absolute"])) var deadlineKind: String
        @Guide(description: "Exact hard-deadline words, or none") var deadlineEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var deadlineWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var deadlineWhich: String
        @Guide(description: "Positive deadline offset amount, or 0") var deadlineN: Int
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var deadlineUnit: String
        @Guide(.anyOf(["none", "start", "early", "mid", "late", "end"])) var deadlinePart: String
        @Guide(.anyOf(["none", "start", "end"])) var deadlineAnchor: String
        @Guide(description: "Explicit deadline year, or 0") var deadlineYear: Int
        @Guide(description: "Explicit deadline month number, or 0") var deadlineMonth: Int
        @Guide(description: "Explicit deadline day of month, or 0") var deadlineDay: Int
        @Guide(description: "Estimated minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["high", "normal", "low"])) var priority: String
        @Guide(description: "Exact clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var recurrenceFrequency: String
        @Guide(description: "Repeat interval, normally 1, or 0 when not recurring") var recurrenceInterval: Int
        @Guide(description: "Repeated weekdays as sun through sat, or empty") var recurrenceWeekdays: [String]
        @Guide(description: "Repeated day of month, or 0") var recurrenceMonthDay: Int
        @Guide(description: "Repeated month number, or 0") var recurrenceMonth: Int
        @Guide(.anyOf(["fixed", "completion"])) var recurrenceAnchor: String
        @Guide(description: "Total occurrence count, or 0 for no count limit") var recurrenceCount: Int
        @Guide(description: "Exact recurrence words, or none") var recurrenceEvidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct DateConstraintArgs {
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday", "offset", "weekend", "week", "month", "month_day", "ordinal_day", "absolute"])) var dateKind: String
        @Guide(description: "Exact occurrence-date words, or none") var dateEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var dateWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var dateWhich: String
        @Guide(description: "Positive offset amount, or 0") var dateN: Int
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var dateUnit: String
        @Guide(.anyOf(["none", "start", "early", "mid", "late", "end"])) var datePart: String
        @Guide(.anyOf(["none", "start", "end"])) var dateAnchor: String
        @Guide(description: "Explicit four-digit year, or 0") var dateYear: Int
        @Guide(description: "Explicit month number, or 0") var dateMonth: Int
        @Guide(description: "Explicit day of month, or 0") var dateDay: Int
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct RecurrenceConstraintArgs {
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var recurrenceFrequency: String
        @Guide(description: "Repeat interval, normally 1, or 0") var recurrenceInterval: Int
        @Guide(description: "Repeated weekdays as sun through sat, or empty") var recurrenceWeekdays: [String]
        @Guide(description: "Repeated day of month, or 0") var recurrenceMonthDay: Int
        @Guide(description: "Repeated month number, or 0") var recurrenceMonth: Int
        @Guide(.anyOf(["fixed", "completion"])) var recurrenceAnchor: String
        @Guide(description: "Total occurrence count, or 0") var recurrenceCount: Int
        @Guide(description: "Exact recurrence words, or none") var recurrenceEvidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureBatchArgs {
        @Guide(description: "Every distinct new obligation, one item per task or appointment") var tasks: [CaptureArgs]
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct SimpleCaptureItem {
        @Guide(description: "One short actionable task label") var task: String
        @Guide(description: "Exact user words expressing this obligation") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct SimpleCaptureBatch {
        @Guide(description: "Every genuine new obligation, or empty") var tasks: [SimpleCaptureItem]
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureDecompositionItem {
        @Guide(description: "One short appointment label naming only its own person or object") var task: String
        @Guide(description: "Exact user words naming only this appointment") var evidence: String
        @Guide(description: "The exact clock text paired with this appointment") var clockText: String
        @Guide(.anyOf(["am", "pm"])) var clockInterpretation: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureDecompositionArgs {
        @Guide(description: "The separate appointments in their original order") var tasks: [CaptureDecompositionItem]
    }
    struct GroundedCaptureLabel {
        let task: String
        let evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureLabelArgs {
        @Guide(description: "Only this appointment's short action label") var task: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct SingleClockArgs {
        @Guide(.anyOf(["none", "clock"])) var kind: String
        @Guide(description: "Only the exact clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CoordinatedClockPairArgs {
        @Guide(.anyOf(["one_time_range", "two_appointments"])) var kind: String
        @Guide(description: "Only the exact first clock text") var firstClockText: String
        @Guide(.anyOf(["am", "pm"])) var firstClockInterpretation: String
        @Guide(description: "Only the exact second clock text") var secondClockText: String
        @Guide(.anyOf(["am", "pm"])) var secondClockInterpretation: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct MoveDestination {
        @Guide(description: "1-based open task number") var targetIndex: Int
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday", "offset", "weekend", "week", "month", "month_day", "ordinal_day", "absolute"])) var scheduleKind: String
        @Guide(description: "Exact date or day words from the user message") var dateEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var scheduleWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var scheduleWhich: String
        @Guide(description: "Positive offset amount, or 0") var scheduleN: Int
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var scheduleUnit: String
        @Guide(.anyOf(["none", "start", "early", "mid", "late", "end"])) var schedulePart: String
        @Guide(.anyOf(["none", "start", "end"])) var scheduleAnchor: String
        @Guide(description: "Explicit four-digit year, or 0") var scheduleYear: Int
        @Guide(description: "Explicit month number, or 0") var scheduleMonth: Int
        @Guide(description: "Explicit day of month, or 0") var scheduleDay: Int
        @Guide(description: "Exact clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct MoveArgs {
        var target: TargetArgs
        var destination: MoveDestination
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct AmendArgs {
        var target: TargetArgs
        @Guide(description: "Replacement task label") var task: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct ReviseArgs {
        var target: TargetArgs
        @Guide(description: "Full replacement task label, or none") var task: String
        @Guide(description: "Exact words supporting the replacement label, or none") var taskEvidence: String
        var date: DateConstraintArgs
        var deadline: DateConstraintArgs
        @Guide(description: "Exact replacement clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
        @Guide(description: "Replacement estimated minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["none", "high", "normal", "low"])) var priority: String
        @Guide(description: "Exact priority words, or none") var priorityEvidence: String
        @Guide(description: "Fields explicitly removed: date, time, deadline, duration, priority, or note") var clearFields: [String]
        @Guide(description: "Exact user words requesting this edit") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct NoteArgs {
        var target: TargetArgs
        @Guide(description: "Only the durable detail to attach, copied from the user") var text: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct PriorityArgs {
        var target: TargetArgs
        @Guide(.anyOf(["high", "normal", "low"])) var level: String
        @Guide(description: "Exact user words setting priority") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct DurationEditArgs {
        var target: TargetArgs
        @Guide(description: "Replacement estimated minutes") var minutes: Int
        @Guide(description: "Exact user words stating the estimate") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct ClearFieldArgs {
        var target: TargetArgs
        @Guide(.anyOf(["date", "time", "deadline", "duration", "priority", "note"])) var field: String
        @Guide(description: "Exact user words removing this field") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct QueryArgs {
        @Guide(.anyOf(["today", "date", "all", "overdue", "week", "search", "done", "waiting"])) var kind: String
        var date: DateConstraintArgs
        @Guide(description: "Search words, or none") var term: String
        @Guide(.anyOf(["today", "week", "all"])) var period: String
        @Guide(description: "Exact user words asking this question") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct QueryClassificationArgs {
        @Guide(.anyOf(["none", "today", "date", "all", "overdue", "week", "search", "done", "waiting"])) var kind: String
        @Guide(.anyOf(["open", "completed", "waiting", "any"])) var status: String
        var date: DateConstraintArgs
        @Guide(description: "Search words, or none") var term: String
        @Guide(.anyOf(["today", "week", "all"])) var period: String
        @Guide(description: "Exact user words asking for task state, or none") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct DateQueryClassificationArgs {
        @Guide(.anyOf(["date", "other"])) var mode: String
        var date: DateConstraintArgs
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct SimpleQueryClassificationArgs {
        @Guide(.anyOf(["today", "all", "overdue", "week", "search", "done", "waiting"])) var kind: String
        @Guide(description: "Search words from the user, or none") var term: String
        @Guide(.anyOf(["today", "week", "all"])) var period: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct IntentClassificationArgs {
        @Guide(.anyOf(["change", "report", "new_task", "planning", "social", "retrieval"])) var intent: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct SocialAuditArgs {
        @Guide(.anyOf(["social", "task"])) var mode: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct RetrievalAuditArgs {
        @Guide(.anyOf(["retrieval", "new_task", "task_change", "report"])) var mode: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct NewObligationAuditArgs {
        @Guide(.anyOf(["new_task", "retrieval", "task_change", "report", "other"])) var mode: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct ChangeClassificationArgs {
        @Guide(.anyOf(["other", "metadata", "note", "wait", "resume", "move", "rename", "drop", "keep", "recurrence"])) var kind: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct RecurrenceAuditArgs {
        @Guide(.anyOf(["none", "day", "week", "month", "year"])) var frequency: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct BulkCompleteArgs {
        @Guide(description: "1-based task numbers explicitly excluded and left open") var excludedTargets: [Int]
        @Guide(description: "Exact user words expressing bulk completion") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct BulkMoveArgs {
        @Guide(description: "One destination for every affected task") var destinations: [MoveDestination]
        @Guide(description: "Exact user words expressing the bulk move") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct RecurrenceArgs {
        @Guide(description: "1-based number of the recurring task") var targetIndex: Int
        @Guide(.anyOf(["skip", "stop"])) var operation: String
        @Guide(description: "Exact user words requesting this recurrence change") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct AnalysisArgs {
        @Guide(.anyOf(["capacity", "explain", "what_if"])) var kind: String
        @Guide(description: "1-based affected task number, or 0 for the whole plan") var targetIndex: Int
        @Guide(description: "Planning horizon in days; use 7 when unstated") var horizonDays: Int
        @Guide(description: "Available time budget in minutes, or 0") var budgetMinutes: Int
        @Guide(description: "Temporary task duration in minutes, or 0") var hypotheticalDurationMinutes: Int
        @Guide(description: "Exact words supporting the temporary duration, or none") var durationEvidence: String
        @Guide(description: "Exact user words requesting analysis") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct AnalysisClassificationArgs {
        @Guide(.anyOf(["none", "capacity", "explain", "what_if"])) var kind: String
        @Guide(description: "1-based affected task number, or 0") var targetIndex: Int
        @Guide(description: "Planning horizon in days; use 7 when unstated") var horizonDays: Int
        @Guide(description: "Available time budget in minutes, or 0") var budgetMinutes: Int
        @Guide(description: "Temporary task duration in minutes, or 0") var hypotheticalDurationMinutes: Int
        @Guide(description: "Exact words supporting that duration, or none") var durationEvidence: String
        @Guide(description: "Exact words requesting analysis, or none") var evidence: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    struct Acknowledge: Tool {
        let collector: Collector; let name = "acknowledge_no_work"
        let description = "Use for an answer meaning no accomplishments or zero completed work, including terse idiom, slang, metaphor, or another language."
        func call(arguments: EvidenceArgs) async throws -> String {
            await collector.append(.acknowledge); return "Acknowledged."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Undo: Tool {
        let collector: Collector; let name = "undo_recent_change"
        let description = "Use for a standalone retraction of the immediately preceding task change, only when recent undo is available."
        func call(arguments: EvidenceArgs) async throws -> String {
            await collector.append(.undo); return "Undo requested."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Replan: Tool {
        let collector: Collector; let name = "replan_schedule"
        let description = "Use when the user explicitly asks Hob to plan, schedule, time-block, or rebuild their existing on-deck work and no individual task changed."
        func call(arguments: EvidenceArgs) async throws -> String {
            await collector.append(.replan); return "Replan requested."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Progress: Tool {
        let collector: Collector; let name = "leave_partial_progress_open"
        let description = "Use when the user worked on or made progress on an existing task without clearly finishing it."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.progress(arguments)); return "Left open."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Complete: Tool {
        let collector: Collector; let name = "complete_task"
        let description = "Mark one existing task complete only when clearly reported fully finished. Never use for progress, scheduling, negation, or exclusion."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.complete(arguments)); return "Completed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Drop: Tool {
        let collector: Collector; let name = "drop_task"
        let description = "Drop one task only when explicitly asked to drop, remove, delete, or cancel it. An unfinished or negated task is not dropped."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.drop(arguments)); return "Dropped."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Move: Tool {
        let collector: Collector; let name = "move_task"
        let description = "Move one existing task to a stated date or clock. Scheduling is never completion."
        func call(arguments: MoveArgs) async throws -> String {
            await collector.append(.move(arguments)); return "Moved."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Amend: Tool {
        let collector: Collector; let name = "edit_task_text"
        let description = "Replace the wording of one existing task when explicitly edited or renamed."
        func call(arguments: AmendArgs) async throws -> String {
            await collector.append(.amend(arguments)); return "Edited."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Revise: Tool {
        let collector: Collector; let name = "revise_task"
        let description = "Change the title, planned date, clock, deadline, estimate, priority, or remove one of those fields on an existing task. Use amend only for a title-only rename."
        func call(arguments: ReviseArgs) async throws -> String {
            await collector.append(.revise(arguments)); return "Task revision proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Note: Tool {
        let collector: Collector; let name = "add_note"
        let description = "Attach a durable detail to an existing task without changing its title or schedule."
        func call(arguments: NoteArgs) async throws -> String {
            await collector.append(.note(arguments)); return "Note proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct SetPriority: Tool {
        let collector: Collector; let name = "set_task_priority"
        let description = "Set high, normal, or low priority on one existing task."
        func call(arguments: PriorityArgs) async throws -> String {
            await collector.append(.priority(arguments)); return "Priority proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct SetDuration: Tool {
        let collector: Collector; let name = "set_task_estimate"
        let description = "Set the estimated duration of one existing task in minutes."
        func call(arguments: DurationEditArgs) async throws -> String {
            await collector.append(.duration(arguments)); return "Estimate proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct ClearField: Tool {
        let collector: Collector; let name = "clear_task_field"
        let description = "Remove an explicitly named date, clock, deadline, estimate, priority, or note from one existing task."
        func call(arguments: ClearFieldArgs) async throws -> String {
            await collector.append(.clearField(arguments)); return "Clear proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Wait: Tool {
        let collector: Collector; let name = "park_waiting"
        let description = "Park an existing task because progress is blocked for now."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.wait(arguments)); return "Waiting state proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Resume: Tool {
        let collector: Collector; let name = "resume_waiting"
        let description = "Return an existing waiting task to the active deck because its blocker cleared."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.resume(arguments)); return "Resume proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Query: Tool {
        let collector: Collector; let name = "query_tasks"
        let description = "Answer a read-only question about today's tasks, a date, the next week, overdue work, all open work, waiting work, completed history, or text search. Never use for capacity or what-if planning."
        func call(arguments: QueryArgs) async throws -> String {
            await collector.append(.query(arguments)); return "Task query proposed."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Keep: Tool {
        let collector: Collector; let name = "keep_task_open"
        let description = "Keep a stale or focused task open when the user says it should stay on deck."
        func call(arguments: TargetArgs) async throws -> String {
            await collector.append(.keep(arguments)); return "Kept open."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Capture: Tool {
        let collector: Collector; let name = "add_new_tasks"
        let description = "Add every genuinely new obligation in one batch. Use one item per task, split coordinated appointments, and pair their clocks in order. Never use for an effect on existing work. A planned day is not a deadline."
        func call(arguments: CaptureBatchArgs) async throws -> String {
            for task in arguments.tasks {
                await collector.append(.capture(task))
            }
            return "Added \(arguments.tasks.count)."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct BulkComplete: Tool {
        let collector: Collector; let name = "complete_all_except"
        let description = "Use once for an all/everything completion report. excludedTargets are exactly the task numbers the user says remain unfinished."
        func call(arguments: BulkCompleteArgs) async throws -> String {
            await collector.append(.bulkComplete(arguments)); return "Bulk completion recorded."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct BulkMove: Tool {
        let collector: Collector; let name = "move_multiple_tasks"
        let description = "Use once to move all/everything or several existing tasks. Supply one destination per affected task and honor exceptions."
        func call(arguments: BulkMoveArgs) async throws -> String {
            await collector.append(.bulkMove(arguments)); return "Bulk move recorded."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Recurrence: Tool {
        let collector: Collector; let name = "change_recurrence"
        let description = "Skip the next occurrence or stop repetition for one existing recurring task. Never complete or drop the task."
        func call(arguments: RecurrenceArgs) async throws -> String {
            await collector.append(.recurrence(arguments)); return "Recurrence updated."
        }
    }
    @available(iOS 26.0, macOS 26.0, *)
    struct Analyze: Tool {
        let collector: Collector; let name = "analyze_plan"
        let description = "Use for read-only capacity, why/explanation, fit, or what-if questions. A what-if duration is temporary and never edits a task."
        func call(arguments: AnalysisArgs) async throws -> String {
            await collector.append(.analysis(arguments)); return "Analysis requested."
        }
    }
    #endif

    private static func dateIntent(
        kind: String,
        weekday: String,
        which: String,
        n: Int = 0,
        unit: String = "none",
        part: String = "none",
        anchor: String = "none",
        year: Int = 0,
        month: Int = 0,
        day: Int = 0,
        evidence: String = ""
    ) throws -> RuntimeDateIntent? {
        let evidenceWords = Set(words(evidence))
        if evidenceWords.contains("tomorrow") { return RuntimeDateIntent(kind: "tomorrow") }
        if evidenceWords.contains("today") { return RuntimeDateIntent(kind: "today") }
        if kind == "none" { return nil }
        if kind == "today" || kind == "tomorrow" { return RuntimeDateIntent(kind: kind) }
        let weekdays = [
            "mon": ["mon", "monday"], "tue": ["tue", "tuesday"],
            "wed": ["wed", "wednesday"], "thu": ["thu", "thursday"],
            "fri": ["fri", "friday"], "sat": ["sat", "saturday"],
            "sun": ["sun", "sunday"],
        ]
        let evidencedDay = weekdays.first { _, names in
            !Set(names).isDisjoint(with: evidenceWords)
        }?.key
        let resolvedDay = evidencedDay ?? weekday
        let resolvedWhich = evidenceWords.contains("next") ? "next" : which
        if kind == "weekday" {
            guard weekdays[resolvedDay] != nil,
                  ["this", "next"].contains(resolvedWhich) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(
                kind: "weekday", which: resolvedWhich, day: resolvedDay
            )
        }
        if kind == "offset" {
            guard n > 0, ["day", "week", "month", "year"].contains(unit),
                  numberIsGrounded(n, in: evidence) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(kind: kind, n: n, unit: unit)
        }
        if kind == "weekend" {
            guard ["this", "next"].contains(resolvedWhich) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(kind: kind, which: resolvedWhich)
        }
        if kind == "week" || kind == "month" {
            guard ["this", "next"].contains(resolvedWhich) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(
                kind: kind, which: resolvedWhich,
                part: part == "none" ? nil : part,
                anchor: anchor == "none" ? nil : anchor
            )
        }
        if kind == "month_day" || kind == "ordinal_day" {
            guard (1...31).contains(day), numberIsGrounded(day, in: evidence),
                  month == 0 || ((1...12).contains(month)
                    && monthIsGrounded(month, in: evidence)) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(
                kind: kind, month: month > 0 ? month : nil, dayNumber: day
            )
        }
        if kind == "absolute" {
            guard (1...9999).contains(year), (1...12).contains(month),
                  (1...31).contains(day),
                  numberIsGrounded(year, in: evidence),
                  monthIsGrounded(month, in: evidence),
                  numberIsGrounded(day, in: evidence) else {
                throw RuntimeInterpretationError.invalidOutput
            }
            return RuntimeDateIntent(
                kind: kind, year: year, month: month, dayNumber: day
            )
        }
        throw RuntimeInterpretationError.invalidOutput
    }

    private static func numberIsGrounded(_ value: Int, in evidence: String) -> Bool {
        let tokens = Set(words(evidence))
        if tokens.contains(String(value)) { return true }
        let names = [
            1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
            6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten",
            11: "eleven", 12: "twelve", 13: "thirteen", 14: "fourteen",
            15: "fifteen", 16: "sixteen", 17: "seventeen",
            18: "eighteen", 19: "nineteen", 20: "twenty",
        ]
        return names[value].map(tokens.contains) == true
    }

    private static func monthIsGrounded(_ value: Int, in evidence: String) -> Bool {
        let tokens = Set(words(evidence))
        if tokens.contains(String(value)) { return true }
        let months = [
            1: ["jan", "january"], 2: ["feb", "february"],
            3: ["mar", "march"], 4: ["apr", "april"],
            5: ["may"], 6: ["jun", "june"], 7: ["jul", "july"],
            8: ["aug", "august"], 9: ["sep", "sept", "september"],
            10: ["oct", "october"], 11: ["nov", "november"],
            12: ["dec", "december"],
        ]
        return months[value].map { !Set($0).isDisjoint(with: tokens) } == true
    }

    private static func normalizedTime(
        text: String, interpretation: String, originalMessage: String
    ) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
            return nil
        }
        return RuntimeGeneratedClock.normalizeEvidence(
            text,
            interpretation: explicitMeridiem(in: text) ?? interpretation,
            in: originalMessage
        )
    }

    private static func hasRecentChange(tasks: [RuntimeTask], now: String) -> Bool {
        guard let instant = ISO8601DateFormatter().date(from: now) else { return false }
        return tasks.contains { task in
            guard let updated = ISO8601DateFormatter().date(from: task.updatedAt) else {
                return false
            }
            let age = instant.timeIntervalSince(updated)
            return age >= 0 && age <= 15 * 60
        }
    }
}
