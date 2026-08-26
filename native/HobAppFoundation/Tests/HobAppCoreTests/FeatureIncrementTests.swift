// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

@Test func clockOnlyCaptureIsAnchoredToToday() {
    var runtime = TaskRuntime()
    let result = runtime.process(turn(
        id: "clock-only",
        now: "2026-08-25T09:00:00-04:00",
        action: RuntimeAction(
            type: "capture",
            task: "go to the office",
            raw: "go to the office at 10:30",
            time: "10:30"
        )
    ))

    #expect(result.outcome.disposition == .applied)
    #expect(result.outcome.tasks.first?.dueDate == "2026-08-25")
    #expect(result.outcome.tasks.first?.dueTime == "10:30")
}

@Test func groundedDateIntentsCoverOffsetsNamedDatesAndInvalidDates() throws {
    var runtime = TaskRuntime()

    let offset = runtime.process(turn(
        id: "offset-years",
        now: "2026-08-25T09:00:00-04:00",
        action: RuntimeAction(
            type: "capture",
            task: "buy bananas",
            raw: "buy bananas in 10 years",
            when: RuntimeDateIntent(kind: "offset", n: 10, unit: "year")
        )
    ))
    #expect(offset.outcome.disposition == .applied)
    #expect(offset.outcome.tasks[0].dueDate == "2036-08-25")

    let named = runtime.process(turn(
        id: "named-date",
        action: RuntimeAction(
            type: "capture",
            task: "renew passport",
            raw: "renew passport on February 28 2030",
            when: RuntimeDateIntent(
                kind: "absolute", year: 2030, month: 2, dayNumber: 28
            )
        )
    ))
    #expect(named.outcome.disposition == .applied)
    #expect(named.outcome.tasks.last?.dueDate == "2030-02-28")

    let before = runtime.tasks
    let invalid = runtime.process(turn(
        id: "invalid-date",
        action: RuntimeAction(
            type: "capture",
            task: "impossible",
            raw: "February 30 2030",
            when: RuntimeDateIntent(
                kind: "absolute", year: 2030, month: 2, dayNumber: 30
            )
        )
    ))
    #expect(invalid.outcome.disposition == .rejected)
    #expect(runtime.tasks == before)
}

@Test func weekendAndMonthDayDatesUseCalendarMeaning() {
    var runtime = TaskRuntime()
    let sunday = runtime.process(turn(
        id: "this-weekend",
        now: "2026-08-30T09:00:00-04:00",
        action: RuntimeAction(
            type: "capture",
            task: "walk",
            raw: "walk this weekend",
            when: RuntimeDateIntent(kind: "weekend", which: "this")
        )
    ))
    #expect(sunday.outcome.tasks[0].dueDate == "2026-08-30")

    let monthDay = runtime.process(turn(
        id: "month-day",
        now: "2026-08-25T09:00:00-04:00",
        action: RuntimeAction(
            type: "capture",
            task: "appointment",
            raw: "appointment September 4",
            when: RuntimeDateIntent(
                kind: "month_day", month: 9, dayNumber: 4
            )
        )
    ))
    #expect(monthDay.outcome.tasks.last?.dueDate == "2026-09-04")
}

@Test func recurringCompletionAdvancesAndUndoRestoresOccurrence() {
    var runtime = TaskRuntime()
    _ = runtime.process(turn(
        id: "repeat-capture",
        action: RuntimeAction(
            type: "capture",
            task: "water plants",
            raw: "water plants every day",
            when: RuntimeDateIntent(kind: "today"),
            recurrence: RuntimeRecurrenceRule(frequency: "day")
        )
    ))
    let completed = runtime.process(turn(
        id: "repeat-complete",
        action: RuntimeAction(type: "complete", target: "a1")
    ))
    #expect(completed.outcome.disposition == .applied)
    #expect(runtime.tasks[0].status == "open")
    #expect(runtime.tasks[0].dueDate == "2026-08-26")
    #expect(runtime.tasks[0].recurrence?.completed == 1)

    _ = runtime.process(turn(
        id: "repeat-undo",
        action: RuntimeAction(type: "undo")
    ))
    #expect(runtime.tasks[0].dueDate == "2026-08-25")
    #expect(runtime.tasks[0].recurrence?.completed == 0)
}

