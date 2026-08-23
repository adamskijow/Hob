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
    var morningDigests: [RuntimeMorningDigest] = []
    var morningTime: String?
    var morningCancellations = 0
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

    func replaceMorningDigests(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws {
        morningDigests = digests
        morningTime = time
    }

    func cancelMorningDigests() async {
        morningCancellations += 1
        morningDigests = []
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

@MainActor
private final class StubSync: RuntimeTaskSyncing {
    var availability: RuntimeTaskSyncAvailability
    var remoteOperations: [RuntimeTaskOperation]

    init(
        availability: RuntimeTaskSyncAvailability = .unavailable,
        remoteOperations: [RuntimeTaskOperation] = []
    ) {
        self.availability = availability
        self.remoteOperations = remoteOperations
    }

    func refreshAvailability() async -> RuntimeTaskSyncAvailability {
        availability
    }

    func exchange(
        localOperations: [RuntimeTaskOperation]
    ) async throws -> [RuntimeTaskOperation] {
        let merged = try RuntimeTaskOperationMerge.merge(
            local: localOperations,
            remote: remoteOperations
        )
        remoteOperations = merged
        return merged
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
    let defaults = try #require(UserDefaults(
        suiteName: "hob-workspace-tests-\(UUID().uuidString)"
    ))
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
        syncStore: StubSync(),
        defaults: defaults,
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
    #expect(controller.morningDigest?.items.map(\.task) == ["finish taxes"])
    #expect(notifications.morningTime == "07:00")
    #expect(notifications.morningDigests.count == 7)

    controller.adoptProposal()
    try await waitUntilIdle(controller)

    #expect(controller.adoptedSchedule?.proposal.blocks.count == 2)
    #expect(controller.adoptedSchedule?.calendarEventIDs == calendar.writtenEventIDs)
    #expect(controller.adoptedSchedule?.notificationIDs == notifications.scheduledIDs)
    let reopened = try TaskStateStore(directoryURL: directory).load()
    #expect(reopened.adoptedSchedule?.proposal.blocks.count == 2)
    #expect(reopened.adoptedSchedule?.notificationIDs == notifications.scheduledIDs)

    let oldEventIDs = calendar.writtenEventIDs
    let oldNotificationIDs = notifications.scheduledIDs
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
    #expect(controller.adoptedSchedule?.proposal.blocks.count == 2)
    #expect(controller.proposal?.blocks.map(\.task) == ["call Mom"])
    #expect(controller.scheduleDiff?.changes.contains {
        $0.task == "finish taxes" && $0.kind == .removed
    } == true)
    #expect(notifications.cancelledIDs.isEmpty)
    #expect(calendar.removedEventIDs.isEmpty)

    controller.adoptProposal()
    try await waitUntilIdle(controller)
    #expect(controller.adoptedSchedule?.proposal.blocks.map(\.task) == ["call Mom"])
    #expect(Set(notifications.cancelledIDs) == Set(oldNotificationIDs))
    #expect(Set(calendar.removedEventIDs) == Set(oldEventIDs))

    let afterActions = try TaskStateStore(directoryURL: directory).load()
    #expect(afterActions.pendingNotificationResponses.isEmpty)
    #expect(afterActions.notificationCleanupIDs.isEmpty)
}

@Test @MainActor
func todayTaskCanBeMarkedDoneAndUndone() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-today-done-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(ISO8601DateFormatter().date(
        from: "2026-06-29T08:00:00-04:00"
    ))
    let defaults = try #require(UserDefaults(
        suiteName: "hob-today-done-tests-\(UUID().uuidString)"
    ))
    let notifications = StubNotifications()
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: [
            RuntimeAction(
                type: "capture",
                task: "get Willow haircut",
                raw: "Get Willow haircut today",
                when: RuntimeDateIntent(kind: "today"),
                durationMinutes: 30
            ),
        ]),
        calendarStore: StubCalendar(),
        notificationStore: notifications,
        syncStore: StubSync(),
        defaults: defaults,
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )

    controller.draft = "Get Willow haircut today"
    controller.submit()
    try await waitUntilIdle(controller)
    let taskID = try #require(controller.morningDigest?.items.first?.taskID)

    controller.renameTask(taskID: taskID, to: "Book Willow haircut")
    try await waitUntilIdle(controller)

    #expect(controller.tasks.first?.task == "Book Willow haircut")
    #expect(controller.morningDigest?.items.map(\.task) == ["Book Willow haircut"])
    #expect(controller.notice == "Updated: Book Willow haircut.")
    #expect(notifications.morningDigests.first?.items.map(\.task) == ["Book Willow haircut"])
    #expect(try TaskStateStore(directoryURL: directory).load().tasks.first?.task == "Book Willow haircut")

    controller.markDone(taskID: taskID)
    try await waitUntilIdle(controller)

    #expect(controller.tasks.first?.status == "done")
    #expect(controller.morningDigest?.items.isEmpty == true)
    #expect(controller.notice == "Done: Book Willow haircut.")
    #expect(notifications.morningDigests.allSatisfy { $0.items.isEmpty })
    #expect(try TaskStateStore(directoryURL: directory).load().tasks.first?.status == "done")

    controller.undoLastChange()
    try await waitUntilIdle(controller)

    #expect(controller.tasks.first?.status == "open")
    #expect(controller.morningDigest?.items.map(\.task) == ["Book Willow haircut"])
}

@Test @MainActor
func manualSyncPullsRemoteTasksAndBuildsAProposal() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-sync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(ISO8601DateFormatter().date(
        from: "2026-06-29T08:00:00-04:00"
    ))
    let timestamp = "2026-06-29T07:00:00-04:00"
    let task = RuntimeTask(
        id: "task-remote",
        rawText: "call Mom",
        task: "call Mom",
        dueDate: "2026-06-29",
        dueTime: nil,
        durationMinutes: 15,
        priority: "normal",
        status: "open",
        createdAt: timestamp,
        updatedAt: timestamp
    )
    let sync = StubSync(remoteOperations: [RuntimeTaskOperation(
        id: "remote-capture:task-remote",
        taskID: task.id,
        occurredAt: timestamp,
        task: task
    )])
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: []),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: sync,
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )
    try await Task.sleep(for: .milliseconds(20))
    try await waitUntilIdle(controller)

    sync.availability = .available
    controller.syncNow()
    try await waitUntilIdle(controller)

    #expect(controller.tasks == [task])
    #expect(controller.proposal?.blocks.map(\.task) == ["call Mom"])
    #expect(controller.syncNeedsAttention == false)
    #expect(controller.notice == "Tasks updated from iCloud.")
}

@Test @MainActor
func routineSyncIsSilentWhenNothingChanged() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-quiet-sync-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let sync = StubSync()
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: []),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: sync,
        timezone: try #require(TimeZone(identifier: "America/New_York"))
    )
    try await waitUntilSettled(controller)

    sync.availability = .available
    controller.syncNow()
    try await waitUntilIdle(controller)

    #expect(controller.notice == nil)
    #expect(controller.syncNeedsAttention == false)
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
