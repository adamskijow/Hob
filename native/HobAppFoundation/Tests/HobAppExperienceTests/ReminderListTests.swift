// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage
@testable import HobAppExperience

@Test func reminderListSeparatesFutureFromTodayAndHistory() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-09T08:00:00-04:00"))
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    func task(_ id: String, _ date: String?, _ time: String? = nil) -> RuntimeTask {
        MessageBenchmarkCorpus.task(id, id, date: date, time: time)
    }
    var done = task("done", "2026-09-15"); done.status = "done"
    var dropped = task("removed", nil); dropped.status = "dropped"
    var paused = task("paused", nil); paused.waitingSince = "2026-09-08T08:00:00-04:00"
    var deadline = task("deadline", nil); deadline.deadlineDate = "2026-09-15"
    let tasks = [task("anytime", nil), task("overdue", "2026-09-08"), task("today", "2026-09-09", "09:00"),
                 task("missed", "2026-09-08", "09:00"), task("tomorrow", "2026-09-10"),
                 task("tomorrowTimed", "2026-09-10", "14:30"), task("friday", "2026-09-11"),
                 task("later", "2026-10-01"), done, dropped, paused, deadline]
    let list = RuntimeReminderList(tasks: tasks, now: now, timezone: zone)
    #expect(list.upcoming.map(\.title) == ["Tomorrow", "This week", "Later"])
    #expect(list.upcoming[0].tasks.map(\.id) == ["tomorrow", "tomorrowTimed"])
    #expect(list.upcoming[0].tasks[0].dueTime == nil)
    #expect(Set(list.history.map(\.id)) == ["done", "removed", "paused", "missed"])
    let today = RuntimeMorningDigestBuilder.build(for: now, tasks: tasks, proposal: nil, timezone: zone)
    #expect(Set(today.items.map(\.id)) == ["anytime", "overdue", "today", "deadline"])
    let all = today.items.map(\.id) + list.upcoming.flatMap(\.tasks).map(\.id) + list.history.map(\.id)
    #expect(Set(all) == Set(tasks.map(\.id)))
    #expect(all.count == tasks.count)
    let nextDay = now.addingTimeInterval(86400)
    #expect(!RuntimeReminderList(tasks: tasks, now: nextDay, timezone: zone).upcoming.flatMap(\.tasks).contains { $0.id == "tomorrow" })
    #expect(RuntimeMorningDigestBuilder.build(for: nextDay, tasks: tasks, proposal: nil, timezone: zone).items.contains { $0.id == "tomorrow" })
}

@Test func upcomingDatesRespectTimezoneDSTAndYearBoundaries() throws {
    for (instant, tomorrow, zoneName) in [
        ("2026-12-31T23:30:00-05:00", "2027-01-01", "America/New_York"),
        ("2026-03-07T23:30:00-05:00", "2026-03-08", "America/New_York"),
        ("2028-02-28T23:30:00+09:00", "2028-02-29", "Asia/Tokyo"),
        ("2026-09-12T23:30:00-04:00", "2026-09-13", "America/New_York"),
    ] {
        let now = try #require(ISO8601DateFormatter().date(from: instant))
        let zone = try #require(TimeZone(identifier: zoneName))
        let task = MessageBenchmarkCorpus.task("a1", "Future reminder", date: tomorrow)
        let list = RuntimeReminderList(tasks: [task], now: now, timezone: zone)
        #expect(list.upcoming.count == 1)
        #expect(list.upcoming.first?.title == "Tomorrow")
        #expect(list.upcoming.first?.tasks == [task])
    }
}

private struct UnusedReminderParser: RuntimeMessageInterpreting {
    func interpret(message: String, now: String, timezone: String, tasks: [RuntimeTask]) async throws -> [RuntimeAction] { [] }
}

