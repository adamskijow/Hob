// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

@Test func reviewerScenarioBecomesAFeasibleMultiDayTimeline() throws {
    let tasks = [
        RuntimeTask(
            id: "a1",
            rawText: "Finish taxes by Friday, high priority, about 90 minutes",
            task: "finish taxes",
            dueDate: nil,
            dueTime: nil,
            deadlineDate: "2026-07-03",
            durationMinutes: 90,
            priority: "high",
            status: "open",
            createdAt: "2026-06-29T08:00:00-04:00",
            updatedAt: "2026-06-29T08:00:00-04:00"
        ),
        RuntimeTask(
            id: "a2",
            rawText: "call Mom tomorrow for 15 minutes",
            task: "call Mom",
            dueDate: "2026-06-30",
            dueTime: nil,
            durationMinutes: 15,
            priority: "normal",
            status: "open",
            createdAt: "2026-06-29T08:00:00-04:00",
            updatedAt: "2026-06-29T08:00:00-04:00"
        ),
    ]
    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: tasks,
        request: RuntimeScheduleRequest(
            proposalID: "reviewer-scenario",
            generatedAt: "2026-06-29T08:00:00-04:00",
            startDate: "2026-06-29",
            timezone: "America/New_York",
            workStart: "09:00",
            workEnd: "17:00",
            busy: [RuntimeBusyInterval(
                startAt: "2026-06-29T09:00:00-04:00",
                endAt: "2026-06-29T10:00:00-04:00"
            )]
        )
    )

    #expect(proposal.blocks.map(\.taskID) == ["a1", "a2"])
    #expect(proposal.blocks[0].startAt == "2026-06-29T10:00:00-04:00")
    #expect(proposal.blocks[0].endAt == "2026-06-29T11:30:00-04:00")
    #expect(proposal.blocks[1].startAt == "2026-06-30T09:00:00-04:00")
    #expect(proposal.blocks[1].endAt == "2026-06-30T09:15:00-04:00")
    #expect(proposal.unscheduled.isEmpty)
    #expect(proposal.assumptions.isEmpty)
}

@Test func schedulerExposesCapacityFailureAndDefaultEstimate() throws {
    let task = RuntimeTask(
        id: "a1",
        rawText: "write report",
        task: "write report",
        dueDate: "2026-06-29",
        dueTime: nil,
        status: "open",
        createdAt: "2026-06-29T08:00:00-04:00",
        updatedAt: "2026-06-29T08:00:00-04:00"
    )
    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: [task],
        request: RuntimeScheduleRequest(
            proposalID: "no-room",
            generatedAt: "2026-06-29T08:00:00-04:00",
            startDate: "2026-06-29",
            timezone: "America/New_York",
            workStart: "09:00",
            workEnd: "09:20"
        )
    )

    #expect(proposal.blocks.isEmpty)
    #expect(proposal.unscheduled.map(\.taskID) == ["a1"])
    #expect(proposal.assumptions == ["write report: 30m default estimate"])
}

@Test func taskRuntimePersistsTypedPlanningConstraints() {
    var runtime = TaskRuntime()
    let result = runtime.process(RuntimeTurnRequest(
        requestID: "typed-capture",
        message: "Finish taxes by Friday, high priority, about 90 minutes",
        now: "2026-06-29T08:00:00-04:00",
        timezone: "America/New_York",
        actions: [RuntimeAction(
            type: "capture",
            task: "finish taxes",
            raw: "Finish taxes by Friday, high priority, about 90 minutes",
            deadline: RuntimeDateIntent(kind: "weekday", which: "this", day: "fri"),
            durationMinutes: 90,
            priority: "high"
        )]
    )).outcome

    #expect(result.disposition == .applied)
    #expect(result.tasks[0].deadlineDate == "2026-07-03")
    #expect(result.tasks[0].durationMinutes == 90)
    #expect(result.tasks[0].priority == "high")
}

@Test func invalidBusyIntervalsFailClosed() {
    #expect(throws: RuntimeScheduleError.invalidRequest) {
        _ = try RuntimeSchedulePlanner.propose(
            tasks: [],
            request: RuntimeScheduleRequest(
                proposalID: "bad-busy",
                generatedAt: "2026-06-29T08:00:00-04:00",
                startDate: "2026-06-29",
                timezone: "America/New_York",
                busy: [RuntimeBusyInterval(startAt: "bad", endAt: "worse")]
            )
        )
    }
}
