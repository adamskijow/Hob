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
func conversationalContinuationAddsAnotherAppointment() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let existing = RuntimeTask(
        id: "office", rawText: "Go to the office at 1030",
        task: "Go to the office", dueDate: "2026-08-25",
        dueTime: "10:30", status: "open",
        createdAt: "2026-08-25T07:00:00-04:00",
        updatedAt: "2026-08-25T07:00:00-04:00"
    )

    let actions = try await interpreter.interpret(
        message: "And prexchool at 230",
        now: "2026-08-25T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: [existing],
        context: RuntimeConversationContext(focusedTaskIDs: [existing.id])
    )

    #expect(actions.count == 1)
    #expect(actions.first?.type == "capture")
    let task = actions.first?.task?.lowercased() ?? ""
    #expect(["prexchool", "preschool", "pre-school"].contains {
        task.contains($0)
    })
    #expect(actions.first?.time == "14:30")
}

@Test
func tomorrowStatusQuestionReturnsTomorrowTasks() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let actions = try await interpreter.interpret(
        message: "How's it looking tomorrow",
        now: "2026-08-25T12:29:00-04:00",
        timezone: "America/New_York",
        tasks: []
    )

    #expect(actions.count == 1)
    #expect(actions.first?.type == "query")
    #expect(actions.first?.queryKind == "date")
    #expect(actions.first?.when == RuntimeDateIntent(kind: "tomorrow"))
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
func modelKeepsSocialMessagesOutOfPlanning() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }

    for message in [
        "thanks bro", "cool", "got it",
        "Who's the princess of the prairie?",
    ] {
        let actions = try await interpreter.interpret(
            message: message,
            now: "2026-08-25T08:00:00-04:00",
            timezone: "America/New_York",
            tasks: []
        )
        #expect(actions.count == 1)
        #expect(actions.first?.type == "social")
        let reply = try #require(actions.first?.reply)
        #expect(!reply.isEmpty)
    }
}

@Test
func taskLabelsPreserveUserWording() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }

    let actions = try await interpreter.interpret(
        message: "Return Amazon shit",
        now: "2026-08-26T19:00:00-04:00",
        timezone: "America/New_York",
        tasks: []
    )

    #expect(actions == [RuntimeAction(
        type: "capture", task: "Return Amazon shit",
        raw: "Return Amazon shit", priority: "normal", confidence: 1
    )])
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

    for message in ["test", "Eat bacon"] {
        let oneOff = try await interpreter.interpret(
            message: message,
            now: "2026-08-25T08:00:00-04:00",
            timezone: "America/New_York",
            tasks: []
        )
        #expect(oneOff.count == 1)
        #expect(oneOff.first?.type == "capture")
        #expect(oneOff.first?.recurrence == nil)
    }
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

@Test
func modelUnderstandsRecoveredParityFeatures() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let first = RuntimeTask(
        id: "a1", rawText: "call the bank", task: "call the bank",
        dueDate: nil, dueTime: nil, status: "open",
        createdAt: "2026-08-24T07:00:00-04:00",
        updatedAt: "2026-08-24T07:00:00-04:00"
    )
    var report = RuntimeTask(
        id: "a2", rawText: "finish the report", task: "finish the report",
        dueDate: nil, dueTime: nil, durationMinutes: 30,
        priority: "normal", status: "open",
        createdAt: "2026-08-24T07:00:00-04:00",
        updatedAt: "2026-08-24T07:00:00-04:00"
    )
    let done = RuntimeTask(
        id: "a3", rawText: "file taxes", task: "file taxes",
        dueDate: nil, dueTime: nil,
        completionHistory: ["2026-08-24T12:00:00-04:00"],
        status: "done",
        createdAt: "2026-08-20T07:00:00-04:00",
        updatedAt: "2026-08-24T12:00:00-04:00"
    )
    let now = "2026-08-25T08:00:00-04:00"
    let zone = "America/New_York"

    let query: [RuntimeAction]
    do { query = try await interpreter.interpret(
        message: "What did I finish this week?", now: now,
        timezone: zone, tasks: [first, report, done]
    ) } catch { Issue.record("query failed: \(error)"); return }
    #expect(query.first?.type == "query")
    #expect(query.first?.queryKind == "done")

    let revision: [RuntimeAction]
    do { revision = try await interpreter.interpret(
        message: "Make the report high priority and 90 minutes", now: now,
        timezone: zone, tasks: [first, report]
    ) } catch { Issue.record("revision failed: \(error)"); return }
    #expect(revision.allSatisfy { $0.type == "revise" && $0.target == "2" })
    #expect(revision.contains { $0.priority == "high" })
    #expect(revision.contains { $0.durationMinutes == 90 })

    let note: [RuntimeAction]
    do { note = try await interpreter.interpret(
        message: "Note that the gate code for the report is 4412", now: now,
        timezone: zone, tasks: [first, report]
    ) } catch { Issue.record("note failed: \(error)"); return }
    #expect(note.first?.type == "note")
    #expect(note.first?.target == "2")
    #expect(note.first?.note?.contains("4412") == true)

    let waiting: [RuntimeAction]
    do { waiting = try await interpreter.interpret(
        message: "I'm waiting on Sam for the report", now: now,
        timezone: zone, tasks: [first, report]
    ) } catch { Issue.record("waiting failed: \(error)"); return }
    #expect(waiting.first?.type == "wait")
    #expect(waiting.first?.target == "2")

    report.waitingSince = "2026-08-25T08:00:00-04:00"
    let resumed: [RuntimeAction]
    do { resumed = try await interpreter.interpret(
        message: "Sam replied, put the report back on deck", now: now,
        timezone: zone, tasks: [first, report]
    ) } catch { Issue.record("resume failed: \(error)"); return }
    #expect(resumed.first?.type == "resume")
    #expect(resumed.first?.target == "2")

    let followUp: [RuntimeAction]
    do { followUp = try await interpreter.interpret(
        message: "Make that 4pm", now: now,
        timezone: zone, tasks: [first, report],
        context: RuntimeConversationContext(focusedTaskIDs: ["a2"])
    ) } catch { Issue.record("follow-up failed: \(error)"); return }
    #expect(followUp.first?.type == "reschedule")
    #expect(followUp.first?.target == "2")
    #expect(followUp.first?.time == "16:00")
}

