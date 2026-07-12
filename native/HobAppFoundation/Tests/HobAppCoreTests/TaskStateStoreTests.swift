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

@Test func failedCompletionWriteLeavesReceiptPendingWithoutTaskOrReply() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let turn = request(
        id: "completion-write-fails",
        message: "call mom",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    )
    try store.save(RuntimePersistentState(
        tasks: [],
        undoSnapshots: [],
        inbox: [pending(turn, sequence: 1)],
        nextSequence: 2
    ))
    let durable = try DurableTaskRuntime(store: store)
    try FileManager.default.removeItem(at: store.stateURL)
    try FileManager.default.createDirectory(
        at: store.stateURL,
        withIntermediateDirectories: true
    )

    await #expect(throws: (any Error).self) {
        _ = try await durable.replayPending()
    }
    let snapshot = await durable.snapshot()
    #expect(snapshot.tasks.isEmpty)
    #expect(snapshot.inbox.map(\.status) == [.pending])
    #expect(snapshot.outbox.isEmpty)
}

@Test func storeRejectsFutureVersionSymlinkAndOversizedState() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let store = TaskStateStore(directoryURL: directory)
    let future = RuntimePersistentState(version: 3, tasks: [], undoSnapshots: [])
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

@Test func pendingReceiptReplaysAfterRestartExactlyOnce() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let turn = request(
        id: "crash-replay",
        message: "call mom",
        actions: [RuntimeAction(type: "capture", task: "call mom", raw: "call mom")]
    )
    try store.save(RuntimePersistentState(
        tasks: [],
        undoSnapshots: [],
        inbox: [pending(turn, sequence: 1)],
        nextSequence: 2
    ))

    let restarted = try DurableTaskRuntime(store: store)
    #expect(try await restarted.replayPending() == 1)
    #expect(try await restarted.replayPending() == 0)
    _ = try await restarted.receive(turn)

    let snapshot = await restarted.snapshot()
    #expect(snapshot.tasks.map(\.task) == ["call mom"])
    #expect(snapshot.inbox.map(\.status) == [.completed])
    #expect(snapshot.outbox.count == 1)
    #expect(snapshot.outbox[0].summary.affectedTaskIDs == ["a1"])
}

@Test func duplicateDeliveryConflictsFailClosedWithoutAnotherMutation() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let durable = try DurableTaskRuntime(
        store: TaskStateStore(directoryURL: directory)
    )
    let original = request(
        id: "same-update",
        message: "buy milk",
        actions: [RuntimeAction(type: "capture", task: "buy milk", raw: "buy milk")]
    )
    _ = try await durable.receive(original)
    let conflict = request(
        id: "same-update",
        message: "buy eggs",
        actions: [RuntimeAction(type: "capture", task: "buy eggs", raw: "buy eggs")]
    )

    await #expect(throws: RuntimePipelineError.idempotencyConflict) {
        _ = try await durable.receive(conflict)
    }
    #expect(await durable.snapshot().tasks.map(\.task) == ["buy milk"])
    #expect(await durable.snapshot().outbox.count == 1)
}

@Test func replayPreservesInboundAndOutboundOrder() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let first = request(
        id: "ordered-1",
        message: "first",
        actions: [RuntimeAction(type: "capture", task: "first", raw: "first")]
    )
    let second = request(
        id: "ordered-2",
        message: "second",
        actions: [RuntimeAction(type: "capture", task: "second", raw: "second")]
    )
    try store.save(RuntimePersistentState(
        tasks: [],
        undoSnapshots: [],
        inbox: [pending(first, sequence: 1), pending(second, sequence: 2)],
        nextSequence: 3
    ))

    let durable = try DurableTaskRuntime(store: store)
    #expect(try await durable.replayPending() == 2)
    #expect(await durable.pendingDeliveries().map(\.requestID) == [
        "ordered-1", "ordered-2",
    ])
    #expect(await durable.snapshot().tasks.map(\.task) == ["first", "second"])
}

