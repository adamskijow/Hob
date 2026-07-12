// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif

public enum TaskStateStoreError: Error, Equatable, Sendable {
    case createFailed
    case unsafePath
    case readFailed
    case tooLarge
    case invalidData
    case unsupportedVersion
    case writeFailed
    case backupUnavailable

    public var userMessage: String {
        switch self {
        case .backupUnavailable:
            return "No previous task-state backup is available. No data was changed."
        case .tooLarge:
            return "Hob's task data is unexpectedly large. No changes were made."
        case .unsupportedVersion:
            return "This task data needs a newer version of Hob. No changes were made."
        case .invalidData:
            return "Hob could not safely read its task data. No changes were made."
        case .createFailed, .unsafePath, .readFailed, .writeFailed:
            return "Hob could not safely access its task storage. No changes were made."
        }
    }
}

public struct TaskStateStore: Sendable {
    public static let maximumBytes = 10_000_000

    public let stateURL: URL
    public let backupURL: URL

    public init(directoryURL: URL) {
        stateURL = directoryURL.appendingPathComponent("task-state-v1.json")
        backupURL = directoryURL.appendingPathComponent("task-state-v1.previous.json")
    }

    private var fileManager: FileManager { .default }

    public func load() throws -> RuntimePersistentState {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return .empty
        }
        return try load(from: stateURL, missing: .readFailed)
    }

    public func save(_ state: RuntimePersistentState) throws {
        let validated = try validate(state)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(validated)
        } catch {
            throw TaskStateStoreError.invalidData
        }
        guard data.count <= Self.maximumBytes else {
            throw TaskStateStoreError.tooLarge
        }
        try prepareDirectory()
        try rejectSymlink(stateURL)
        try rejectSymlink(backupURL)

        if fileManager.fileExists(atPath: stateURL.path) {
            let previous = try readBounded(stateURL)
            _ = try decode(previous)
            try write(previous, to: backupURL)
        }
        try write(data, to: stateURL)
    }

    public func recoverFromBackup() throws -> RuntimePersistentState {
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw TaskStateStoreError.backupUnavailable
        }
        let recovered = try load(from: backupURL, missing: .backupUnavailable)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(recovered)
        } catch {
            throw TaskStateStoreError.invalidData
        }
        try prepareDirectory()
        try rejectSymlink(stateURL)
        try write(data, to: stateURL)
        return recovered
    }

    private func load(
        from url: URL,
        missing: TaskStateStoreError
    ) throws -> RuntimePersistentState {
        guard fileManager.fileExists(atPath: url.path) else { throw missing }
        try rejectSymlink(url)
        return try decode(readBounded(url))
    }

    private func readBounded(_ url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize, size <= Self.maximumBytes else {
                throw TaskStateStoreError.tooLarge
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as TaskStateStoreError {
            throw error
        } catch {
            throw TaskStateStoreError.readFailed
        }
    }

    private func decode(_ data: Data) throws -> RuntimePersistentState {
        guard data.count <= Self.maximumBytes else { throw TaskStateStoreError.tooLarge }
        let state: RuntimePersistentState
        do {
            state = try JSONDecoder().decode(RuntimePersistentState.self, from: data)
        } catch {
            throw TaskStateStoreError.invalidData
        }
        return try validate(state)
    }

    private func validate(
        _ state: RuntimePersistentState
    ) throws -> RuntimePersistentState {
        do {
            return try state.validated()
        } catch RuntimeStateError.unsupportedVersion {
            throw TaskStateStoreError.unsupportedVersion
        } catch {
            throw TaskStateStoreError.invalidData
        }
    }

    private func prepareDirectory() throws {
        do {
            let directory = stateURL.deletingLastPathComponent()
            try rejectSymlink(directory)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch let error as TaskStateStoreError {
            throw error
        } catch {
            throw TaskStateStoreError.createFailed
        }
    }

    private func rejectSymlink(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            throw TaskStateStoreError.unsafePath
        } catch TaskStateStoreError.unsafePath {
            throw TaskStateStoreError.unsafePath
        } catch {
            return
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw TaskStateStoreError.writeFailed
        }
    }
}

public actor DurableTaskRuntime {
    private let store: TaskStateStore
    private var runtime: TaskRuntime

    public init(store: TaskStateStore) throws {
        self.store = store
        runtime = try TaskRuntime(persistentState: store.load())
    }

    public func process(_ request: RuntimeTurnRequest) throws -> RuntimeTurnResponse {
        var candidate = runtime
        let response = candidate.process(request)
        if response.outcome.disposition == .applied {
            try store.save(candidate.persistentState)
            runtime = candidate
        }
        return response
    }

    public func snapshot() -> RuntimePersistentState {
        runtime.persistentState
    }

    @discardableResult
    public func recoverFromBackup() throws -> RuntimePersistentState {
        let recovered = try store.recoverFromBackup()
        runtime = try TaskRuntime(persistentState: recovered)
        return recovered
    }
}
