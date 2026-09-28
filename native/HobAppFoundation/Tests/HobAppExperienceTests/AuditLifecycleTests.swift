// SPDX-License-Identifier: MIT
import Foundation
import Synchronization
import Testing
import HobAppCore
import HobAppStorage
@testable import HobAppExperience

private struct AuditInterpreter: RuntimeMessageInterpreting {
    func interpret(message: String, now: String, timezone: String, tasks: [RuntimeTask]) async throws -> [RuntimeAction] { [] }
}

@Test @MainActor func sameSecondNotificationAndSnoozeLifecycleRegressions() async throws {
    let timestamp = "2026-09-18T08:00:00-04:00"
    let now = try #require(ISO8601DateFormatter().date(from: timestamp))
    for scenario in ["stale-done", "new-occurrence", "retry", "duplicate-snooze"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "hob-audit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let task = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: "2026-09-18", dueTime: "15:00",
            status: "open", createdAt: timestamp, updatedAt: timestamp)
        let store = TaskStateStore(directoryURL: directory)
        try store.save(RuntimePersistentState(tasks: [task], undoSnapshots: []))
        let notifications = StubNotifications()
        let controller = HobWorkspaceController(store: store, interpreter: AuditInterpreter(), calendarStore: StubCalendar(),
            notificationStore: notifications, syncStore: StubSync(availability: .noAccount), defaults: defaults,
            timezone: try #require(TimeZone(identifier: "America/New_York")), now: { now })
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(30))
            for _ in 0..<200 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!controller.isWorking)
        }
        func response(_ action: RuntimeNotificationAction, revision: String) -> RuntimeNotificationResponse {
            RuntimeNotificationResponse(id: UUID().uuidString, action: action,
                notificationID: "hob.reminder.a1", proposalID: "reminder", blockID: "a1", taskID: task.id,
                task: task.task, receivedAt: timestamp, taskRevision: revision)
        }
        try await settle()
        switch scenario {
        case "stale-done":
            controller.editReminder(taskID: task.id, title: task.task, date: task.dueDate, time: "16:00")
            try await settle()
            #expect(controller.tasks.first?.updatedAt == task.updatedAt)
            #expect(controller.tasks.first?.revision != task.revision)
            await notifications.send(response(.done, revision: task.revision))
            try await settle()
            #expect(controller.tasks.first?.status == "open")
            #expect(controller.notice == "That reminder is no longer current.")
        case "new-occurrence":
            for _ in 0..<5 {
                await notifications.send(response(.snooze, revision: task.revision))
                try await settle()
            }
            #expect(notifications.snoozed.map(\.1) == [15, 60, 240, 720])
            #expect(controller.notice?.contains("indefinitely") == true)
            controller.editReminder(taskID: task.id, title: task.task, date: "2026-09-19", time: task.dueTime)
            try await settle()
            let next = try #require(controller.tasks.first)
            await notifications.send(response(.snooze, revision: next.revision))
            try await settle()
            #expect(notifications.snoozed.map(\.1) == [15, 60, 240, 720, 15])
        case "duplicate-snooze":
            let duplicate = response(.snooze, revision: task.revision)
            await notifications.send(duplicate)
            try await settle()
            await notifications.send(duplicate)
            try await settle()
            #expect(notifications.snoozed.map(\.1) == [15])
        default:
            notifications.snoozeError = .schedulingFailed
            await notifications.send(response(.snooze, revision: task.revision))
            try await settle()
            #expect(try store.load().pendingNotificationResponses.count == 1)
            notifications.snoozeError = nil
            controller.processNotificationResponses()
            try await settle()
            #expect(notifications.snoozed.map(\.1) == [15, 15])
            #expect(try store.load().pendingNotificationResponses.isEmpty)
        }
    }
}

@Test @MainActor func offlineDayRolloverRefreshesTodayAndStaleNotificationCannotCompleteEditedTask() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let initial = try #require(ISO8601DateFormatter().date(from: "2026-09-18T23:59:00-04:00"))
    let clock = Mutex(initial)
    let task = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: "2026-09-19", dueTime: "15:00",
        status: "open", createdAt: "2026-09-18T08:00:00-04:00", updatedAt: "2026-09-18T09:00:00-04:00")
    let store = TaskStateStore(directoryURL: directory)
    try store.save(RuntimePersistentState(tasks: [task], undoSnapshots: []))
    let notifications = StubNotifications()
    let defaults = try #require(UserDefaults(suiteName: "hob-audit-\(UUID().uuidString)"))
    let controller = HobWorkspaceController(store: store, interpreter: AuditInterpreter(), calendarStore: StubCalendar(),
        notificationStore: notifications, syncStore: StubSync(availability: .noAccount), defaults: defaults,
        timezone: try #require(TimeZone(identifier: "America/New_York")), now: { clock.withLock { $0 } })
    await controller.refresh()
    #expect(controller.morningDigest?.items.isEmpty == true)
    #expect(notifications.taskReminders.map(\.taskID) == [task.id])
    try await Task.sleep(for: .milliseconds(100))
    clock.withLock { $0 = initial.addingTimeInterval(120) }
    controller.syncNow()
    for _ in 0..<200 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.morningDigest?.date == "2026-09-19")
    #expect(controller.morningDigest?.items.map(\.taskID) == [task.id])
    await notifications.send(RuntimeNotificationResponse(id: "stale-tap", action: .done,
        notificationID: "hob.reminder.a1", proposalID: "reminder", blockID: "a1", taskID: "a1", task: task.task,
        receivedAt: "2026-09-19T00:01:00-04:00", taskRevision: task.createdAt))
    for _ in 0..<200 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.first?.status == "open")
    await notifications.send(RuntimeNotificationResponse(id: "current-tap", action: .done,
        notificationID: "hob.reminder.a1", proposalID: "reminder", blockID: "a1", taskID: "a1", task: task.task,
        receivedAt: "2026-09-19T00:01:00-04:00", taskRevision: task.updatedAt))
    for _ in 0..<200 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.first?.status == "done")
    #expect(notifications.taskReminders.isEmpty)
}