@Test func poisonReceiptCanBeQuarantinedWithoutBlockingLaterWork() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let poison = request(
        id: "poison",
        message: "poison",
        actions: [RuntimeAction(type: "capture", task: "poison", raw: "poison")]
    )
    let healthy = request(
        id: "healthy",
        message: "healthy",
        actions: [RuntimeAction(type: "capture", task: "healthy", raw: "healthy")]
    )
    try store.save(RuntimePersistentState(
        tasks: [],
        undoSnapshots: [],
        inbox: [pending(poison, sequence: 1), pending(healthy, sequence: 2)],
        nextSequence: 3
    ))

    let durable = try DurableTaskRuntime(store: store)
    try await durable.quarantinePending(
        requestID: "poison",
        code: "decode_failed",
        at: "2026-06-29T09:01:00-04:00"
    )
    #expect(try await durable.replayPending() == 1)
    let snapshot = await durable.snapshot()
    #expect(snapshot.tasks.map(\.task) == ["healthy"])
    #expect(snapshot.pipelineStatus.quarantinedInbound == 1)
    #expect(snapshot.pipelineStatus.pendingInbound == 0)
    #expect(snapshot.outbox.map(\.requestID) == ["healthy"])
}

@Test func outboundRetryAndDeliveryAreDurableAndIdempotent() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    let durable = try DurableTaskRuntime(store: store)
    _ = try await durable.receive(request(
        id: "delivery",
        message: "send this",
        actions: [RuntimeAction(type: "capture", task: "send this", raw: "send this")]
    ))
    try await durable.recordDeliveryFailure(
        dedupeKey: "turn:delivery",
        code: "telegram_timeout"
    )

    let restarted = try DurableTaskRuntime(store: store)
    #expect(await restarted.pendingDeliveries()[0].attempts == 1)
    try await restarted.markDelivered(
        dedupeKey: "turn:delivery",
        at: "2026-06-29T09:02:00-04:00"
    )
    try await restarted.markDelivered(
        dedupeKey: "turn:delivery",
        at: "2026-06-29T09:03:00-04:00"
    )

    let delivered = await restarted.snapshot().outbox[0]
    #expect(delivered.status == .delivered)
    #expect(delivered.deliveredAt == "2026-06-29T09:02:00-04:00")
    #expect(await restarted.pendingDeliveries().isEmpty)
    #expect(await restarted.pipelineStatus().failedDeliveryAttempts == 0)
}

@Test func versionOneStateMigratesAndFutureStateStillFailsClosed() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"version":1,"tasks":[],"undoSnapshots":[]}"#.utf8).write(
        to: store.stateURL
    )

    let migrated = try store.load()
    #expect(migrated.version == RuntimePersistentState.currentVersion)
    #expect(migrated.inbox.isEmpty)
    #expect(migrated.outbox.isEmpty)
    #expect(migrated.nextSequence == 1)
}

@Test func storageInspectionIsActionableAndStatusContainsNoUserContent() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    #expect(store.inspect().condition == .new)
    let durable = try DurableTaskRuntime(store: store)
    _ = try await durable.receive(request(
        id: "private-message-id",
        message: "private task words",
        actions: [RuntimeAction(
            type: "capture",
            task: "private task words",
            raw: "private task words"
        )]
    ))
    let inspection = store.inspect()
    #expect(inspection.condition == .ready)
    #expect(inspection.pipeline.pendingOutbound == 1)
    let statusData = try JSONEncoder().encode(inspection.pipeline)
    let statusText = try #require(String(data: statusData, encoding: .utf8))
    #expect(!statusText.contains("private"))
    #expect(!statusText.contains("message-id"))

    try store.save(await durable.snapshot())
    try Data("broken".utf8).write(to: store.stateURL, options: [.atomic])
    let recovery = store.inspect()
    #expect(recovery.condition == .recoveryAvailable)
    #expect(recovery.backupAvailable)
}

@Test func storageInspectionNeverOffersImpossibleSymlinkRecovery() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TaskStateStore(directoryURL: directory)
    try store.save(.empty)
    try store.save(.empty)
    try FileManager.default.removeItem(at: store.stateURL)
    let target = directory.appendingPathComponent("redirected.json")
    try Data("broken".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
        at: store.stateURL,
        withDestinationURL: target
    )

    let inspection = store.inspect()
    #expect(inspection.condition == .unavailable)
    #expect(!inspection.backupAvailable)
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

private func pending(
    _ request: RuntimeTurnRequest,
    sequence: Int
) -> RuntimeInboundRecord {
    RuntimeInboundRecord(
        sequence: sequence,
        request: request,
        receivedAt: request.now,
        status: .pending,
        updatedAt: request.now
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
