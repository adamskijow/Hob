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

@MainActor
private final class StubNotifications: RuntimeNotificationScheduling {
    var authorization: RuntimeNotificationAuthorization = .authorized
    var scheduledIDs: [String] = []
    var cancelledIDs: [String] = []
    var snoozed: [(RuntimeNotificationResponse, Int)] = []
    private var handler: (@MainActor @Sendable (
        RuntimeNotificationResponse
    ) async -> Void)?

    func refreshAuthorization() async -> RuntimeNotificationAuthorization {
        authorization
    }

    func requestAccess() async throws -> RuntimeNotificationAuthorization {
        authorization
    }

    func schedule(
        proposal: RuntimeScheduleProposal,
        now: Date
    ) async throws -> [String] {
        scheduledIDs = proposal.blocks.map { "notification-\($0.id)" }
        return scheduledIDs
    }

    func snooze(
        response: RuntimeNotificationResponse,
        minutes: Int
    ) async throws {
        snoozed.append((response, minutes))
    }

    func cancel(notificationIDs: [String]) {
        cancelledIDs += notificationIDs
    }

    func setActionHandler(
        _ handler: @escaping @MainActor @Sendable (
            RuntimeNotificationResponse
        ) async -> Void
    ) {
        self.handler = handler
    }

    func send(_ response: RuntimeNotificationResponse) async {
        await handler?(response)
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
    let notifications = StubNotifications()
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
        notificationStore: notifications,
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
    #expect(controller.adoptedSchedule?.notificationIDs == notifications.scheduledIDs)
    let reopened = try TaskStateStore(directoryURL: directory).load()
    #expect(reopened.adoptedSchedule?.proposal.blocks.count == 2)
    #expect(reopened.adoptedSchedule?.notificationIDs == notifications.scheduledIDs)

    let firstBlock = try #require(controller.adoptedSchedule?.proposal.blocks.first)
    let adoptedProposalID = try #require(controller.adoptedSchedule?.proposal.id)
    await notifications.send(notificationResponse(
        id: "replan-action",
        action: .replan,
        block: firstBlock,
        proposalID: adoptedProposalID,
        notificationID: try #require(notifications.scheduledIDs.first)
    ))
    try await waitUntilSettled(controller)
    #expect(controller.draft == "I need to replan finish taxes because ")
    #expect(controller.tasks.first?.status == "open")

    await notifications.send(notificationResponse(
        id: "snooze-action",
        action: .snooze,
        block: firstBlock,
        proposalID: adoptedProposalID,
        notificationID: try #require(notifications.scheduledIDs.first)
    ))
    try await waitUntilSettled(controller)
    #expect(notifications.snoozed.count == 1)
    #expect(notifications.snoozed.first?.1 == 15)
    #expect(controller.tasks.first?.status == "open")

    await notifications.send(notificationResponse(
        id: "done-action",
        action: .done,
        block: firstBlock,
        proposalID: adoptedProposalID,
        notificationID: try #require(notifications.scheduledIDs.first)
    ))
    try await waitUntilSettled(controller)
    #expect(controller.tasks.first?.status == "done")
    #expect(controller.adoptedSchedule == nil)
    #expect(controller.proposal?.blocks.map(\.task) == ["call Mom"])
    #expect(Set(notifications.cancelledIDs) == Set(notifications.scheduledIDs))
    #expect(Set(calendar.removedEventIDs) == Set(calendar.writtenEventIDs))

    let afterActions = try TaskStateStore(directoryURL: directory).load()
    #expect(afterActions.pendingNotificationResponses.isEmpty)
    #expect(afterActions.notificationCleanupIDs.isEmpty)
}

private func notificationResponse(
    id: String,
    action: RuntimeNotificationAction,
    block: RuntimeScheduleBlock,
    proposalID: String,
    notificationID: String
) -> RuntimeNotificationResponse {
    RuntimeNotificationResponse(
        id: id,
        action: action,
        notificationID: notificationID,
        proposalID: proposalID,
        blockID: block.id,
        taskID: block.taskID,
        task: block.task,
        receivedAt: "2026-06-29T08:05:00-04:00"
    )
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

@MainActor
private func waitUntilSettled(
    _ controller: HobWorkspaceController
) async throws {
    for _ in 0..<200 {
        if !controller.isWorking && !controller.notificationActionsPending {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Workspace notification action did not finish")
}
