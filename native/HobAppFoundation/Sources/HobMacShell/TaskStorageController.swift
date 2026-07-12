// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppStorage)
import HobAppStorage
#endif

@MainActor
final class TaskStorageController: ObservableObject {
    @Published private(set) var inspection: TaskStorageInspection = .unavailable
    @Published private(set) var lastResult: String?

    private let storage: SharedStorage

    init(storage: SharedStorage = .system) {
        self.storage = storage
        refresh()
    }

    var canRecover: Bool {
        inspection.condition == .recoveryAvailable && inspection.backupAvailable
    }

    func refresh() {
        do {
            let directory = try storage.taskStateDirectory()
            inspection = TaskStateStore(directoryURL: directory).inspect()
        } catch {
            inspection = .unavailable
        }
    }

    func recoverPreviousCopy() {
        guard canRecover else { return }
        do {
            let directory = try storage.taskStateDirectory()
            _ = try TaskStateStore(directoryURL: directory).recoverFromBackup()
            lastResult = "The verified previous copy was restored. Review your tasks before turning on background delivery."
        } catch let error as TaskStateStoreError {
            lastResult = error.userMessage
        } catch {
            lastResult = TaskStateStoreError.readFailed.userMessage
        }
        refresh()
    }
}
