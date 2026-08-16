// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage
@testable import HobAppExperience

private struct StubInterpreter: RuntimeMessageInterpreting {
    let actions: [RuntimeAction]

    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction] {
        actions
    }
}

@MainActor
private final class StubCalendar: RuntimeCalendarScheduling {
    var authorization: RuntimeCalendarAuthorization = .fullAccess
    var writtenEventIDs: [String] = []
    var removedEventIDs: [String] = []

    func requestAccess() async throws -> RuntimeCalendarAuthorization {
        authorization
    }

    func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone
    ) throws -> [RuntimeBusyInterval] {
        [RuntimeBusyInterval(
            startAt: "2026-06-29T09:00:00-04:00",
            endAt: "2026-06-29T10:00:00-04:00"
        )]
    }

    func write(_ proposal: RuntimeScheduleProposal) throws -> [String] {
        writtenEventIDs = proposal.blocks.map { "event-\($0.id)" }
        return writtenEventIDs
    }

    func remove(eventIDs: [String]) throws {
        removedEventIDs += eventIDs
    }
}

@Test @MainActor
func naturalMessageBuildsAndAdoptsAPersistentSchedule() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-workspace-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(ISO8601DateFormatter().date(
        from: "2026-06-29T08:00:00-04:00"
    ))
    let calendar = StubCalendar()
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: [
            RuntimeAction(
                type: "capture",
                task: "finish taxes",
                raw: "Finish taxes by Friday, high priority, about 90 minutes",
                deadline: RuntimeDateIntent(kind: "weekday", which: "this", day: "fri"),
                durationMinutes: 90,
                priority: "high"
            ),
            RuntimeAction(
                type: "capture",
                task: "call Mom",
                raw: "Call Mom tomorrow for 15 minutes",
                when: RuntimeDateIntent(kind: "tomorrow"),
                durationMinutes: 15,
                priority: "normal"
            ),
        ]),
        calendarStore: calendar,
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )

    controller.draft = "Finish taxes by Friday, high priority, about 90 minutes. Call Mom tomorrow for 15 minutes."
    controller.submit()
    try await waitUntilIdle(controller)

    #expect(controller.tasks.map(\.task) == ["finish taxes", "call Mom"])
    #expect(controller.proposal?.blocks.count == 2)
    #expect(controller.proposal?.blocks.first?.startAt == "2026-06-29T10:00:00-04:00")
    #expect(controller.adoptedSchedule == nil)

    controller.adoptProposal()
    try await waitUntilIdle(controller)

    #expect(controller.adoptedSchedule?.proposal.blocks.count == 2)
    #expect(controller.adoptedSchedule?.calendarEventIDs == calendar.writtenEventIDs)
    let reopened = try TaskStateStore(directoryURL: directory).load()
    #expect(reopened.adoptedSchedule?.proposal.blocks.count == 2)
}

@MainActor
private func waitUntilIdle(
    _ controller: HobWorkspaceController
) async throws {
    for _ in 0..<200 {
        if !controller.isWorking { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Workspace operation did not finish")
}
