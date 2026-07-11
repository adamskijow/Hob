// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

@Test func portableTaskRuntimeFixturesMatchNativeCore() throws {
    let data = try Data(contentsOf: fixtureURL())
    let fixture = try JSONDecoder().decode(RuntimeFixture.self, from: data)
    #expect(fixture.version == 1)

    for testCase in fixture.cases {
        var runtime = TaskRuntime(tasks: testCase.initialTasks)
        for (index, turn) in testCase.turns.enumerated() {
            let requestID = "\(testCase.name)-\(index)"
            let response = runtime.process(RuntimeTurnRequest(
                requestID: requestID,
                message: turn.message,
                now: testCase.now,
                timezone: testCase.timezone,
                actions: turn.actions
            ))
            let outcome = response.outcome
            #expect(response.version == 1)
            #expect(response.requestID == requestID)
            #expect(
                outcome.disposition == turn.expected.disposition,
                "\(testCase.name): wrong disposition"
            )
            #expect(
                outcome.appliedKinds == turn.expected.appliedKinds,
                "\(testCase.name): wrong applied actions"
            )
            #expect(
                outcome.tasks == turn.expected.tasks,
                "\(testCase.name): wrong task state"
            )
        }
    }
}

@Test func runtimeRejectsOversizedOrMixedUndoWithoutChangingTasks() {
    let task = RuntimeTask(
        id: "a1",
        rawText: "call mom",
        task: "call mom",
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "2026-06-29T09:00:00-04:00",
        updatedAt: "2026-06-29T09:00:00-04:00"
    )
    var runtime = TaskRuntime(tasks: [task])
    let mixed = runtime.process(RuntimeTurnRequest(
        requestID: "mixed-undo",
        message: "undo and finish it",
        now: "2026-06-29T09:00:00-04:00",
        timezone: "America/New_York",
        actions: [
            RuntimeAction(type: "undo"),
            RuntimeAction(type: "complete", target: "a1"),
        ]
    )).outcome
    #expect(mixed.disposition == .rejected)
    #expect(mixed.tasks == [task])

    let oversized = runtime.process(RuntimeTurnRequest(
        requestID: "oversized-task",
        message: "large task",
        now: "2026-06-29T09:00:00-04:00",
        timezone: "America/New_York",
        actions: [RuntimeAction(
            type: "capture",
            task: String(repeating: "x", count: 10_001),
            raw: "large"
        )]
    )).outcome
    #expect(oversized.disposition == .rejected)
    #expect(oversized.tasks == [task])
}

@Test func runtimeRejectsUnsupportedOrUncorrelatedRequests() {
    var runtime = TaskRuntime()
    let unsupported = runtime.process(RuntimeTurnRequest(
        version: 2,
        requestID: "future",
        message: "call mom",
        now: "2026-06-29T09:00:00-04:00",
        timezone: "America/New_York",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    ))
    #expect(unsupported.outcome.disposition == .rejected)
    #expect(unsupported.outcome.tasks.isEmpty)

    let uncorrelated = runtime.process(RuntimeTurnRequest(
        requestID: "",
        message: "call mom",
        now: "2026-06-29T09:00:00-04:00",
        timezone: "America/New_York",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    ))
    #expect(uncorrelated.outcome.disposition == .rejected)
    #expect(uncorrelated.outcome.tasks.isEmpty)

    let invalidClock = runtime.process(RuntimeTurnRequest(
        requestID: "bad-clock",
        message: "call mom",
        now: "not-a-time",
        timezone: "America/New_York",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    ))
    #expect(invalidClock.outcome.disposition == .rejected)
    #expect(invalidClock.outcome.tasks.isEmpty)
}

private struct RuntimeFixture: Decodable {
    let version: Int
    let cases: [RuntimeFixtureCase]
}

private struct RuntimeFixtureCase: Decodable {
    let name: String
    let now: String
    let timezone: String
    let initialTasks: [RuntimeTask]
    let turns: [RuntimeFixtureTurn]
}

private struct RuntimeFixtureTurn: Decodable {
    let message: String
    let actions: [RuntimeAction]
    let expected: RuntimeFixtureExpected
}

private struct RuntimeFixtureExpected: Decodable {
    let disposition: RuntimeDisposition
    let appliedKinds: [String]
    let tasks: [RuntimeTask]
}

private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/portable/task-runtime-v1.json")
}
