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
                recentChange: Self.hasRecentChange(tasks: tasks, now: now)
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
        recentChange: Bool
    ) async throws -> [RuntimeAction] {
        let collector = Collector()
        var tools: [any Tool] = [
            Acknowledge(collector: collector), Undo(collector: collector),
            Replan(collector: collector), Capture(collector: collector),
        ]
        if !open.isEmpty {
            tools += [
                Progress(collector: collector), BulkComplete(collector: collector),
                BulkMove(collector: collector), Complete(collector: collector),
                Drop(collector: collector), Move(collector: collector),
                Amend(collector: collector), Keep(collector: collector),
            ]
        }
        let prompt = """
        Current instant: \(now)
        Timezone: \(timezone)
        Recent undo available: \(recentChange)
        Open tasks: \(open.enumerated().map { "\($0.offset + 1). \($0.element.task)" })
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
        guard succeeded else { throw RuntimeInterpretationError.invalidOutput }
        let firstPass = await collector.values()
        if !open.isEmpty,
           !firstPass.contains(where: {
               switch $0 {
               case .bulkComplete, .bulkMove, .acknowledge: return true
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
                 .bulkComplete, .bulkMove: return true
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
        return try await validate(
            reviewed, message: message, open: open,
            recentChange: recentChange
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func validate(
        _ rawProposals: [Proposal],
        message: String,
        open: [RuntimeTask],
        recentChange: Bool
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
                      captureIsNew(task, evidence: value.evidence, open: open)
                else { continue }
                if !open.isEmpty {
                    let approved = try await captureAudit(
                        task: task, evidence: value.evidence, message: message
                    )
                    if !approved { continue }
                }
                let duration = (5...480).contains(value.durationMinutes)
                    && RuntimeConstraintEvidence.isSupportedDuration(
                        value.durationEvidence, in: message
                    ) ? value.durationMinutes : nil
                result.append(RuntimeAction(
                    type: "capture", task: task, raw: message,
                    when: RuntimeConstraintEvidence.contains(
                        value.scheduleEvidence, in: message
                    ) ? try dateIntent(
                        kind: value.scheduleKind, weekday: value.scheduleWeekday,
                        which: value.scheduleWhich, evidence: value.scheduleEvidence
                    ) : nil,
                    deadline: RuntimeConstraintEvidence.contains(
                        value.deadlineEvidence, in: message
                    ) ? try dateIntent(
                        kind: value.deadlineKind, weekday: value.deadlineWeekday,
                        which: value.deadlineWhich, evidence: value.deadlineEvidence
                    ) : nil,
                    time: recoveredTime(
                        task: task, evidence: value.evidence,
                        text: value.clockText,
                        interpretation: value.clockInterpretation,
                        originalMessage: message
                    ),
                    durationMinutes: duration,
                    priority: ["high", "normal", "low"].contains(value.priority)
                        ? value.priority : "normal",
                    confidence: 1
                ))
            case .complete(let value):
                guard let target = resolvedTarget(
                    value, message: message, open: open
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
                    value, message: message, open: open
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
                    value.target, message: message, open: open
                ), try await audit(
                    "scheduled or moved to a stated date or time",
                    target: target, message: message, open: open
                ) else { continue }
                var destination = value.destination
                destination.targetIndex = target
                guard RuntimeConstraintEvidence.contains(
                    destination.dateEvidence, in: message
                ) else { continue }
                let action = try moveAction(destination, message: message)
                guard action.when != nil || action.time != nil else { continue }
                result.append(action)
            case .amend(let value):
                guard supports(value.target, message: message, open: open) else { continue }
                let task = value.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { continue }
                result.append(RuntimeAction(
                    type: "amend", task: task, target: String(value.target.targetIndex)
                ))
            case .keep(let value):
                guard supports(value, message: message, open: open) else { continue }
                result.append(RuntimeAction(type: "keep", target: String(value.targetIndex)))
            case .bulkComplete, .bulkMove:
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
            let signature = [action.type, action.target ?? "", action.task ?? ""]
                .joined(separator: "|")
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
        open: [RuntimeTask]
    ) -> Bool {
        guard (1...open.count).contains(value.targetIndex),
              RuntimeConstraintEvidence.contains(value.evidence, in: message)
        else { return false }
        if open.count == 1 { return true }
        let evidence = Set(words(value.evidence))
        let task = Set(words(open[value.targetIndex - 1].task).filter { $0.count >= 3 })
        if !task.isDisjoint(with: evidence) { return true }
        if evidence.contains(String(value.targetIndex)) { return true }
        let ordinals = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
        ]
        return ordinals[value.targetIndex].map(evidence.contains) ?? false
    }

    private static func resolvedTarget(
        _ value: TargetArgs,
        message: String,
        open: [RuntimeTask]
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
        if supports(value, message: message, open: open) { return value.targetIndex }
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
        open: [RuntimeTask]
    ) -> Bool {
        let taskWords = Set(words(task).filter { $0.count >= 3 })
        let evidenceWords = Set(words(evidence).filter { $0.count >= 3 })
        guard !taskWords.isEmpty, !taskWords.isDisjoint(with: evidenceWords) else {
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
                    clocks in order. Keep constraints out of task labels. Return
                    an empty list for a reply, status report, or replan request.
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
            deadlineKind: initial.deadlineKind,
            deadlineEvidence: initial.deadlineEvidence,
            deadlineWeekday: initial.deadlineWeekday,
            deadlineWhich: initial.deadlineWhich,
            durationMinutes: initial.durationMinutes,
            durationEvidence: initial.durationEvidence,
            priority: initial.priority,
            clockText: item.clockText,
            clockInterpretation: item.clockInterpretation
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
        guard interpretation == "am" || interpretation == "pm" else { return nil }
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
            candidate, interpretation: interpretation, in: originalMessage
        )
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
                which: value.scheduleWhich, evidence: value.dateEvidence
            ),
            time: normalizedTime(
                text: value.clockText,
                interpretation: value.clockInterpretation,
                originalMessage: message
            ), confidence: 1
        )
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
        case bulkComplete(BulkCompleteArgs), bulkMove(BulkMoveArgs)
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
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday"])) var scheduleKind: String
        @Guide(description: "Exact planned-day words, or none") var scheduleEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var scheduleWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var scheduleWhich: String
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday"])) var deadlineKind: String
        @Guide(description: "Exact hard-deadline words, or none") var deadlineEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var deadlineWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var deadlineWhich: String
        @Guide(description: "Estimated minutes, or 0") var durationMinutes: Int
        @Guide(description: "Exact effort words, or none") var durationEvidence: String
        @Guide(.anyOf(["high", "normal", "low"])) var priority: String
        @Guide(description: "Exact clock text, or none") var clockText: String
        @Guide(.anyOf(["none", "am", "pm"])) var clockInterpretation: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct CaptureBatchArgs {
        @Guide(description: "Every distinct new obligation, one item per task or appointment") var tasks: [CaptureArgs]
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
        @Guide(.anyOf(["none", "today", "tomorrow", "weekday"])) var scheduleKind: String
        @Guide(description: "Exact date or day words from the user message") var dateEvidence: String
        @Guide(.anyOf(["none", "mon", "tue", "wed", "thu", "fri", "sat", "sun"])) var scheduleWeekday: String
        @Guide(.anyOf(["none", "this", "next"])) var scheduleWhich: String
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
    struct BulkCompleteArgs {
        @Guide(description: "1-based task numbers explicitly excluded and left open") var excludedTargets: [Int]
        @Guide(description: "Exact user words expressing bulk completion") var evidence: String
    }
    @available(iOS 26.0, macOS 26.0, *) @Generable
    struct BulkMoveArgs {
        @Guide(description: "One destination for every affected task") var destinations: [MoveDestination]
        @Guide(description: "Exact user words expressing the bulk move") var evidence: String
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
        let description = "Use when changed circumstances require a new plan but no individual task changed."
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
    #endif

    private static func dateIntent(
        kind: String, weekday: String, which: String, evidence: String = ""
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
        guard kind == "weekday", weekdays[resolvedDay] != nil,
              ["this", "next"].contains(resolvedWhich) else {
            throw RuntimeInterpretationError.invalidOutput
        }
        return RuntimeDateIntent(kind: "weekday", which: resolvedWhich, day: resolvedDay)
    }

    private static func normalizedTime(
        text: String, interpretation: String, originalMessage: String
    ) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
            return nil
        }
        return RuntimeGeneratedClock.normalizeEvidence(
            text, interpretation: interpretation, in: originalMessage
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