@Test func weeklyRecurrenceUsesSelectedDaysAndInterval() {
    var runtime = TaskRuntime()
    _ = runtime.process(turn(
        id: "weekly-capture",
        now: "2026-08-24T09:00:00-04:00",
        action: RuntimeAction(
            type: "capture",
            task: "climb",
            raw: "climb Monday and Wednesday every other week",
            when: RuntimeDateIntent(
                kind: "absolute", year: 2026, month: 8, dayNumber: 24
            ),
            recurrence: RuntimeRecurrenceRule(
                frequency: "week", interval: 2, weekdays: ["mon", "wed"]
            )
        )
    ))
    _ = runtime.process(turn(
        id: "weekly-first",
        now: "2026-08-24T18:00:00-04:00",
        action: RuntimeAction(type: "complete", target: "a1")
    ))
    #expect(runtime.tasks[0].dueDate == "2026-08-26")
    _ = runtime.process(turn(
        id: "weekly-second",
        now: "2026-08-26T18:00:00-04:00",
        action: RuntimeAction(type: "complete", target: "a1")
    ))
    #expect(runtime.tasks[0].dueDate == "2026-09-07")
}

@Test func monthlyRecurrenceClampsToLastDayAndCountCanClose() {
    var runtime = TaskRuntime()
    _ = runtime.process(turn(
        id: "monthly-capture",
        now: "2027-01-31T09:00:00-05:00",
        action: RuntimeAction(
            type: "capture",
            task: "month end",
            raw: "month end twice",
            when: RuntimeDateIntent(kind: "today"),
            recurrence: RuntimeRecurrenceRule(
                frequency: "month", monthDay: 31, count: 2
            )
        )
    ))
    _ = runtime.process(turn(
        id: "monthly-first",
        now: "2027-01-31T17:00:00-05:00",
        action: RuntimeAction(type: "complete", target: "a1")
    ))
    #expect(runtime.tasks[0].dueDate == "2027-02-28")
    #expect(runtime.tasks[0].status == "open")
    _ = runtime.process(turn(
        id: "monthly-second",
        now: "2027-02-28T17:00:00-05:00",
        action: RuntimeAction(type: "complete", target: "a1")
    ))
    #expect(runtime.tasks[0].status == "done")
    #expect(runtime.tasks[0].recurrence?.completed == 2)
}

@Test func recurringOccurrenceCanSkipOrStopAndPersists() throws {
    var runtime = TaskRuntime()
    _ = runtime.process(turn(
        id: "skip-capture",
        action: RuntimeAction(
            type: "capture",
            task: "practice",
            raw: "practice weekly",
            when: RuntimeDateIntent(kind: "today"),
            recurrence: RuntimeRecurrenceRule(frequency: "week")
        )
    ))
    _ = runtime.process(turn(
        id: "skip",
        action: RuntimeAction(
            type: "recurrence", target: "a1", recurrenceOperation: "skip"
        )
    ))
    #expect(runtime.tasks[0].dueDate == "2026-09-01")
    let restored = try TaskRuntime(persistentState: runtime.persistentState.validated())
    #expect(restored.tasks[0].recurrence?.frequency == "week")
    var stopped = restored
    _ = stopped.process(turn(
        id: "stop",
        action: RuntimeAction(
            type: "recurrence", target: "a1", recurrenceOperation: "stop"
        )
    ))
    #expect(stopped.tasks[0].recurrence == nil)
    #expect(stopped.tasks[0].status == "open")
}

@Test func skippingTheFinalRecurringOccurrenceClosesTheSeries() {
    var runtime = TaskRuntime()
    _ = runtime.process(turn(
        id: "ending-capture",
        action: RuntimeAction(
            type: "capture",
            task: "submit report",
            raw: "submit report daily through today",
            when: RuntimeDateIntent(kind: "today"),
            recurrence: RuntimeRecurrenceRule(
                frequency: "day", endDate: "2026-08-25"
            )
        )
    ))
    _ = runtime.process(turn(
        id: "ending-skip",
        action: RuntimeAction(
            type: "recurrence", target: "a1", recurrenceOperation: "skip"
        )
    ))
    #expect(runtime.tasks[0].status == "done")
    #expect(runtime.tasks[0].dueDate == "2026-08-25")
}

