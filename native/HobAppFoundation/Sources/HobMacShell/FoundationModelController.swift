// SPDX-License-Identifier: MIT
import Foundation
#if canImport(HobAppCore)
import HobAppCore
#endif
#if canImport(HobAppleIntelligence)
import HobAppleIntelligence
#endif

@MainActor
final class FoundationModelController: ObservableObject {
    @Published private(set) var state: ModelReadinessState = .notChecked

    private let interpreter: AppleFoundationInterpreter

    init(interpreter: AppleFoundationInterpreter = AppleFoundationInterpreter()) {
        self.interpreter = interpreter
    }

    func check() {
        guard state != .checking else { return }
        guard interpreter.isAvailable else {
            state = .unavailable
            return
        }
        state = .checking
        Task {
            do {
                try await interpreter.probe()
                state = .available
            } catch {
                state = .unavailable
            }
        }
    }
}
