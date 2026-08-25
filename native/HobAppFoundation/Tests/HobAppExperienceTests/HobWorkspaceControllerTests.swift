// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage
@testable import HobAppExperience

private struct StubInterpreter: RuntimeMessageInterpreting {
    let actions: [RuntimeAction]
    var error: RuntimeInterpretationError?

    init(
        actions: [RuntimeAction],
        error: RuntimeInterpretationError? = nil
    ) {
        self.actions = actions
        self.error = error
    }

    func interpret(
        message: String,
        now: String,
        timezone: String,
        tasks: [RuntimeTask]
    ) async throws -> [RuntimeAction] {
        if let error { throw error }
        return actions
    }
}

@MainActor
private final class StubCalendar: RuntimeCalendarScheduling {
    var authorization: RuntimeCalendarAuthorization = .fullAccess
    var writtenEventIDs: [String] = []
    var removedEventIDs: [String] = []
    var writeCount = 0
    var writtenCalendarID: String?
    var busyRequestCount = 0
    var requestedCalendarIDs: Set<String>?
    var requestedBlockAllDayEvents = false
    var excludedProposalID: String?
    var availableCalendars = [
        RuntimeCalendarDescriptor(
            id: "personal",
            title: "Personal",
            sourceTitle: "iCloud",
            allowsContentModifications: true,
            isSubscribed: false
        ),
        RuntimeCalendarDescriptor(
            id: "family",
            title: "Family",
            sourceTitle: "Subscribed",
            allowsContentModifications: false,
            isSubscribed: true
        ),
    ]

    func requestAccess() async throws -> RuntimeCalendarAuthorization {
        authorization
    }

    func calendars() throws -> [RuntimeCalendarDescriptor] {
        availableCalendars
    }

    func busyIntervals(
        from start: Date,
        to end: Date,
        timezone: TimeZone,
        calendarIDs: Set<String>?,
        blockAllDayEvents: Bool,
        excludingProposalID: String?
    ) throws -> [RuntimeBusyInterval] {
        busyRequestCount += 1
        requestedCalendarIDs = calendarIDs
        requestedBlockAllDayEvents = blockAllDayEvents
        self.excludedProposalID = excludingProposalID
        return [RuntimeBusyInterval(
            startAt: "2026-06-29T09:00:00-04:00",
            endAt: "2026-06-29T10:00:00-04:00"
        )]
    }

    func write(
        _ proposal: RuntimeScheduleProposal,
        calendarID: String?
    ) throws -> [String] {
        writeCount += 1
        writtenCalendarID = calendarID
        writtenEventIDs = proposal.blocks.map { "event-\($0.id)" }
        return writtenEventIDs
    }

    func createHobCalendar() throws -> RuntimeCalendarDescriptor {
        let calendar = RuntimeCalendarDescriptor(
            id: "hob",
            title: "Hob",
            sourceTitle: "iCloud",
            allowsContentModifications: true,
            isSubscribed: false
        )
        if !availableCalendars.contains(calendar) {
            availableCalendars.append(calendar)
        }
        return calendar
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
    var eveningRecaps: [RuntimeMorningDigest] = []
    var eveningTime: String?
    var eveningCancellations = 0
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

    func replaceEveningRecaps(
        _ digests: [RuntimeMorningDigest],
        time: String,
        now: Date
    ) async throws {
        eveningRecaps = digests
        eveningTime = time
    }

    func cancelEveningRecaps() async {
        eveningCancellations += 1
        eveningRecaps = []
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

@Test
func setupReviewCanAlwaysCloseWithoutWeakeningFirstRun() {
    #expect(HobFirstRunView.canFinish(
        reviewingExistingSetup: true,
        modelReadiness: .unavailable,
        isWorking: true
    ))
    #expect(!HobFirstRunView.canFinish(
        reviewingExistingSetup: false,
        modelReadiness: .unavailable,
        isWorking: false
    ))
    #expect(HobFirstRunView.canFinish(
        reviewingExistingSetup: false,
        modelReadiness: .available,
        isWorking: false
    ))
}

