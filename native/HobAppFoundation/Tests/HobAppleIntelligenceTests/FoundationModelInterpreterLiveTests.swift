// SPDX-License-Identifier: MIT
import Testing
import Foundation
import HobAppCore
@testable import HobAppleIntelligence

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HOB_LIVE_TESTS"] == "1"))
struct FoundationModelInterpreterLiveTests {

@Test func compoundCapturesKeepIndependentConstraintsAndOngoingPolicy() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE")
    let cases: [(String, Int)] = [
        ("Buy milk tomorrow and call Sam on Friday", 2),
        ("I need to buy milk tomorrow and call Sam on Friday", 2),
        ("Could you buy milk tomorrow and call Sam on Friday", 2),
        ("Buy milk tomorrow and book a dentist appointment next Monday", 2),
        ("Buy milk tomorrow at 6pm and call Sam Friday at 3pm", 2),
        ("Take my morning pill and keep it indefinitely", 1),
        ("Buy milk and don't remove the time from Call Alex", 1),
    ]
    let existing = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: "2026-09-18", dueTime: "15:00",
        status: "open", createdAt: "2026-09-18T08:00:00-04:00", updatedAt: "2026-09-18T08:00:00-04:00")
    for (message, count) in cases {
        let actions: [RuntimeAction]
        do {
            actions = try await interpreter.interpret(message: message, now: "2026-09-18T08:01:00-04:00",
                timezone: "America/New_York", tasks: message.contains("Alex") ? [existing] : [])
        } catch {
            Issue.record("Interpretation failed for \(message): \(error)")
            continue
        }
        #expect(actions.count == count, "\(message): \(actions)")
        #expect(actions.allSatisfy { $0.kind == .capture }, "\(message)")
        if count == 2 {
            #expect(actions.first?.when == RuntimeDateIntent(kind: "tomorrow"), "\(message)")
            #expect(actions.last?.when?.kind == "weekday", "\(message)")
            #expect(actions.last?.when?.day == (message.contains("Monday") ? "mon" : "fri"))
            #expect(actions.first?.task?.localizedCaseInsensitiveContains("milk") == true)
            #expect(actions.first?.task?.localizedCaseInsensitiveContains("Sam") == false)
        }
        if message.contains("6pm") { #expect(actions.map(\.time) == ["18:00", "15:00"]) }
        if message.contains("indefinitely") {
            #expect(actions.first?.reviewPolicy == "never")
            #expect(actions.first?.recurrence == nil)
            #expect(actions.first?.task?.localizedCaseInsensitiveContains("pill") == true)
        }
    }
}

@Test func compoundEditsAndCapturesAreBothReturned() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE")
    let task = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: nil, dueTime: nil,
        status: "open", createdAt: "2026-09-18T08:00:00-04:00", updatedAt: "2026-09-18T08:00:00-04:00")
    for message in ["Move Call Alex to Friday and buy milk", "Call Alex takes 30 minutes and add buy milk", "Move Call Alex to Friday and buy milk tomorrow at 6pm"] {
        let actions = try await interpreter.interpret(message: message, now: "2026-09-18T08:01:00-04:00",
            timezone: "America/New_York", tasks: [task])
        #expect(actions.count == 2)
        #expect(actions.last?.type == "capture")
        #expect(actions.last?.task?.localizedCaseInsensitiveContains("milk") == true)
        #expect(actions.first?.target == "1")
        if message.contains("6pm") {
            #expect(actions.last?.when == RuntimeDateIntent(kind: "tomorrow"))
            #expect(actions.last?.time == "18:00")
        }
    }
    let other = RuntimeTask(id: "a2", rawText: "Call Sam", task: "Call Sam", dueDate: nil, dueTime: nil,
        status: "open", createdAt: task.createdAt, updatedAt: task.updatedAt)
    let related = try await interpreter.interpret(message: "Move Call Alex to Friday and make it high priority",
        now: "2026-09-18T08:01:00-04:00", timezone: "America/New_York", tasks: [task, other],
        context: RuntimeConversationContext(focusedTaskIDs: [other.id]))
    #expect(related.count == 2)
    #expect(related.allSatisfy { $0.target == "1" })
}

@Test
func coordinatedAppointmentsKeepTheirRespectiveTimes() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

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
func planningWorkRemainsACapturableTask() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

    let actions = try await interpreter.interpret(
        message: "Plan a schedule",
        now: "2026-08-31T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: [RuntimeTask(
            id: "anniversary", rawText: "buy anniversary gift",
            task: "buy anniversary gift", dueDate: nil, dueTime: nil,
            status: "open", createdAt: "2026-08-31T07:00:00-04:00",
            updatedAt: "2026-08-31T07:00:00-04:00"
        )]
    )

    #expect(actions == [RuntimeAction(
        type: "capture", task: "Plan a schedule",
        raw: "Plan a schedule", priority: "normal", confidence: 1
    )])
}

