// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore
@testable import HobAppStorage

@Test func durableRuntimeSurvivesRestartAndPersistsUndo() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let first = try DurableTaskRuntime(store: store)

    _ = try await first.process(request(
        id: "capture-1",
        message: "Tomorrow buy bananas",
        actions: [RuntimeAction(
            type: "capture",
            task: "buy bananas",
            raw: "Tomorrow buy bananas",
            when: RuntimeDateIntent(kind: "tomorrow")
        )]
    ))
    _ = try await first.process(request(
        id: "capture-2",
        message: "call mom",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    ))

    let afterRestart = try DurableTaskRuntime(store: store)
    #expect(await afterRestart.snapshot().tasks.map(\.task) == ["buy bananas", "call mom"])
    _ = try await afterRestart.process(request(
        id: "undo-1",
        message: "undo",
        actions: [RuntimeAction(type: "undo")]
    ))

    let afterUndoRestart = try DurableTaskRuntime(store: store)
    #expect(await afterUndoRestart.snapshot().tasks.map(\.task) == ["buy bananas"])
    _ = try await afterUndoRestart.process(request(
        id: "undo-2",
        message: "undo",
        actions: [RuntimeAction(type: "undo")]
    ))
    #expect(await afterUndoRestart.snapshot().tasks.isEmpty)

    let finalRestart = try DurableTaskRuntime(store: store)
    #expect(await finalRestart.snapshot().tasks.isEmpty)
}

@Test func corruptPrimaryNeverSilentlyStartsEmptyAndBackupRecoveryIsExplicit() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let first = state(task: "first")
    let second = state(task: "second")
    try store.save(first)
    try store.save(second)
    try Data("not json".utf8).write(to: store.stateURL, options: [.atomic])

    #expect(throws: TaskStateStoreError.invalidData) {
        try store.load()
    }
    let recovered = try store.recoverFromBackup()
    #expect(recovered == first)
    #expect(try store.load() == first)
}

@Test func failedPersistenceCannotCommitOrAcknowledgeCandidateState() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let durable = try DurableTaskRuntime(store: store)
    try FileManager.default.createDirectory(
        at: store.stateURL,
        withIntermediateDirectories: true
    )

    await #expect(throws: (any Error).self) {
        _ = try await durable.process(request(
            id: "must-not-commit",
            message: "call mom",
            actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
        ))
    }
    #expect(await durable.snapshot().tasks.isEmpty)
}

@Test func storeRejectsFutureVersionSymlinkAndOversizedState() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let store = TaskStateStore(directoryURL: directory)
    let future = RuntimePersistentState(version: 2, tasks: [], undoSnapshots: [])
    try JSONEncoder().encode(future).write(to: store.stateURL)
    #expect(throws: TaskStateStoreError.unsupportedVersion) {
        try store.load()
    }

    try FileManager.default.removeItem(at: store.stateURL)
    let target = directory.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: store.stateURL,
        withDestinationURL: target
    )
    #expect(throws: TaskStateStoreError.unsafePath) {
        try store.load()
    }

    try FileManager.default.removeItem(at: store.stateURL)
    try Data(count: TaskStateStore.maximumBytes + 1).write(to: store.stateURL)
    #expect(throws: TaskStateStoreError.tooLarge) {
        try store.load()
    }

    let redirected = temporaryDirectory()
    let redirectTarget = temporaryDirectory()
    defer {
        try? FileManager.default.removeItem(at: redirected)
        try? FileManager.default.removeItem(at: redirectTarget)
    }
    try FileManager.default.createDirectory(
        at: redirected.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: redirectTarget,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: redirected,
        withDestinationURL: redirectTarget
    )
    let redirectedStore = TaskStateStore(directoryURL: redirected)
    #expect(throws: TaskStateStoreError.unsafePath) {
        try redirectedStore.save(.empty)
    }
}

@Test func persistentStateRejectsDuplicatesAndInvalidTimestamps() {
    let valid = state(task: "first").tasks[0]
    let duplicate = RuntimePersistentState(
        tasks: [valid, valid],
        undoSnapshots: []
    )
    #expect(throws: RuntimeStateError.invalidState) {
        try duplicate.validated()
    }

    let invalidTime = RuntimeTask(
        id: "a1",
        rawText: "first",
        task: "first",
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "not-a-time",
        updatedAt: "2026-06-29T09:00:00-04:00"
    )
    #expect(throws: RuntimeStateError.invalidState) {
        try RuntimePersistentState(tasks: [invalidTime], undoSnapshots: []).validated()
    }
}

@Test func stateFilesUsePrivatePermissionsAndErrorsDoNotLeakPaths() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    try store.save(.empty)
    let fileAttributes = try FileManager.default.attributesOfItem(
        atPath: store.stateURL.path
    )
    let directoryAttributes = try FileManager.default.attributesOfItem(
        atPath: directory.path
    )
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(!TaskStateStoreError.invalidData.userMessage.contains(directory.path))
}

private func request(
    id: String,
    message: String,
    actions: [RuntimeAction]
) -> RuntimeTurnRequest {
    RuntimeTurnRequest(
        requestID: id,
        message: message,
        now: "2026-06-29T09:00:00-04:00",
        timezone: "America/New_York",
        actions: actions
    )
}

private func state(task: String) -> RuntimePersistentState {
    RuntimePersistentState(
        tasks: [RuntimeTask(
            id: "a1",
            rawText: task,
            task: task,
            dueDate: nil,
            dueTime: nil,
            status: "open",
            createdAt: "2026-06-29T09:00:00-04:00",
            updatedAt: "2026-06-29T09:00:00-04:00"
        )],
        undoSnapshots: [[]]
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-state-tests-\(UUID().uuidString)", isDirectory: true)
}
