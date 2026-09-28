// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore
@testable import HobCloudSync

@MainActor
struct ICloudTaskSyncStoreTests {
    @Test func historyCompactsBeforeTransportLimitAndPreservesDeletion() async throws {
        let cloud = MemoryICloudStore()
        let sync = ICloudTaskSyncStore(store: cloud, signedIn: { true }, deviceID: UUID().uuidString)
        _ = await sync.refreshAvailability()
        let history = (0..<1500).map { operation(id: "edit-\($0)", taskID: "one", minute: 1, sequence: $0) }
        #expect(try await sync.exchange(localOperations: history).count == 1)
        let deletion = RuntimeTaskOperation(id: "delete", taskID: "one", occurredAt: "2026-08-19T02:02:00Z", task: nil)
        #expect(try await sync.exchange(localOperations: [deletion]) == [deletion])
        #expect(try await sync.exchange(localOperations: [history[0]]) == [deletion])
    }

    @Test func timestampOrderingUsesInstantsNotOffsetText() throws {
        let old = RuntimeTaskOperation(id: "old", taskID: "one", occurredAt: "2026-09-18T12:00:00+02:00", task: nil)
        let new = RuntimeTaskOperation(id: "new", taskID: "one", occurredAt: "2026-09-18T07:00:00-04:00", task: nil)
        #expect(try RuntimeTaskOperationMerge.compacted([new, old]) == [new])
    }

    @Test func versionElevenMigrationRepairsOffsetWinnerWithoutLosingTheTask() throws {
        let created = "2026-09-18T08:00:00Z"
        let old = RuntimeTask(id: "a1", rawText: "Old", task: "Old", dueDate: nil, dueTime: nil,
            status: "open", createdAt: created, updatedAt: "2026-09-18T12:00:00+02:00")
        var new = old
        new.task = "New"
        new.updatedAt = "2026-09-18T07:00:00-04:00"
        let operations = [old, new].enumerated().map { index, task in
            RuntimeTaskOperation(id: "edit-\(index)", taskID: task.id, occurredAt: task.updatedAt, task: task)
        }
        let state = RuntimePersistentState(version: 11, tasks: [old], undoSnapshots: [[old]], taskOperations: operations)
        let migrated = try state.validated()
        #expect(migrated.tasks == [new])
        #expect(migrated.taskOperations == [operations[1]])
        #expect(migrated.undoSnapshots.isEmpty)
    }
    @Test func requiresAnICloudAccount() async {
        let sync = ICloudTaskSyncStore(
            store: MemoryICloudStore(),
            signedIn: { false },
            deviceID: UUID().uuidString
        )

        #expect(await sync.refreshAvailability() == .noAccount)
        await #expect(throws: RuntimeTaskSyncError.accountUnavailable) {
            _ = try await sync.exchange(localOperations: [])
        }
    }

    @Test func distinctDevicesConvergeWithoutOverwritingEachOther() async throws {
        let cloud = MemoryICloudStore()
        let first = ICloudTaskSyncStore(
            store: cloud,
            signedIn: { true },
            deviceID: UUID().uuidString
        )
        let second = ICloudTaskSyncStore(
            store: cloud,
            signedIn: { true },
            deviceID: UUID().uuidString
        )
        _ = await first.refreshAvailability()
        _ = await second.refreshAvailability()

        let one = operation(id: "one", taskID: "task-one", minute: 1)
        let two = operation(id: "two", taskID: "task-two", minute: 2)
        #expect(try await first.exchange(localOperations: [one]) == [one])
        #expect(try await second.exchange(localOperations: [two]) == [one, two])
        #expect(try await first.exchange(localOperations: [one]) == [one, two])
        #expect(cloud.values.count == 2)
    }

    @Test func rejectsUnreadableRemoteShard() async {
        let cloud = MemoryICloudStore()
        cloud.values["hob.task-operations.v1.\(UUID().uuidString.lowercased())"] = Data("bad".utf8)
        let sync = ICloudTaskSyncStore(
            store: cloud,
            signedIn: { true },
            deviceID: UUID().uuidString
        )
        _ = await sync.refreshAvailability()

        await #expect(throws: RuntimeTaskSyncError.invalidRemoteData) {
            _ = try await sync.exchange(localOperations: [])
        }
    }

    @Test func queuedWriteDoesNotBecomeAFalseTransportFailure() async throws {
        let cloud = MemoryICloudStore()
        cloud.synchronizeResult = false
        let sync = ICloudTaskSyncStore(
            store: cloud,
            signedIn: { true },
            deviceID: UUID().uuidString
        )
        _ = await sync.refreshAvailability()
        let value = operation(id: "one", taskID: "task-one", minute: 1)

        #expect(try await sync.exchange(localOperations: [value]) == [value])
        #expect(cloud.values.count == 1)
    }

    @Test func independentlyCreatedRecurrenceRepairsConverge() throws {
        let first = operation(
            id: "migration-v10-recurrence-task-one",
            taskID: "task-one",
            minute: 1,
            sequence: 4
        )
        let second = operation(
            id: "migration-v10-recurrence-task-one",
            taskID: "task-one",
            minute: 1,
            sequence: 7
        )

        #expect(try RuntimeTaskOperationMerge.merge(
            local: [first], remote: [second]
        ) == [second])
    }

    @Test func independentlyCreatedBaselinesConvergeToLatestTask() throws {
        let first = operation(
            id: "baseline-task-one",
            taskID: "task-one",
            minute: 1
        )
        let second = operation(
            id: "baseline-task-one",
            taskID: "task-one",
            minute: 2
        )

        #expect(try RuntimeTaskOperationMerge.merge(
            local: [first], remote: [second]
        ) == [second])
        #expect(try RuntimeTaskOperationMerge.merge(
            local: [second], remote: [first]
        ) == [second])
    }

    private func operation(
        id: String,
        taskID: String,
        minute: Int,
        sequence: Int = 0
    ) -> RuntimeTaskOperation {
        let timestamp = String(format: "2026-08-19T02:%02d:00Z", minute)
        return RuntimeTaskOperation(
            id: id,
            taskID: taskID,
            occurredAt: timestamp,
            sequence: sequence,
            task: RuntimeTask(
                id: taskID,
                rawText: taskID,
                task: taskID,
                dueDate: nil,
                dueTime: nil,
                status: "open",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
    }
}

@MainActor
private final class MemoryICloudStore: ICloudKeyValueStoring {
    var values: [String: Any] = [:]
    var synchronizeResult = true
    var dictionaryRepresentation: [String: Any] { values }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func synchronize() -> Bool { synchronizeResult }
}
