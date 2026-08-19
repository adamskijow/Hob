// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore
@testable import HobCloudSync

@MainActor
struct ICloudTaskSyncStoreTests {
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

    private func operation(
        id: String,
        taskID: String,
        minute: Int
    ) -> RuntimeTaskOperation {
        let timestamp = String(format: "2026-08-19T02:%02d:00Z", minute)
        return RuntimeTaskOperation(
            id: id,
            taskID: taskID,
            occurredAt: timestamp,
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
    var dictionaryRepresentation: [String: Any] { values }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func synchronize() -> Bool { true }
}
