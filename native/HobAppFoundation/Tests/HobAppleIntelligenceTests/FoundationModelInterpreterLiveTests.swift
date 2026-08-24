// SPDX-License-Identifier: MIT
import Testing
@testable import HobAppleIntelligence

@Test
func coordinatedAppointmentsKeepTheirRespectiveTimes() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }

    let actions = try await interpreter.interpret(
        message: "Meeting with Claude code and dev team at 230 and 330 respectively",
        now: "2026-08-24T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: []
    )
    #expect(actions.count == 2)
    guard actions.count == 2 else { return }
    #expect(actions.map(\.time) == ["14:30", "15:30"])
    #expect(actions[0].task?.localizedCaseInsensitiveContains("claude") == true)
    #expect(actions[0].task?.localizedCaseInsensitiveContains("dev") == false)
    #expect(actions[1].task?.localizedCaseInsensitiveContains("dev") == true)
    #expect(actions[1].task?.localizedCaseInsensitiveContains("claude") == false)
    #expect(actions.allSatisfy {
        $0.task?.contains("230") == false && $0.task?.contains("330") == false
    })
}