@Test
func reminderRegressionCorpusIsStableAcrossTwoRuns() async throws {
    let interpreter = AppleFoundationInterpreter()
    guard interpreter.isAvailable else { return }
    let now = "2026-08-25T08:00:00-04:00"
    let zone = "America/New_York"
    let insurance = RuntimeTask(
        id: "a1", rawText: "home insurance", task: "home insurance",
        dueDate: nil, dueTime: nil, status: "open",
        createdAt: now, updatedAt: now
    )
    let gym = RuntimeTask(
        id: "a2", rawText: "hit the grift", task: "hit the grift",
        dueDate: nil, dueTime: nil, status: "open",
        createdAt: now, updatedAt: now
    )
    let haircut = RuntimeTask(
        id: "a3", rawText: "do haircut for Willow", task: "do haircut for Willow",
        dueDate: nil, dueTime: nil, status: "open",
        createdAt: now, updatedAt: now
    )
    let report = RuntimeTask(
        id: "a4", rawText: "finish report", task: "finish report",
        dueDate: nil, dueTime: nil, durationMinutes: 30,
        priority: "normal", status: "open",
        createdAt: now, updatedAt: now
    )

    // Sources: production failures from Hob's Telegram/Ollama history, the old
    // interpreter evals, and reminder/calendar utterances shaped like TOPv2 and
    // SMCalFlow examples. Every case is repeated to expose model variance.
    for _ in 0..<2 {
        let cake = try await interpreter.interpret(
            message: "I gotta eat that cake before it goes bad tomorrow",
            now: now, timezone: zone, tasks: []
        )
        #expect(cake.count == 1)
        #expect(cake.first?.type == "capture")
        #expect(cake.first?.deadline == RuntimeDateIntent(kind: "tomorrow"))
        #expect(cake.first?.recurrence == nil)

        let grift = try await interpreter.interpret(
            message: "Tomorrow I got to hit the grift",
            now: now, timezone: zone, tasks: []
        )
        #expect(grift.first?.type == "capture")
        #expect(grift.first?.when == RuntimeDateIntent(kind: "tomorrow"))

        let reminder = try await interpreter.interpret(
            message: "Set a reminder to call Mom tomorrow at 4pm",
            now: now, timezone: zone, tasks: []
        )
        #expect(reminder.first?.type == "capture")
        #expect(reminder.first?.when == RuntimeDateIntent(kind: "tomorrow"))
        #expect(reminder.first?.time == "16:00")

        let recurring = try await interpreter.interpret(
            message: "Take out the trash every Monday",
            now: now, timezone: zone, tasks: []
        )
        #expect(recurring.first?.type == "capture")
        #expect(recurring.first?.recurrence?.frequency == "week")
        #expect(recurring.first?.recurrence?.weekdays == ["mon"])

        let query = try await interpreter.interpret(
            message: "What's my schedule tomorrow?",
            now: now, timezone: zone, tasks: []
        )
        #expect(query.first?.type == "query")
        #expect(query.first?.queryKind == "date")

        for zero in ["nada", "Bro jack shit got done today"] {
            let actions = try await interpreter.interpret(
                message: zero, now: now, timezone: zone,
                tasks: [insurance, gym]
            )
            #expect(actions == [RuntimeAction(type: "acknowledge")])
        }

        let zeroSugar = try await interpreter.interpret(
            message: "Buy zero sugar soda", now: now, timezone: zone, tasks: []
        )
        #expect(zeroSugar.first?.type == "capture")

        let amazon = try await interpreter.interpret(
            message: "Return Amazon shit", now: now, timezone: zone, tasks: []
        )
        #expect(amazon == [RuntimeAction(
            type: "capture", task: "Return Amazon shit",
            raw: "Return Amazon shit", priority: "normal", confidence: 1
        )])

        let completed = try await interpreter.interpret(
            message: "I did home insurance and hit the grift",
            now: now, timezone: zone, tasks: [insurance, gym]
        )
        #expect(completed.count == 2)
        #expect(Set(completed.map(\.type)) == Set(["complete"]))
        #expect(Set(completed.compactMap(\.target)) == Set(["1", "2"]))

        let kept = try await interpreter.interpret(
            message: "It needs to stay on", now: now, timezone: zone,
            tasks: [report],
            context: RuntimeConversationContext(focusedTaskIDs: [report.id])
        )
        #expect(kept == [RuntimeAction(type: "keep", target: "1")])

        let moved = try await interpreter.interpret(
            message: "Haircut got scheduled for next Friday",
            now: now, timezone: zone, tasks: [haircut]
        )
        #expect(moved.first?.type == "reschedule")
        #expect(moved.first?.when == RuntimeDateIntent(
            kind: "weekday", which: "next", day: "fri"
        ))

        let revised = try await interpreter.interpret(
            message: "Make the report high priority and 90 minutes",
            now: now, timezone: zone, tasks: [report]
        )
        #expect(revised == [RuntimeAction(
            type: "revise", target: "1", durationMinutes: 90,
            priority: "high"
        )])
    }
}

}
