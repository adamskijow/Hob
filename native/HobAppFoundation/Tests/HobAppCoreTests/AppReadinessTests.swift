// SPDX-License-Identifier: MIT
import Testing
@testable import HobAppCore

@Test func appStoreEditionRequiresAppleModel() {
    let readiness = AppReadiness(
        edition: .appStore,
        modelBackend: .ollama,
        ownerPaired: true,
        backgroundServiceApproved: true,
        modelAvailable: true
    )

    #expect(readiness.blockers == [.unsupportedModelBackend])
    #expect(!readiness.canRun)
}

@Test func readinessNamesEveryUnfinishedOnboardingBoundary() {
    let readiness = AppReadiness(
        edition: .appStore,
        modelBackend: .appleFoundationModels,
        ownerPaired: false,
        backgroundServiceApproved: false,
        modelAvailable: false
    )

    #expect(readiness.blockers == [
        .modelUnavailable,
        .ownerNotPaired,
        .backgroundServiceNotApproved,
    ])
}

@Test func appStoreEditionCanRunOnlyAfterExplicitSetup() {
    let readiness = AppReadiness(
        edition: .appStore,
        modelBackend: .appleFoundationModels,
        ownerPaired: true,
        backgroundServiceApproved: true,
        modelAvailable: true
    )

    #expect(readiness.canRun)
}

@Test func unavailableTaskStorageBlocksReadiness() {
    let readiness = AppReadiness(
        edition: .appStore,
        modelBackend: .appleFoundationModels,
        ownerPaired: true,
        backgroundServiceApproved: true,
        modelAvailable: true,
        storageAvailable: false
    )

    #expect(readiness.blockers == [.taskStorageUnavailable])
    #expect(!readiness.canRun)
}
