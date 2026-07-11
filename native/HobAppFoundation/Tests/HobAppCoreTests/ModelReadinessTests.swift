// SPDX-License-Identifier: MIT
import Testing
@testable import HobAppCore

@Test func onlyRealGenerationMakesTheModelReady() {
    for state in ModelReadinessState.allNonReadyStates {
        #expect(!state.isReady)
    }
    #expect(ModelReadinessState.available.isReady)
}

@Test func modelFailuresGiveActionableNonTechnicalGuidance() {
    #expect(ModelReadinessState.unavailable.guidance.contains("Apple Intelligence"))
    #expect(ModelReadinessState.timedOut.guidance.contains("30 seconds"))
    #expect(ModelReadinessState.invalidResponse.guidance.contains("Update or reinstall"))
    #expect(!ModelReadinessState.unavailable.guidance.lowercased().contains("nserror"))
}

private extension ModelReadinessState {
    static let allNonReadyStates: [ModelReadinessState] = [
        .notChecked,
        .checking,
        .unavailable,
        .toolMissing,
        .timedOut,
        .invalidResponse,
    ]
}
