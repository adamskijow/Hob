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

public enum TaskStorageCondition: String, Codable, Equatable, Sendable {
    case new
    case ready
    case recoveryAvailable
    case upgradeRequired
    case unavailable

    public var title: String {
        switch self {
        case .new: return "Ready for first task"
        case .ready: return "Healthy"
        case .recoveryAvailable: return "Recovery available"
        case .upgradeRequired: return "Hob update required"
        case .unavailable: return "Needs attention"
        }
    }

    public var guidance: String {
        switch self {
        case .new:
            return "Local task storage is ready. Nothing has been saved yet."
        case .ready:
            return "Hob can safely read its local task and delivery state."
        case .recoveryAvailable:
            return "The current state cannot be read, but a verified previous copy can be restored."
        case .upgradeRequired:
            return "This task state was created by a newer Hob. Update the app before continuing."
        case .unavailable:
            return "Hob cannot safely read task storage. No data was changed."
        }
    }
}

public struct TaskStorageInspection: Equatable, Sendable {
    public let condition: TaskStorageCondition
    public let pipeline: RuntimePipelineStatus
    public let backupAvailable: Bool

    public init(
        condition: TaskStorageCondition,
        pipeline: RuntimePipelineStatus,
        backupAvailable: Bool
    ) {
        self.condition = condition
        self.pipeline = pipeline
        self.backupAvailable = backupAvailable
    }

    public static let unavailable = TaskStorageInspection(
        condition: .unavailable,
        pipeline: RuntimePersistentState.empty.pipelineStatus,
        backupAvailable: false
    )
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