@Test func recurrenceSurvivesSyncOperationRoundTrip() throws {
    let recurring = RuntimeTask(
        id: "a1", rawText: "climb every Friday", task: "climb",
        dueDate: "2026-08-28", dueTime: nil, durationMinutes: 90,
        priority: "normal",
        recurrence: RuntimeRecurrenceRule(
            frequency: "week", weekdays: ["fri"]
        ),
        status: "open",
        createdAt: "2026-08-25T08:00:00-04:00",
        updatedAt: "2026-08-25T09:00:00-04:00"
    )
    let operation = RuntimeTaskOperation(
        id: "op1", taskID: recurring.id,
        occurredAt: recurring.updatedAt, task: recurring
    )
    #expect(operation.isValid)
    let tasks = try RuntimeTaskOperationMerge.tasks(from: [operation])
    #expect(tasks == [recurring])
}

@Test func capacityAnalysisAccountsForCalendarAndNeverMutatesTasks() throws {
    let tasks = [task(id: "a1", title: "deep work", duration: 60)]
    let action = RuntimeAction(
        type: "analysis", analysisKind: "capacity", horizonDays: 1
    )
    let analysis = try RuntimePlanningAnalyzer.analyze(
        tasks: tasks,
        action: action,
        request: scheduleRequest(
            workStart: "09:00", workEnd: "10:00",
            busy: [RuntimeBusyInterval(
                startAt: "2026-08-25T09:00:00-04:00",
                endAt: "2026-08-25T09:30:00-04:00"
            )]
        )
    )
    #expect(!analysis.fits)
    #expect(analysis.capacityMinutes == 30)
    #expect(analysis.requiredMinutes == 60)
    #expect(tasks == [task(id: "a1", title: "deep work", duration: 60)])
}

@Test func explanationAndWhatIfAreReadOnlyAndShowTheirBasis() throws {
    let fixed = RuntimeTask(
        id: "a1", rawText: "meeting", task: "meeting",
        dueDate: "2026-08-25", dueTime: "10:00",
        durationMinutes: 30, priority: "normal", status: "open",
        createdAt: "2026-08-25T08:00:00-04:00",
        updatedAt: "2026-08-25T08:00:00-04:00"
    )
    let explanation = try RuntimePlanningAnalyzer.analyze(
        tasks: [fixed],
        action: RuntimeAction(
            type: "analysis", target: "a1",
            analysisKind: "explain", horizonDays: 1
        ),
        request: scheduleRequest()
    )
    #expect(explanation.details.joined().contains("time you stated"))

    let untimed = task(id: "a2", title: "write report", duration: 30)
    let original = [untimed]
    let whatIf = try RuntimePlanningAnalyzer.analyze(
        tasks: original,
        action: RuntimeAction(
            type: "analysis", target: "a2", analysisKind: "what_if",
            horizonDays: 1, hypotheticalDurationMinutes: 120
        ),
        request: scheduleRequest(workStart: "09:00", workEnd: "10:00")
    )
    #expect(!whatIf.fits)
    #expect(whatIf.details.joined().contains("120m"))
    #expect(original[0].durationMinutes == 30)
    #expect(whatIf.assumptions.contains { $0.contains("09:00–10:00") })
}

private func turn(
    id: String,
    now: String = "2026-08-25T09:00:00-04:00",
    action: RuntimeAction
) -> RuntimeTurnRequest {
    RuntimeTurnRequest(
        requestID: id,
        message: id,
        now: now,
        timezone: "America/New_York",
        actions: [action]
    )
}

private func task(
    id: String,
    title: String,
    duration: Int?
) -> RuntimeTask {
    RuntimeTask(
        id: id, rawText: title, task: title,
        dueDate: nil, dueTime: nil, durationMinutes: duration,
        priority: "normal", status: "open",
        createdAt: "2026-08-25T08:00:00-04:00",
        updatedAt: "2026-08-25T08:00:00-04:00"
    )
}

private func scheduleRequest(
    workStart: String = "09:00",
    workEnd: String = "17:30",
    busy: [RuntimeBusyInterval] = []
) -> RuntimeScheduleRequest {
    RuntimeScheduleRequest(
        proposalID: "analysis-test",
        generatedAt: "2026-08-25T09:00:00-04:00",
        startDate: "2026-08-25",
        timezone: "America/New_York",
        horizonDays: 1,
        workStart: workStart,
        workEnd: workEnd,
        busy: busy
    )
}
