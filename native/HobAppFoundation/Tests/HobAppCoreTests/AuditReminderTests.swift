// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage

@Test func legacySyncRoundTripsPreserveEditIdentityWithoutHidingConflicts() throws {
    let now = "2026-09-18T08:00:00-04:00"
    let legacy = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: nil, dueTime: nil,
        status: "open", createdAt: now, updatedAt: now)
    var current = legacy
    current.revisionID = UUID().uuidString
    func operation(_ task: RuntimeTask) -> RuntimeTaskOperation {
        RuntimeTaskOperation(id: "edit-operation", taskID: task.id, occurredAt: now, sequence: 1, task: task)
    }
    let old = operation(legacy)
    let new = operation(current)
    #expect(try RuntimeTaskOperationMerge.merge(local: [old], remote: [new]) == [new])
    #expect(try RuntimeTaskOperationMerge.merge(local: [new], remote: [old]) == [new])
    var conflicting = legacy
    conflicting.task = "Call someone else"
    #expect(throws: RuntimeTaskSyncError.conflict) {
        try RuntimeTaskOperationMerge.merge(local: [new], remote: [operation(conflicting)])
    }
    current.revisionID = "invalid-revision"
    #expect(!operation(current).isValid)
}

@Test func captureAndQueryShareEverySupportedDateInterpretation() throws {
    let now = "2026-09-18T08:00:00-04:00"
    let instant = try #require(ISO8601DateFormatter().date(from: now))
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let intents = [
        RuntimeDateIntent(kind: "today"), RuntimeDateIntent(kind: "tomorrow"),
        RuntimeDateIntent(kind: "yesterday"),
        RuntimeDateIntent(kind: "weekday", which: "next", day: "mon"),
        RuntimeDateIntent(kind: "weekday", which: "this", day: "mon"),
        RuntimeDateIntent(kind: "weekend", which: "next"),
        RuntimeDateIntent(kind: "week", which: "next", part: "mid"),
        RuntimeDateIntent(kind: "month", which: "next", anchor: "end"),
        RuntimeDateIntent(kind: "month_day", month: 10, dayNumber: 4),
        RuntimeDateIntent(kind: "ordinal_day", dayNumber: 23),
        RuntimeDateIntent(kind: "offset", n: 3, unit: "week"),
        RuntimeDateIntent(kind: "absolute", year: 2026, month: 12, dayNumber: 8),
    ]
    for intent in intents {
        var runtime = TaskRuntime()
        let result = runtime.process(RuntimeTurnRequest(requestID: UUID().uuidString, message: "date fixture",
            now: now, timezone: zone.identifier, actions: [
                RuntimeAction(type: "capture", task: "Date fixture", raw: "Date fixture", when: intent)]))
        #expect(result.outcome.disposition == .applied)
        let answer = try RuntimeTaskQueryEngine.answer(action: RuntimeAction(type: "query", when: intent, queryKind: "date"),
            tasks: result.outcome.tasks, now: instant, timezone: zone)
        #expect(answer.contains("Date fixture"), "\(intent): \(answer)")
    }
    #expect(RuntimeDateResolver.resolve(RuntimeDateIntent(kind: "absolute", year: 2026, month: 2, dayNumber: 30),
        now: now, timezone: zone.identifier) == .invalid)
}

@Test func ongoingCaptureSurvivesPersistenceAndRapidEditsHaveDistinctRevisions() throws {
    let now = "2026-09-18T08:00:00-04:00"
    var runtime = TaskRuntime()
    func request(_ actions: [RuntimeAction]) -> RuntimeTurnRequest {
        RuntimeTurnRequest(requestID: UUID().uuidString, message: "fixture", now: now,
            timezone: "America/New_York", actions: actions)
    }
    let created = runtime.process(request([RuntimeAction(type: "capture", task: "Morning pill", raw: "Morning pill",
        reviewPolicy: "never")])).outcome.tasks[0]
    #expect(created.reviewPolicy == "never")
    #expect(!created.allowsStaleReview)
    let edited = runtime.process(request([RuntimeAction(type: "revise", task: "Take morning pill", target: created.id)])).outcome.tasks[0]
    #expect(edited.updatedAt == created.updatedAt)
    #expect(edited.revision != created.revision)
    #expect(RuntimeTask.isValidRevision(edited.revision))
    let restored = runtime.process(request([RuntimeAction(type: "undo")])).outcome.tasks[0]
    #expect(restored.revision != edited.revision && restored.revision != created.revision)
    let roundTrip = try JSONDecoder().decode(RuntimePersistentState.self,
        from: JSONEncoder().encode(runtime.persistentState)).validated()
    #expect(roundTrip.tasks == runtime.tasks)
    #expect(roundTrip.tasks[0].reviewPolicy == "never")
}

@Test func rapidEditInvalidatesUnadoptedPlanAndLegacyRevisionsRemainReadable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = "2026-09-18T08:00:00-04:00"
    let legacy = RuntimeTask(id: "a1", rawText: "Write letter", task: "Write letter", dueDate: nil, dueTime: nil,
        status: "open", createdAt: now, updatedAt: now)
    let store = TaskStateStore(directoryURL: directory)
    try store.save(RuntimePersistentState(version: 12, tasks: [legacy], undoSnapshots: []))
    let runtime = try DurableTaskRuntime(store: store)
    #expect(await runtime.snapshot().tasks[0].revision == now)
    let proposal = try await runtime.proposeSchedule(RuntimeScheduleRequest(proposalID: "before-edit", generatedAt: now,
        startDate: "2026-09-18", timezone: "America/New_York", includedUntimedTaskIDs: [legacy.id]))
    _ = try await runtime.process(RuntimeTurnRequest(requestID: "rapid-edit", message: "rename", now: now,
        timezone: "America/New_York", actions: [RuntimeAction(type: "revise", task: "Write long letter", target: legacy.id)]))
    await #expect(throws: (any Error).self) { try await runtime.adoptSchedule(proposalID: proposal.id, at: now) }
}