@Test @MainActor func reminderEditorMovesClearsAndPersistsWithoutCalendarWrites() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-reminder-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "hob-reminder-edit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TaskStateStore(directoryURL: directory)
    let original = MessageBenchmarkCorpus.task("a1", "Book haircut", date: "2026-09-10", time: "14:00")
    try store.save(RuntimePersistentState(tasks: [original], undoSnapshots: []))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-09T08:00:00-04:00"))
    let calendar = StubCalendar()
    let controller = HobWorkspaceController(store: store, interpreter: UnusedReminderParser(), calendarStore: calendar,
        notificationStore: StubNotifications(), syncStore: StubSync(), defaults: defaults,
        timezone: TimeZone(identifier: "America/New_York")!, now: { now })
    await controller.refresh()
    func settle() async throws {
        for _ in 0..<500 {
            if !controller.isWorking { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Reminder edit did not finish")
    }
    controller.editReminder(taskID: "a1", title: "Book a haircut", date: "2026-09-11", time: nil)
    try await settle()
    #expect(controller.tasks.first?.task == "Book a haircut")
    #expect(controller.tasks.first?.dueDate == "2026-09-11")
    #expect(controller.tasks.first?.dueTime == nil)
    #expect(controller.reminderList.upcoming.first?.tasks.first?.id == "a1")
    controller.editReminder(taskID: "a1", title: "Book a haircut", date: nil, time: nil)
    try await settle()
    #expect(controller.reminderList.upcoming.isEmpty)
    #expect(controller.morningDigest?.items.first?.id == "a1")
    #expect(try store.load().tasks == controller.tasks)
    #expect(calendar.busyRequestCount == 0)
    controller.undoLastChange()
    try await settle()
    #expect(controller.tasks.first?.dueDate == "2026-09-11")
}

@Test @MainActor func reminderEditorCanKeepAnItemIndefinitelyAndRestoreCheckIns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-ongoing-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "hob-ongoing-edit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TaskStateStore(directoryURL: directory)
    let task = RuntimeTask(id: "a1", rawText: "Take my morning pill", task: "Take my morning pill",
        dueDate: nil, dueTime: nil, status: "open", createdAt: "2026-07-01T08:00:00-04:00",
        updatedAt: "2026-07-01T08:00:00-04:00")
    try store.save(RuntimePersistentState(tasks: [task], undoSnapshots: []))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-09T08:00:00-04:00"))
    let controller = HobWorkspaceController(store: store, interpreter: UnusedReminderParser(), calendarStore: StubCalendar(),
        notificationStore: StubNotifications(), syncStore: StubSync(), defaults: defaults,
        timezone: TimeZone(identifier: "America/New_York")!, now: { now })
    await controller.refresh()
    #expect(controller.morningDigest?.items.first?.isStale == true)

    controller.editReminder(taskID: "a1", title: task.task, date: nil, time: nil, keepIndefinitely: true)
    for _ in 0..<500 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.first?.reviewPolicy == "never")
    #expect(controller.morningDigest?.items.map(\.task) == ["Take my morning pill"])
    #expect(controller.morningDigest?.items.first?.isStale == false)
    #expect(try store.load().tasks.first?.reviewPolicy == "never")

    controller.editReminder(taskID: "a1", title: task.task, date: nil, time: nil, keepIndefinitely: false)
    for _ in 0..<500 where controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.first?.reviewPolicy == "standard")
    #expect(controller.morningDigest?.items.first?.isStale == false)
}

@Test @MainActor func closingTaskEditorSavesCombinedChangesWithoutResettingUnchangedTasks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-autosave-edit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "hob-autosave-edit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = TaskStateStore(directoryURL: directory)
    let task = RuntimeTask(id: "a1", rawText: "Take my morning pill", task: "Take my morning pill",
        dueDate: nil, dueTime: nil, status: "open", createdAt: "2026-07-01T08:00:00-04:00",
        updatedAt: "2026-07-01T08:00:00-04:00")
    try store.save(RuntimePersistentState(tasks: [task], undoSnapshots: []))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-09T08:00:00-04:00"))
    let controller = HobWorkspaceController(store: store, interpreter: UnusedReminderParser(), calendarStore: StubCalendar(),
        notificationStore: StubNotifications(), syncStore: StubSync(), defaults: defaults,
        timezone: TimeZone(identifier: "America/New_York")!, now: { now })
    await controller.refresh()

    controller.autosaveReminder(original: task, title: task.task, date: nil, time: nil,
        keepIndefinitely: false, note: "")
    #expect(try store.load().tasks.first?.revision == task.revision)

    controller.autosaveReminder(original: task, title: "Take my morning medication",
        date: "2026-09-10", time: "08:00", keepIndefinitely: true, note: "With breakfast")
    for _ in 0..<500 {
        if controller.tasks.first?.reviewPolicy == "never" && !controller.isWorking { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let saved = try #require(store.load().tasks.first)
    #expect(saved.task == "Take my morning medication")
    #expect(saved.dueDate == "2026-09-10")
    #expect(saved.dueTime == "08:00")
    #expect(saved.note == "With breakfast")
    #expect(saved.reviewPolicy == "never")
    #expect(controller.morningDigest?.items.isEmpty == true)
}
