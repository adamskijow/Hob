// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore
import HobAppStorage
@testable import HobAppExperience

private struct JourneyParser: RuntimeMessageInterpreting {
    var asksQuestion = true
    func interpret(message: String, now: String, timezone: String, tasks: [RuntimeTask]) async throws -> [RuntimeAction] {
        if asksQuestion {
            throw RuntimeInterpretationError.question(.init(kind: .chooseDate, text: RuntimeInteraction.moveDateQuestion, taskIDs: ["a1"]))
        }
        return [.init(type: "capture", task: message, raw: message)]
    }
}

@Test @MainActor func syncRevisionReplacesPendingQuestionInsteadOfRetargeting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-sync-question-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let original = MessageBenchmarkCorpus.task("a1", "Plan picnic", stale: true)
    try store.save(RuntimePersistentState(tasks: [original], undoSnapshots: []))
    let sync = StubSync()
    let defaults = UserDefaults(suiteName: "hob-sync-question-\(UUID())")!
    let now = ISO8601DateFormatter().date(from: MessageBenchmarkCorpus.now)!
    let controller = HobWorkspaceController(store: store, interpreter: JourneyParser(), calendarStore: StubCalendar(),
        notificationStore: StubNotifications(), syncStore: sync, defaults: defaults,
        timezone: TimeZone(identifier: "America/New_York")!, now: { now })
    await controller.refresh()
    controller.draft = "Move"; controller.submit()
    while controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    let oldID = try #require(controller.conversationState.pending?.id)
    var changed = original; changed.task = "Plan reunion"; changed.updatedAt = "2026-09-07T08:01:00-04:00"
    sync.remoteOperations = [.init(id: "remote-edit", taskID: changed.id, occurredAt: changed.updatedAt, task: changed)]
    sync.availability = .available
    controller.syncNow()
    while controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.first?.task == "Plan reunion")
    #expect(controller.conversationState.pending?.id != oldID)
    #expect(controller.conversationState.pending?.kind == .chooseTask)
    #expect(controller.conversationState.pending?.text.contains("changed") == true)
    #expect(controller.tasks.first?.dueDate == nil)
    #expect(try store.load().tasks.first?.task == "Plan reunion")
}

@Test @MainActor func failedSaveNeverProducesASuccessfulConversationReply() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hob-failed-save-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    try store.save(RuntimePersistentState(tasks: [], undoSnapshots: []))
    let now = ISO8601DateFormatter().date(from: MessageBenchmarkCorpus.now)!
    let controller = HobWorkspaceController(store: store, interpreter: JourneyParser(asksQuestion: false),
        calendarStore: StubCalendar(), notificationStore: StubNotifications(), syncStore: StubSync(),
        defaults: UserDefaults(suiteName: "hob-failed-save-\(UUID())")!,
        timezone: TimeZone(identifier: "America/New_York")!, now: { now })
    await controller.refresh()
    try FileManager.default.removeItem(at: store.stateURL)
    try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
    controller.draft = "Buy envelopes"; controller.submit()
    while controller.isWorking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(controller.tasks.isEmpty)
    #expect(controller.conversationMessages.last?.isError == true)
    #expect(!controller.conversationMessages.contains { $0.text.hasPrefix("Added") })
    #expect(controller.conversationMessages.first?.text == "Buy envelopes")
}