    public func inspect() -> TaskStorageInspection {
        let primaryExists = fileManager.fileExists(atPath: stateURL.path)
        do {
            let state = try load()
            return TaskStorageInspection(
                condition: primaryExists ? .ready : .new,
                pipeline: state.pipelineStatus,
                backupAvailable: validBackupExists()
            )
        } catch TaskStateStoreError.unsupportedVersion {
            return TaskStorageInspection(
                condition: .upgradeRequired,
                pipeline: RuntimePersistentState.empty.pipelineStatus,
                backupAvailable: false
            )
        } catch TaskStateStoreError.invalidData,
                TaskStateStoreError.tooLarge {
            let backupAvailable = validBackupExists()
            return TaskStorageInspection(
                condition: backupAvailable ? .recoveryAvailable : .unavailable,
                pipeline: RuntimePersistentState.empty.pipelineStatus,
                backupAvailable: backupAvailable
            )
        } catch {
            return .unavailable
        }
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

    private func validBackupExists() -> Bool {
        guard fileManager.fileExists(atPath: backupURL.path) else { return false }
        return (try? load(from: backupURL, missing: .backupUnavailable)) != nil
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

public enum RuntimePipelineError: Error, Equatable, Sendable {
    case invalidEnvelope
    case idempotencyConflict
    case missingPendingRecord
    case missingOutboundRecord
    case alreadyQuarantined
    case queueFull

    public var userMessage: String {
        switch self {
        case .idempotencyConflict:
            return "Hob received conflicting copies of the same message. No changes were made."
        case .alreadyQuarantined:
            return "This message is already held for review. No changes were made."
        case .queueFull:
            return "Hob's local delivery queue is full. No new message was accepted."
        case .invalidEnvelope, .missingPendingRecord, .missingOutboundRecord:
            return "Hob could not safely process this message. No changes were made."
        }
    }
}

public actor DurableTaskRuntime {
    private let store: TaskStateStore
    private var runtime: TaskRuntime
    private var state: RuntimePersistentState

    public init(store: TaskStateStore) throws {
        self.store = store
        let loaded = try store.load()
        state = loaded
        runtime = try TaskRuntime(persistentState: loaded)
    }

    public func process(_ request: RuntimeTurnRequest) throws -> RuntimeTurnResponse {
        try receive(request)
    }

    public func receive(_ request: RuntimeTurnRequest) throws -> RuntimeTurnResponse {
        if let existing = state.inbox.first(where: {
            $0.request.requestID == request.requestID
        }) {
            guard existing.request == request else {
                throw RuntimePipelineError.idempotencyConflict
            }
            switch existing.status {
            case .completed:
                guard let outbound = state.outbox.first(where: {
                    $0.requestID == request.requestID
                }) else {
                    throw RuntimePipelineError.missingOutboundRecord
                }
                return response(for: outbound)
            case .pending:
                return try completePending(requestID: request.requestID)
            case .quarantined:
                throw RuntimePipelineError.alreadyQuarantined
            }
        }

        guard state.inbox.count < 10_000, state.outbox.count < 10_000 else {
            throw RuntimePipelineError.queueFull
        }
        guard requestIsValid(request) else {
            throw RuntimePipelineError.invalidEnvelope
        }
        let sequence = state.nextSequence
        var inbox = state.inbox
        inbox.append(RuntimeInboundRecord(
            sequence: sequence,
            request: request,
            receivedAt: request.now,
            status: .pending,
            updatedAt: request.now
        ))
        let unvalidatedReceipt = combinedState(
            runtimeState: runtime.persistentState,
            inbox: inbox,
            outbox: state.outbox,
            nextSequence: sequence + 1
        )
        guard let receiptState = try? unvalidatedReceipt.validated() else {
            throw RuntimePipelineError.invalidEnvelope
        }
        try store.save(receiptState)
        state = receiptState
        return try completePending(requestID: request.requestID)
    }

    @discardableResult
    public func replayPending() throws -> Int {
        let pending = state.inbox
            .filter { $0.status == .pending }
            .sorted { $0.sequence < $1.sequence }
        var replayed = 0
        for record in pending {
            _ = try completePending(requestID: record.request.requestID)
            replayed += 1
        }
        return replayed
    }

    public func pendingDeliveries(limit: Int = 100) -> [RuntimeOutboundRecord] {
        guard limit > 0 else { return [] }
        return Array(state.outbox
            .filter { $0.status == .pending }
            .sorted { $0.sequence < $1.sequence }
            .prefix(min(limit, 100)))
    }

    public func markDelivered(dedupeKey: String, at timestamp: String) throws {
        guard ISO8601DateFormatter().date(from: timestamp) != nil else {
            throw RuntimePipelineError.invalidEnvelope
        }
        guard let index = state.outbox.firstIndex(where: {
            $0.dedupeKey == dedupeKey
        }) else {
            throw RuntimePipelineError.missingOutboundRecord
        }
        let current = state.outbox[index]
        guard current.status == .pending else { return }
        var outbox = state.outbox
        outbox[index] = RuntimeOutboundRecord(
            sequence: current.sequence,
            requestID: current.requestID,
            dedupeKey: current.dedupeKey,
            createdAt: current.createdAt,
            status: .delivered,
            deliveredAt: timestamp,
            attempts: current.attempts,
            lastFailureCode: current.lastFailureCode,
            summary: current.summary
        )
        try commit(runtime: runtime, inbox: state.inbox, outbox: outbox)
    }

    public func recordDeliveryFailure(
        dedupeKey: String,
        code: String
    ) throws {
        guard validFailureCode(code) else {
            throw RuntimePipelineError.invalidEnvelope
        }
        guard let index = state.outbox.firstIndex(where: {
            $0.dedupeKey == dedupeKey
        }) else {
            throw RuntimePipelineError.missingOutboundRecord
        }
        let current = state.outbox[index]
        guard current.status == .pending else { return }
        guard current.attempts < 1_000 else {
            throw RuntimePipelineError.queueFull
        }
        var outbox = state.outbox
        outbox[index] = RuntimeOutboundRecord(
            sequence: current.sequence,
            requestID: current.requestID,
            dedupeKey: current.dedupeKey,
            createdAt: current.createdAt,
            status: current.status,
            attempts: current.attempts + 1,
            lastFailureCode: code,
            summary: current.summary
        )
        try commit(runtime: runtime, inbox: state.inbox, outbox: outbox)
    }

    public func quarantinePending(
        requestID: String,
        code: String,
        at timestamp: String
    ) throws {
        guard validFailureCode(code),
              ISO8601DateFormatter().date(from: timestamp) != nil else {
            throw RuntimePipelineError.invalidEnvelope
        }
        guard let index = state.inbox.firstIndex(where: {
            $0.request.requestID == requestID && $0.status == .pending
        }) else {
            throw RuntimePipelineError.missingPendingRecord
        }
        let current = state.inbox[index]
        var inbox = state.inbox
        inbox[index] = RuntimeInboundRecord(
            sequence: current.sequence,
            request: current.request,
            receivedAt: current.receivedAt,
            status: .quarantined,
            updatedAt: timestamp,
            failureCode: code
        )
        try commit(runtime: runtime, inbox: inbox, outbox: state.outbox)
    }

    public func snapshot() -> RuntimePersistentState {
        state
    }

    public func pipelineStatus() -> RuntimePipelineStatus {
        state.pipelineStatus
    }

    @discardableResult
    public func recoverFromBackup() throws -> RuntimePersistentState {
        let recovered = try store.recoverFromBackup()
        runtime = try TaskRuntime(persistentState: recovered)
        state = recovered
        return recovered
    }

    private func completePending(requestID: String) throws -> RuntimeTurnResponse {
        guard let inboundIndex = state.inbox.firstIndex(where: {
            $0.request.requestID == requestID && $0.status == .pending
        }) else {
            throw RuntimePipelineError.missingPendingRecord
        }
        let inbound = state.inbox[inboundIndex]
        var candidate = runtime
        let before = runtime.tasks
        let response = candidate.process(inbound.request)
        let summary = RuntimeDeliverySummary(
            disposition: response.outcome.disposition,
            appliedKinds: response.outcome.appliedKinds,
            affectedTaskIDs: affectedTaskIDs(before: before, after: candidate.tasks)
        )
        var inbox = state.inbox
        inbox[inboundIndex] = RuntimeInboundRecord(
            sequence: inbound.sequence,
            request: inbound.request,
            receivedAt: inbound.receivedAt,
            status: .completed,
            updatedAt: inbound.request.now
        )
        var outbox = state.outbox
        outbox.append(RuntimeOutboundRecord(
            sequence: inbound.sequence,
            requestID: inbound.request.requestID,
            dedupeKey: "turn:\(inbound.request.requestID)",
            createdAt: inbound.request.now,
            status: .pending,
            summary: summary
        ))
        try commit(runtime: candidate, inbox: inbox, outbox: outbox)
        return response
    }

    private func commit(
        runtime candidate: TaskRuntime,
        inbox: [RuntimeInboundRecord],
        outbox: [RuntimeOutboundRecord]
    ) throws {
        let candidateState = combinedState(
            runtimeState: candidate.persistentState,
            inbox: inbox,
            outbox: outbox,
            nextSequence: state.nextSequence
        )
        try store.save(candidateState)
        runtime = candidate
        state = candidateState
    }

    private func combinedState(
        runtimeState: RuntimePersistentState,
        inbox: [RuntimeInboundRecord],
        outbox: [RuntimeOutboundRecord],
        nextSequence: Int
    ) -> RuntimePersistentState {
        RuntimePersistentState(
            tasks: runtimeState.tasks,
            undoSnapshots: runtimeState.undoSnapshots,
            inbox: inbox,
            outbox: outbox,
            nextSequence: nextSequence
        )
    }

    private func response(for outbound: RuntimeOutboundRecord) -> RuntimeTurnResponse {
        RuntimeTurnResponse(
            version: 1,
            requestID: outbound.requestID,
            outcome: RuntimeTurnOutcome(
                disposition: outbound.summary.disposition,
                appliedKinds: outbound.summary.appliedKinds,
                tasks: runtime.tasks
            )
        )
    }

    private func affectedTaskIDs(
        before: [RuntimeTask],
        after: [RuntimeTask]
    ) -> [String] {
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        return Set(beforeByID.keys).union(afterByID.keys)
            .filter { beforeByID[$0] != afterByID[$0] }
            .sorted()
    }

    private func requestIsValid(_ request: RuntimeTurnRequest) -> Bool {
        let id = request.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        return request.version == 1
            && !id.isEmpty
            && id == request.requestID
            && id.utf8.count <= 128
            && request.message.utf8.count <= 20_000
            && request.now.utf8.count <= 64
            && ISO8601DateFormatter().date(from: request.now) != nil
            && request.timezone.utf8.count <= 64
            && TimeZone(identifier: request.timezone) != nil
            && !request.actions.isEmpty
            && request.actions.count <= 32
    }

    private func validFailureCode(_ code: String) -> Bool {
        !code.isEmpty
            && code.utf8.count <= 64
            && code.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }
    }
}
