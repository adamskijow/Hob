// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif

@MainActor
public protocol ICloudKeyValueStoring: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func set(_ value: Any?, forKey defaultName: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: ICloudKeyValueStoring {}

@MainActor
public final class ICloudTaskSyncStore: RuntimeTaskSyncing {
    private enum Schema {
        static let keyPrefix = "hob.task-operations.v1."
        static let deviceIDKey = "hob.icloud.device-id.v1"
        static let maximumShardBytes = 400_000
        static let maximumTotalBytes = 900_000
        static let maximumShards = 16
    }

    private let store: any ICloudKeyValueStoring
    private let signedIn: () -> Bool
    private let deviceID: String
    public private(set) var availability: RuntimeTaskSyncAvailability = .unavailable

    public convenience init() {
        let defaults = UserDefaults.standard
        let deviceID: String
        if let saved = defaults.string(forKey: Schema.deviceIDKey),
           UUID(uuidString: saved) != nil {
            deviceID = saved.lowercased()
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: Schema.deviceIDKey)
        }
        self.init(
            store: NSUbiquitousKeyValueStore.default,
            signedIn: { FileManager.default.ubiquityIdentityToken != nil },
            deviceID: deviceID
        )
    }

    public init(
        store: any ICloudKeyValueStoring,
        signedIn: @escaping () -> Bool,
        deviceID: String
    ) {
        self.store = store
        self.signedIn = signedIn
        self.deviceID = deviceID.lowercased()
    }

    public func refreshAvailability() async -> RuntimeTaskSyncAvailability {
        availability = signedIn() ? .available : .noAccount
        return availability
    }

    public func exchange(
        localOperations: [RuntimeTaskOperation]
    ) async throws -> [RuntimeTaskOperation] {
        guard availability == .available else {
            throw RuntimeTaskSyncError.accountUnavailable
        }
        guard UUID(uuidString: deviceID) != nil else {
            throw RuntimeTaskSyncError.invalidRemoteData
        }

        let remote = try decodeRemoteShards()
        let merged = try RuntimeTaskOperationMerge.merge(
            local: localOperations,
            remote: remote
        )
        let payload = try JSONEncoder().encode(merged)
        guard payload.count <= Schema.maximumShardBytes else {
            throw RuntimeTaskSyncError.transportFailed
        }
        store.set(payload, forKey: Schema.keyPrefix + deviceID)
        guard store.synchronize() else {
            throw RuntimeTaskSyncError.transportFailed
        }
        return merged
    }

    private func decodeRemoteShards() throws -> [RuntimeTaskOperation] {
        let shards = store.dictionaryRepresentation.filter {
            $0.key.hasPrefix(Schema.keyPrefix)
        }
        guard shards.count <= Schema.maximumShards else {
            throw RuntimeTaskSyncError.invalidRemoteData
        }
        var totalBytes = 0
        var operations: [RuntimeTaskOperation] = []
        for (key, value) in shards.sorted(by: { $0.key < $1.key }) {
            let suffix = String(key.dropFirst(Schema.keyPrefix.count))
            guard UUID(uuidString: suffix) != nil,
                  let payload = value as? Data,
                  payload.count <= Schema.maximumShardBytes else {
                throw RuntimeTaskSyncError.invalidRemoteData
            }
            totalBytes += payload.count
            guard totalBytes <= Schema.maximumTotalBytes,
                  let decoded = try? JSONDecoder().decode(
                    [RuntimeTaskOperation].self,
                    from: payload
                  ),
                  decoded.allSatisfy(\.isValid) else {
                throw RuntimeTaskSyncError.invalidRemoteData
            }
            operations += decoded
        }
        return try RuntimeTaskOperationMerge.merge(local: operations, remote: [])
    }
}