@Test @MainActor
func captureStaysUntimedUntilUserPlansAndAdoptsIt() async throws {
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
    defaults.set(true, forKey: "hob.calendar.integration.enabled")
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

    #expect(controller.draft.isEmpty)
    #expect(controller.tasks.map(\.task) == ["finish taxes", "call Mom"])
    #expect(controller.proposal?.blocks.isEmpty == true)
    #expect(controller.hasUnplannedOnDeckTasks)
    #expect(controller.notice == "Captured 2 tasks.")
    #expect(controller.adoptedSchedule == nil)
    #expect(controller.morningDigest?.items.map(\.task) == ["finish taxes"])
    #expect(notifications.morningTime == "07:00")
    #expect(notifications.morningDigests.count == 7)

    controller.planOnDeckWork()
    try await waitUntilIdle(controller)

    #expect(controller.proposal?.blocks.count == 2)
    #expect(controller.proposal?.blocks.first?.startAt == "2026-06-29T10:00:00-04:00")
    #expect(controller.proposal?.plannedUntimedTaskIDs.count == 2)
    #expect(!controller.hasUnplannedOnDeckTasks)

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
    #expect(controller.proposal?.blocks.isEmpty == true)
    #expect(controller.hasUnplannedOnDeckTasks)
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

@Test @MainActor
func failedInterpretationKeepsDraftForRetry() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-draft-retry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(
            actions: [],
            error: .invalidOutput
        ),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        timezone: try #require(TimeZone(identifier: "America/New_York"))
    )
    try await waitUntilSettled(controller)

    let message = "Tomorrow meet Claude at 230, then the department at 330"
    controller.draft = message
    controller.submit()
    try await waitUntilIdle(controller)

    #expect(controller.draft == message)
    #expect(controller.errorMessage == "I could not safely interpret that message. Nothing changed.")
}

@Test @MainActor
func calendarIntegrationDefaultsOffAndSchedulesStayUsable() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-calendar-off-\(UUID().uuidString)")
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
                raw: "Finish taxes today",
                when: RuntimeDateIntent(kind: "today"),
                durationMinutes: 30
            ),
        ]),
        calendarStore: calendar,
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        defaults: try #require(UserDefaults(
            suiteName: "hob-calendar-off-tests-\(UUID().uuidString)"
        )),
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )

    controller.draft = "Finish taxes today"
    controller.submit()
    try await waitUntilIdle(controller)
    #expect(!controller.calendarIntegrationEnabled)
    #expect(calendar.busyRequestCount == 0)

    controller.planOnDeckWork()
    try await waitUntilIdle(controller)
    controller.adoptProposal()
    try await waitUntilIdle(controller)
    #expect(calendar.writeCount == 0)
    #expect(controller.adoptedSchedule?.calendarEventIDs == [])
}

@Test @MainActor
func dailyCheckInsAreIndependentAndSupportEveryHour() async throws {
    #expect(HobWorkspaceController.validMorningDigestTimes.count == 24)
    #expect(HobWorkspaceController.validMorningDigestTimes.first == "00:00")
    #expect(HobWorkspaceController.validMorningDigestTimes.last == "23:00")
    #expect(HobWorkspaceController.morningDigestTimeLabel("00:00") == "12:00 AM")
    #expect(HobWorkspaceController.morningDigestTimeLabel("23:00") == "11:00 PM")

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-digest-hour-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "hob-digest-hour-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("23:00", forKey: "hob.morning.digest.time")
    let notifications = StubNotifications()
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: []),
        calendarStore: StubCalendar(),
        notificationStore: notifications,
        syncStore: StubSync(),
        defaults: defaults,
        timezone: try #require(TimeZone(identifier: "America/New_York"))
    )

    #expect(controller.morningDigestTime == "23:00")
    controller.setMorningDigestTime("00:00")
    #expect(controller.morningDigestTime == "00:00")
    #expect(defaults.string(forKey: "hob.morning.digest.time") == "00:00")

    #expect(!controller.eveningRecapEnabled)
    #expect(controller.eveningRecapTime == "20:00")
    controller.setEveningRecapTime("23:00")
    controller.setEveningRecapEnabled(true)
    try await Task.sleep(for: .milliseconds(50))

    #expect(controller.eveningRecapEnabled)
    #expect(controller.eveningRecapTime == "23:00")
    #expect(notifications.eveningTime == "23:00")
    #expect(notifications.eveningRecaps.count == 7)
    #expect(defaults.bool(forKey: "hob.evening.recap.enabled"))
    #expect(defaults.string(forKey: "hob.evening.recap.time") == "23:00")

    controller.setEveningRecapEnabled(false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(notifications.eveningRecaps.isEmpty)
}