@Test func adoptedSplitWorkKeepsEveryBlockReminder() throws {
    let timestamp = "2026-09-18T08:00:00-04:00"
    let task = RuntimeTask(id: "a1", rawText: "Write report", task: "Write report", dueDate: nil, dueTime: nil,
        status: "open", createdAt: timestamp, updatedAt: timestamp)
    let blocks = [9, 11].map { hour in
        RuntimeScheduleBlock(id: "block-\(hour)", taskID: task.id, task: task.task,
            startAt: String(format: "2026-09-18T%02d:00:00-04:00", hour),
            endAt: String(format: "2026-09-18T%02d:30:00-04:00", hour), durationMinutes: 30, priority: "normal")
    }
    let proposal = RuntimeScheduleProposal(id: "split", generatedAt: timestamp, startDate: "2026-09-18",
        timezone: "America/New_York", workStart: "09:00", workEnd: "17:30", taskVersions: [task.id: task.updatedAt],
        blocks: blocks, unscheduled: [], assumptions: [], plannedUntimedTaskIDs: [task.id])
    let adopted = RuntimeAdoptedSchedule(proposal: proposal, adoptedAt: timestamp)
    let reminders = RuntimeTaskReminder.build(tasks: [task], adopted: adopted,
        timezone: try #require(TimeZone(identifier: "America/New_York")))
    #expect(reminders.map(\.blockID) == blocks.map(\.id))
}

@Test func explicitRemindersIgnoreWorkHoursAndTrackSavedRevision() throws {
    var task = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: "2026-09-20", dueTime: "21:00",
        status: "open", createdAt: "2026-09-18T08:00:00-04:00", updatedAt: "2026-09-18T08:00:00-04:00")
    let timezone = try #require(TimeZone(identifier: "America/New_York"))
    let reminder = try #require(RuntimeTaskReminder.build(tasks: [task], adopted: nil, timezone: timezone).first)
    #expect(reminder.fireAt == ISO8601DateFormatter().date(from: "2026-09-20T21:00:00-04:00"))
    task.dueTime = "22:00"
    task.updatedAt = "2026-09-18T08:01:00-04:00"
    let moved = try #require(RuntimeTaskReminder.build(tasks: [task], adopted: nil, timezone: timezone).first)
    #expect(moved.identifier == reminder.identifier)
    #expect(moved.revision != reminder.revision)
    #expect(moved.fireAt.timeIntervalSince(reminder.fireAt) == 3600)
    task.status = "done"
    #expect(RuntimeTaskReminder.build(tasks: [task], adopted: nil, timezone: timezone).isEmpty)
}

@Test func missedItemsDoNotBlockFreshAdoptionAndEditedBlocksStopDisplaying() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try DurableTaskRuntime(store: TaskStateStore(directoryURL: directory))
    _ = try await runtime.process(RuntimeTurnRequest(requestID: "capture", message: "tasks",
        now: "2026-09-18T08:00:00-04:00", timezone: "America/New_York", actions: [
            RuntimeAction(type: "capture", task: "Missed appointment", raw: "Missed appointment yesterday at 3pm",
                when: RuntimeDateIntent(kind: "absolute", year: 2026, month: 9, dayNumber: 17), time: "15:00"),
            RuntimeAction(type: "capture", task: "Write letter", raw: "Write letter")]))
    let tasks = await runtime.snapshot().tasks
    let letter = try #require(tasks.first { $0.task == "Write letter" })
    let proposal = try await runtime.proposeSchedule(RuntimeScheduleRequest(proposalID: "plan",
        generatedAt: "2026-09-18T08:00:00-04:00", startDate: "2026-09-18", timezone: "America/New_York",
        includedUntimedTaskIDs: [letter.id]))
    #expect(proposal.blocks.count == 1)
    let adopted = try await runtime.adoptSchedule(proposalID: proposal.id, at: "2026-09-18T08:01:00-04:00")
    _ = try await runtime.process(RuntimeTurnRequest(requestID: "edit", message: "change time",
        now: "2026-09-18T08:02:00-04:00", timezone: "America/New_York", actions: [
            RuntimeAction(type: "reschedule", target: letter.id, when: RuntimeDateIntent(kind: "today"), time: "16:00")]))
    let updated = await runtime.snapshot().tasks
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let today = try #require(ISO8601DateFormatter().date(from: "2026-09-18T08:03:00-04:00"))
    let digest = RuntimeMorningDigestBuilder.build(for: today, tasks: updated, proposal: proposal, timezone: zone)
    #expect(digest.items.first { $0.taskID == letter.id }?.time == "4:00 PM")
    let reminders = RuntimeTaskReminder.build(tasks: updated, adopted: adopted, timezone: zone)
    #expect(reminders.first { $0.taskID == letter.id }?.proposalID == "reminder")
}
