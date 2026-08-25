// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

private let parityNow = "2026-08-25T09:00:00-04:00"
private let parityZone = "America/New_York"

@Test func completionHistorySupportsNaturalHistoryQueries() throws {
    var runtime = TaskRuntime(tasks: [parityTask("a1", "File taxes")])
    let outcome = runtime.process(RuntimeTurnRequest(
        requestID: "complete-history",
        message: "I filed taxes",
        now: parityNow,
        timezone: parityZone,
        actions: [RuntimeAction(type: "complete", target: "a1")]
    )).outcome

    #expect(outcome.tasks[0].completionHistory == [parityNow])
    let answer = try RuntimeTaskQueryEngine.answer(
        action: RuntimeAction(type: "query", queryKind: "done", queryPeriod: "week"),
        tasks: outcome.tasks,
        now: ISO8601DateFormatter().date(from: parityNow)!,
        timezone: TimeZone(identifier: parityZone)!
    )
    #expect(answer.contains("File taxes"))
}

@Test func conversationalRevisionChangesAndClearsConstraintsAtomically() {
    var task = parityTask("a1", "File taxes")
    task.dueDate = "2026-08-28"
    task.deadlineDate = "2026-08-30"
    task.durationMinutes = 30
    task.priority = "normal"
    var runtime = TaskRuntime(tasks: [task])
    let outcome = runtime.process(RuntimeTurnRequest(
        requestID: "revise-fields",
        message: "Make it high priority, 90 minutes, and remove the deadline",
        now: parityNow,
        timezone: parityZone,
        actions: [RuntimeAction(
            type: "revise",
            target: "a1",
            durationMinutes: 90,
            priority: "high",
            clearFields: ["deadline"]
        )]
    )).outcome

    #expect(outcome.disposition == .applied)
    #expect(outcome.tasks[0].durationMinutes == 90)
    #expect(outcome.tasks[0].priority == "high")
    #expect(outcome.tasks[0].deadlineDate == nil)
    #expect(outcome.tasks[0].dueDate == "2026-08-28")
}

@Test func notesAndWaitingStatePersistWithoutEnteringThePlan() throws {
    var runtime = TaskRuntime(tasks: [parityTask("a1", "Call contractor")])
    let waiting = runtime.process(RuntimeTurnRequest(
        requestID: "wait-with-note",
        message: "Waiting on Lee; gate code is 4412",
        now: parityNow,
        timezone: parityZone,
        actions: [
            RuntimeAction(type: "note", target: "a1", note: "Gate code is 4412"),
            RuntimeAction(type: "wait", target: "a1"),
        ]
    )).outcome
    #expect(waiting.disposition == .applied)
    #expect(waiting.tasks[0].note == "Gate code is 4412")
    #expect(waiting.tasks[0].isWaiting)

    let digest = RuntimeMorningDigestBuilder.build(
        for: ISO8601DateFormatter().date(from: parityNow)!,
        tasks: waiting.tasks,
        proposal: nil,
        timezone: TimeZone(identifier: parityZone)!
    )
    #expect(digest.items.isEmpty)

    let query = try RuntimeTaskQueryEngine.answer(
        action: RuntimeAction(type: "query", queryKind: "waiting"),
        tasks: waiting.tasks,
        now: ISO8601DateFormatter().date(from: parityNow)!,
        timezone: TimeZone(identifier: parityZone)!
    )
    #expect(query.contains("Call contractor"))

    let resumed = runtime.process(RuntimeTurnRequest(
        requestID: "resume-waiting",
        message: "Lee replied",
        now: "2026-08-25T10:00:00-04:00",
        timezone: parityZone,
        actions: [RuntimeAction(type: "resume", target: "a1")]
    )).outcome
    #expect(resumed.tasks[0].isWaiting == false)
}

@Test func staleDigestExplainsWhyItIsAsking() {
    let task = RuntimeTask(
        id: "a1",
        rawText: "Old work",
        task: "Old work",
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "2026-08-10T09:00:00-04:00",
        updatedAt: "2026-08-10T09:00:00-04:00"
    )
    let digest = RuntimeMorningDigestBuilder.build(
        for: ISO8601DateFormatter().date(from: parityNow)!,
        tasks: [task],
        proposal: nil,
        timezone: TimeZone(identifier: parityZone)!
    )
    #expect(digest.items[0].daysOnDeck == 15)
    #expect(digest.notificationBody.contains("has been on deck 15 days"))
    #expect(digest.notificationBody.contains("Keep, move, or drop"))
}

@Test func snoozeIntervalsGrowAndEndIndefinitely() {
    #expect(RuntimeSnoozeSequence.step(after: 0).minutes == 15)
    #expect(RuntimeSnoozeSequence.step(after: 1).minutes == 60)
    #expect(RuntimeSnoozeSequence.step(after: 2).minutes == 240)
    #expect(RuntimeSnoozeSequence.step(after: 3).minutes == 720)
    #expect(RuntimeSnoozeSequence.step(after: 4).minutes == nil)
    #expect(RuntimeSnoozeSequence.step(after: 99).label == "indefinitely")
}

private func parityTask(_ id: String, _ title: String) -> RuntimeTask {
    RuntimeTask(
        id: id,
        rawText: title,
        task: title,
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "2026-08-24T09:00:00-04:00",
        updatedAt: "2026-08-24T09:00:00-04:00"
    )
}