@Test
func unfamiliarImperativeRemainsACapturableTask() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

    let actions = try await interpreter.interpret(
        message: "Make an apple gelea",
        now: "2026-08-31T19:35:00-04:00",
        timezone: "America/New_York",
        tasks: [RuntimeTask(
            id: "anniversary", rawText: "buy anniversary gift",
            task: "buy anniversary gift", dueDate: "2026-08-31", dueTime: "09:00",
            status: "open", createdAt: "2026-08-31T07:00:00-04:00",
            updatedAt: "2026-08-31T07:00:00-04:00"
        )]
    )

    #expect(actions == [RuntimeAction(
        type: "capture", task: "Make an apple gelea",
        raw: "Make an apple gelea", priority: "normal", confidence: 1
    )])
}

@Test
func shortGerundActivityCapturesDirectly() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

    let actions = try await interpreter.interpret(
        message: "Climbing tonight",
        now: "2026-09-01T07:05:00-04:00",
        timezone: "America/New_York",
        tasks: [RuntimeTask(
            id: "galeat", rawText: "Plan to make an apple galeat",
            task: "Plan to make an apple galeat", dueDate: "2026-09-01",
            dueTime: nil, status: "open",
            createdAt: "2026-08-31T19:35:00-04:00",
            updatedAt: "2026-08-31T19:35:00-04:00"
        )]
    )

    #expect(actions.count == 1)
    #expect(actions.first?.type == "capture")
    #expect(actions.first?.task?.localizedCaseInsensitiveContains("climbing") == true)
    #expect(actions.first?.recurrence == nil)
}

@Test
func naturalConstraintRemovalEditsTheNamedTask() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

    let actions = try await interpreter.interpret(
        message: "Buy an anniversary gift does not need a time",
        now: "2026-08-31T19:41:00-04:00",
        timezone: "America/New_York",
        tasks: [RuntimeTask(
            id: "anniversary", rawText: "buy anniversary gift",
            task: "buy anniversary gift", dueDate: "2026-08-31", dueTime: "09:00",
            status: "open", createdAt: "2026-08-31T07:00:00-04:00",
            updatedAt: "2026-08-31T07:00:00-04:00"
        )]
    )

    #expect(actions == [RuntimeAction(
        type: "revise", target: "1", clearFields: ["time"]
    )])
}

@Test
func explicitReplanRequestStillBuildsAPlan() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

    let actions = try await interpreter.interpret(
        message: "Replan my day",
        now: "2026-08-31T08:00:00-04:00",
        timezone: "America/New_York",
        tasks: [RuntimeTask(
            id: "anniversary", rawText: "buy anniversary gift",
            task: "buy anniversary gift", dueDate: nil, dueTime: nil,
            status: "open", createdAt: "2026-08-31T07:00:00-04:00",
            updatedAt: "2026-08-31T07:00:00-04:00"
        )]
    )

    #expect(actions == [RuntimeAction(type: "replan")])
}

@Test
func modelUnderstandsRecurrence() async throws {
    let interpreter = AppleFoundationInterpreter()
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")

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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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
    try #require(interpreter.isAvailable, "LIVE MODEL UNAVAILABLE: this regression did not run")
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

        let climbing = RuntimeTask(
            id: "climbing", rawText: "Climbing tonight", task: "Climbing tonight",
            dueDate: "2026-08-21", dueTime: nil, status: "open",
            createdAt: "2026-08-21T09:00:00-04:00",
            updatedAt: "2026-08-21T09:00:00-04:00"
        )
        let naturalCompletion = try await interpreter.interpret(
            message: "I did climb a few days ago", now: now,
            timezone: zone, tasks: [report, climbing]
        )
        #expect(naturalCompletion == [RuntimeAction(
            type: "complete", target: "2"
        )])

        let kept = try await interpreter.interpret(
            message: "It needs to stay on", now: now, timezone: zone,
            tasks: [report],
            context: RuntimeConversationContext(focusedTaskIDs: [report.id])
        )
        #expect(kept == [RuntimeAction(type: "keep", target: "1")])

        let terseKeep = try await interpreter.interpret(
            message: "It stays", now: now, timezone: zone,
            tasks: [report],
            context: RuntimeConversationContext(focusedTaskIDs: [report.id])
        )
        #expect(terseKeep == [RuntimeAction(type: "keep", target: "1")])

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