@Test @MainActor
func calendarChoicesControlPlanningAndPersistPerDevice() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-calendar-choices-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(
        suiteName: "hob-calendar-choices-tests-\(UUID().uuidString)"
    ))
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
                raw: "Finish taxes today",
                when: RuntimeDateIntent(kind: "today"),
                durationMinutes: 30
            ),
        ]),
        calendarStore: calendar,
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        defaults: defaults,
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )
    try await Task.sleep(for: .milliseconds(30))

    #expect(!controller.calendarIntegrationEnabled)
    #expect(controller.usesAllInputCalendars)
    #expect(controller.calendars.isEmpty)

    controller.setCalendarIntegrationEnabled(true)
    try await waitUntilIdle(controller)
    #expect(controller.calendarIntegrationEnabled)
    #expect(controller.calendars.map(\.id) == ["personal", "family"])

    controller.setUsesAllInputCalendars(false)
    controller.setInputCalendar("family", included: false)
    controller.setBlockAllDayEvents(true)
    controller.createHobCalendar()
    try await waitUntilIdle(controller)
    #expect(controller.outputCalendarID == "hob")
    controller.setOutputCalendar("personal")

    controller.draft = "Finish taxes today"
    controller.submit()
    try await waitUntilIdle(controller)

    #expect(calendar.requestedCalendarIDs == ["personal"])
    #expect(calendar.requestedBlockAllDayEvents)
    #expect(calendar.excludedProposalID == nil)

    controller.adoptProposal()
    try await waitUntilIdle(controller)
    #expect(calendar.writtenCalendarID == "personal")

    let restored = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: []),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        defaults: defaults,
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )
    try await Task.sleep(for: .milliseconds(30))
    #expect(restored.calendarIntegrationEnabled)
    #expect(restored.inputCalendarIDs == ["personal"])
    #expect(restored.outputCalendarID == "personal")
    #expect(restored.blockAllDayEvents)
}

@Test @MainActor
func planningQuestionShowsReadOnlyAnswerWithoutWritingState() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-analysis-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let task = RuntimeTask(
        id: "task-1", rawText: "finish report", task: "finish report",
        dueDate: nil, dueTime: nil, durationMinutes: 60,
        priority: "high", status: "open",
        createdAt: "2026-08-25T08:00:00-04:00",
        updatedAt: "2026-08-25T08:00:00-04:00"
    )
    try store.save(RuntimePersistentState(tasks: [task], undoSnapshots: []))
    let before = try store.load()
    let now = try #require(ISO8601DateFormatter().date(
        from: "2026-08-25T09:00:00-04:00"
    ))
    let controller = HobWorkspaceController(
        store: store,
        interpreter: StubInterpreter(actions: [RuntimeAction(
            type: "analysis", analysisKind: "capacity", horizonDays: 7
        )]),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        defaults: try #require(UserDefaults(
            suiteName: "hob-analysis-tests-\(UUID().uuidString)"
        )),
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )
    try await Task.sleep(for: .milliseconds(30))

    controller.draft = "Will this week fit?"
    controller.submit()
    try await waitUntilIdle(controller)

    #expect(controller.draft.isEmpty)
    #expect(controller.planningAnalysis?.headline == "Everything fits.")
    #expect(controller.planningAnalysis?.kind == "capacity")
    #expect(controller.tasks == [task])
    #expect(try store.load() == before)
}

@Test @MainActor
func farFutureDateRequiresShortConfirmationBeforeWriting() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-far-date-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(ISO8601DateFormatter().date(
        from: "2026-08-25T09:00:00-04:00"
    ))
    let controller = HobWorkspaceController(
        store: TaskStateStore(directoryURL: directory),
        interpreter: StubInterpreter(actions: [RuntimeAction(
            type: "capture",
            task: "buy bananas",
            raw: "buy bananas in 10 years",
            when: RuntimeDateIntent(kind: "offset", n: 10, unit: "year")
        )]),
        calendarStore: StubCalendar(),
        notificationStore: StubNotifications(),
        syncStore: StubSync(),
        defaults: try #require(UserDefaults(
            suiteName: "hob-far-date-tests-\(UUID().uuidString)"
        )),
        timezone: try #require(TimeZone(identifier: "America/New_York")),
        now: { now }
    )
    try await Task.sleep(for: .milliseconds(30))

    controller.draft = "buy bananas in 10 years"
    controller.submit()
    try await waitUntilIdle(controller)

    #expect(controller.tasks.isEmpty)
    #expect(controller.draft == "buy bananas in 10 years")
    #expect(controller.longRangeConfirmation == "Are you sure it’s 10 years away?")

    controller.confirmLongRangeSubmission()
    try await waitUntilIdle(controller)
    #expect(controller.longRangeConfirmation == nil)
    #expect(controller.draft.isEmpty)
    #expect(controller.tasks.first?.dueDate == "2036-08-25")
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
