// SPDX-License-Identifier: MIT
import Testing
import HobAppCore
@testable import HobAppleIntelligence

@Suite(.serialized)
struct FoundationModelInterpreterLiveTests {

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

@Test
func modelUnderstandsLongDates() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }

    let longDate = try await interpreter.interpret(
        message: "Buy bananas in 10 years",
        now: "2026-08-25T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: []
    )
    #expect(longDate.count == 1)
    #expect(longDate.first?.type == "capture")
    #expect(longDate.first?.when == RuntimeDateIntent(
        kind: "offset", n: 10, unit: "year"
    ))

}

@Test
func modelUnderstandsRecurrence() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }

    let repeating = try await interpreter.interpret(
        message: "Water the plants every Monday",
        now: "2026-08-25T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: []
    )
    #expect(repeating.count == 1)
    #expect(repeating.first?.recurrence?.frequency == "week")
    #expect(repeating.first?.recurrence?.weekdays == ["mon"])
}

@Test
func modelUnderstandsCapacityQuestions() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let task = RuntimeTask(
        id: "a1", rawText: "finish report", task: "finish report",
        dueDate: nil, dueTime: nil, durationMinutes: 60,
        priority: "normal", status: "open",
        createdAt: "2026-08-25T07:00:00-04:00",
        updatedAt: "2026-08-25T07:00:00-04:00"
    )
    let capacity = try await interpreter.interpret(
        message: "Will this week fit?",
        now: "2026-08-25T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: [task]
    )
    #expect(capacity == [RuntimeAction(
        type: "analysis", analysisKind: "capacity", horizonDays: 7
    )])

}

@Test
func modelUnderstandsWhatIfQuestions() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let task = RuntimeTask(
        id: "a1", rawText: "finish report", task: "finish report",
        dueDate: nil, dueTime: nil, durationMinutes: 60,
        priority: "normal", status: "open",
        createdAt: "2026-08-25T07:00:00-04:00",
        updatedAt: "2026-08-25T07:00:00-04:00"
    )
    let whatIf = try await interpreter.interpret(
        message: "What if the report takes two hours?",
        now: "2026-08-25T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: [task]
    )
    #expect(whatIf == [RuntimeAction(
        type: "analysis", target: "1", analysisKind: "what_if",
        horizonDays: 7, hypotheticalDurationMinutes: 120
    )])
}

}
