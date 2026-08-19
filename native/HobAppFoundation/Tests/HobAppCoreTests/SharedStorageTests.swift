// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

@Test func sharedStorageUsesPrivateApplicationSupport() throws {
    let container = URL(fileURLWithPath: "/private/tmp/application-support", isDirectory: true)
    let storage = SharedStorage(
        resolveContainer: { container },
        createDirectory: { _ in }
    )

    #expect(try storage.databaseURL().path == "/private/tmp/application-support/Hob/hob.db")
    #expect(try storage.agentHealthURL().path == "/private/tmp/application-support/Hob/agent-health.json")
    #expect(try storage.taskStateDirectory().path == "/private/tmp/application-support/Hob/Runtime")
}

@Test func missingApplicationSupportFailsClosed() {
    let storage = SharedStorage(
        resolveContainer: { nil },
        createDirectory: { _ in }
    )

    #expect(throws: SharedStorageError.containerUnavailable) {
        try storage.databaseURL()
    }
}

@Test func directoryCreationFailureIsStableAndPrivacySafe() {
    struct FilesystemFailure: Error {}
    let storage = SharedStorage(
        resolveContainer: { URL(fileURLWithPath: "/private/private-task-path") },
        createDirectory: { _ in throw FilesystemFailure() }
    )

    #expect(throws: SharedStorageError.createFailed) {
        try storage.databaseURL()
    }
}

@Test func serviceStatesDoNotEquateRegistrationWithApproval() {
    #expect(!BackgroundServiceState.notRegistered.isApproved)
    #expect(!BackgroundServiceState.requiresApproval.isApproved)
    #expect(BackgroundServiceState.enabled.isApproved)
    #expect(BackgroundServiceState.requiresApproval.guidance.contains("System Settings"))
}

@Test func agentHealthCarriesNoUserContent() throws {
    let health = AgentHealth(state: "foundation", updatedAt: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder().encode(health)
    let encoded = try #require(String(data: data, encoding: .utf8))

    #expect(encoded.contains("foundation"))
    #expect(!encoded.contains("task"))
    #expect(!encoded.contains("message"))
}
