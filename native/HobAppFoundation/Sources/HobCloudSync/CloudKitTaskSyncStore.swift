// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import CloudKit
import CryptoKit
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
public final class CloudKitTaskSyncStore: RuntimeTaskSyncing {
    private enum Schema {
        static let recordType = "HobTaskOperation"
        static let payload = "payload"
        static let version = "version"
        static let maximumPayloadBytes = 100_000
    }

    private let container: CKContainer
    private let database: CKDatabase
    public private(set) var availability: RuntimeTaskSyncAvailability = .unavailable

    public init(container: CKContainer = .default()) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    public func refreshAvailability() async -> RuntimeTaskSyncAvailability {
        do {
            switch try await container.accountStatus() {
            case .available: availability = .available
            case .noAccount: availability = .noAccount
            case .restricted: availability = .restricted
            case .couldNotDetermine, .temporarilyUnavailable:
                availability = .unavailable
            @unknown default:
                availability = .unavailable
            }
        } catch {
            availability = .unavailable
        }
        return availability
    }

    public func exchange(
        localOperations: [RuntimeTaskOperation]
    ) async throws -> [RuntimeTaskOperation] {
        guard availability == .available else {
            throw RuntimeTaskSyncError.accountUnavailable
        }
        do {
            let remote = try await fetchAll()
            let merged = try RuntimeTaskOperationMerge.merge(
                local: localOperations,
                remote: remote
            )
            let remoteIDs = Set(remote.map(\.id))
            let missing = localOperations.filter { !remoteIDs.contains($0.id) }
            try await upload(missing)
            return merged
        } catch let error as RuntimeTaskSyncError {
            throw error
        } catch {
            throw RuntimeTaskSyncError.transportFailed
        }
    }

    private func fetchAll() async throws -> [RuntimeTaskOperation] {
        let query = CKQuery(
            recordType: Schema.recordType,
            predicate: NSPredicate(value: true)
        )
        var page = try await database.records(
            matching: query,
            desiredKeys: [Schema.payload, Schema.version],
            resultsLimit: 400
        )
        var operations = try decode(page.matchResults)
        while let cursor = page.queryCursor {
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: [Schema.payload, Schema.version],
                resultsLimit: 400
            )
            operations += try decode(page.matchResults)
            guard operations.count <= 50_000 else {
                throw RuntimeTaskSyncError.invalidRemoteData
            }
        }
        return try RuntimeTaskOperationMerge.merge(local: operations, remote: [])
    }

    private func decode(
        _ results: [(CKRecord.ID, Result<CKRecord, any Error>)]
    ) throws -> [RuntimeTaskOperation] {
        try results.map { _, result in
            let record: CKRecord
            do { record = try result.get() }
            catch { throw RuntimeTaskSyncError.transportFailed }
            guard let version = record[Schema.version] as? Int64,
                  version == 1,
                  let payload = record[Schema.payload] as? Data,
                  payload.count <= Schema.maximumPayloadBytes,
                  let operation = try? JSONDecoder().decode(
                      RuntimeTaskOperation.self,
                      from: payload
                  ),
                  operation.isValid,
                  record.recordID.recordName == recordName(for: operation.id)
            else { throw RuntimeTaskSyncError.invalidRemoteData }
            return operation
        }
    }

    private func upload(_ operations: [RuntimeTaskOperation]) async throws {
        for start in stride(from: 0, to: operations.count, by: 200) {
            let end = min(start + 200, operations.count)
            let records = try operations[start..<end].map(record)
            let results = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
            for result in results.saveResults.values {
                do { _ = try result.get() }
                catch { throw RuntimeTaskSyncError.transportFailed }
            }
        }
    }

    private func record(_ operation: RuntimeTaskOperation) throws -> CKRecord {
        let payload = try JSONEncoder().encode(operation)
        guard operation.isValid,
              payload.count <= Schema.maximumPayloadBytes else {
            throw RuntimeTaskSyncError.invalidRemoteData
        }
        let record = CKRecord(
            recordType: Schema.recordType,
            recordID: CKRecord.ID(recordName: recordName(for: operation.id))
        )
        record[Schema.version] = Int64(1) as CKRecordValue
        record[Schema.payload] = payload as CKRecordValue
        return record
    }

    private func recordName(for operationID: String) -> String {
        SHA256.hash(data: Data(operationID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
