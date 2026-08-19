// SPDX-License-Identifier: MIT
import Foundation

public enum SharedStorageError: Error, Equatable, Sendable {
    case containerUnavailable
    case createFailed
}

public struct SharedStorage: Sendable {
    private let resolveContainer: @Sendable () -> URL?
    private let createDirectory: @Sendable (URL) throws -> Void

    public init(
        resolveContainer: @escaping @Sendable () -> URL?,
        createDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.resolveContainer = resolveContainer
        self.createDirectory = createDirectory
    }

    public static let system = SharedStorage(
        resolveContainer: {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        },
        createDirectory: { url in
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    )

    public func applicationSupportDirectory(create: Bool = true) throws -> URL {
        guard let container = resolveContainer() else {
            throw SharedStorageError.containerUnavailable
        }
        let directory = container.appendingPathComponent("Hob", isDirectory: true)
        if create {
            do {
                try createDirectory(directory)
            } catch {
                throw SharedStorageError.createFailed
            }
        }
        return directory
    }

    public func databaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("hob.db")
    }

    public func agentHealthURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("agent-health.json")
    }

    public func taskStateDirectory() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent(
            "Runtime",
            isDirectory: true
        )
    }
}
