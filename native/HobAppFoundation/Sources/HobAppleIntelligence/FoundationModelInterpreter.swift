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
    @available(iOS 26.0, macOS 26.0, *)
    private static func callTools(
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
        if ["new_task", "retrieval"].contains(intent),
           changeKind == "other",
           let dateQuery = try? await extractDateQuery(message) {
            return [dateQuery]
        }
        if ["new_task", "retrieval"].contains(intent),
           changeKind == "other",
           let dateQuery = try? await recoverRelativeDateQuery(message) {
            return [dateQuery]
        }
        if ["new_task", "retrieval"].contains(intent),
           changeKind == "other",
           try await confirmsNewObligation(message) {
            let captures = try await extractNewCaptures(
                message: message, now: now, timezone: timezone
            )
            if !captures.isEmpty {
                do {
                    let actions = try await validate(
                        captures.map(Proposal.capture), message: message,
                        open: open, recentChange: recentChange,
                        newObligationConfirmed: true
                    )
                    return actions
                } catch {}
            }
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
        Use add_note, wait_for_someone, and resume_waiting for durable task
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
        if reviewed.isEmpty,
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
        guard value.recurrenceFrequency != "none",
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
        guard value.recurrenceFrequency != "none",
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
    private static func classifyIntent(
        _ message: String
    ) async throws -> String {
        let instructions = """
        First classify the user's intent. Retrieval means asking to view, list,
        find, search, or recall saved task state. Change means editing, moving,
        parking, resuming, or annotating a task. Report means saying what
        happened. New task means adding an obligation. Planning means capacity,
        explanation, what-if, or a schedule request. Changing a saved task's
        priority or estimate is change, even when a duration appears. “Make the
        report high priority and 90 minutes” is change. Planning is reserved for
        questions such as “will it fit?” or “what if it takes 90 minutes?” and
        explicit requests to build a schedule. For retrieval only,
        classify the requested saved task state. Use today, date, all, overdue,
        week, search, done, or waiting. Completed-history questions use done.
        Finding words in saved tasks uses search. Copy evidence exactly from the
        user message. For every non-retrieval intent use kind none.
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
    private static func confirmsNewObligation(_ message: String) async throws -> Bool {
        let instructions = """
        Decide whether the user adds at least one genuinely new obligation.
        A compact conversational continuation may begin with a conjunction and
        contain only an appointment or activity label plus a clock. For example,
        “And dentist at 2:30” is a new obligation. Spelling mistakes do not
        change that intent. Retrieval asks to see saved information. A task
        change affects existing work. A report describes what happened.
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
        return modes.count { $0 == "new_task" } >= 4
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
        let collector: Collector; let name = "wait_for_someone"
        let description = "Park an existing task because progress is blocked on another person or external event."
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
