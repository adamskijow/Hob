// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore
import HobAppStorage

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
            )],
            includedUntimedTaskIDs: ["a1", "a2"]
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
            workEnd: "09:20",
            includedUntimedTaskIDs: ["a1"]
        )
    )

    #expect(proposal.blocks.isEmpty)
    #expect(proposal.unscheduled.map(\.taskID) == ["a1"])
    #expect(proposal.assumptions == ["write report: 30m default estimate"])
}

@Test func plannerDoesNotInventTimesForUntimedWork() throws {
    let task = RuntimeTask(
        id: "on-deck",
        rawText: "Buy poster board",
        task: "buy poster board",
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "2026-06-29T08:00:00-04:00",
        updatedAt: "2026-06-29T08:00:00-04:00"
    )
    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: [task],
        request: RuntimeScheduleRequest(
            proposalID: "no-invented-time",
            generatedAt: "2026-06-29T08:00:00-04:00",
            startDate: "2026-06-29",
            timezone: "America/New_York"
        )
    )

    #expect(proposal.blocks.isEmpty)
    #expect(proposal.unscheduled.isEmpty)
    #expect(proposal.taskVersions.isEmpty)
    #expect(proposal.plannedUntimedTaskIDs.isEmpty)
}

@Test func plannerCarriesUntimedWorkButNotTimedAppointments() throws {
    var appointment = RuntimeTask(
        id: "appointment",
        rawText: "Meet the teacher at 2:30",
        task: "meet the teacher",
        dueDate: "2026-06-28",
        dueTime: "14:30",
        status: "open",
        createdAt: "2026-06-28T08:00:00-04:00",
        updatedAt: "2026-06-28T08:00:00-04:00"
    )
    let errand = RuntimeTask(
        id: "errand",
        rawText: "Buy poster board",
        task: "buy poster board",
        dueDate: "2026-06-28",
        dueTime: nil,
        status: "open",
        createdAt: "2026-06-28T08:00:00-04:00",
        updatedAt: "2026-06-28T08:00:00-04:00"
    )
    let request = RuntimeScheduleRequest(
        proposalID: "carry-rule",
        generatedAt: "2026-06-29T08:00:00-04:00",
        startDate: "2026-06-29",
        timezone: "America/New_York",
        workStart: "09:00",
        workEnd: "17:00",
        includedUntimedTaskIDs: ["errand"]
    )

    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: [appointment, errand], request: request
    )

    #expect(proposal.blocks.map(\.taskID) == ["errand"])
    #expect(proposal.unscheduled.isEmpty)
    #expect(proposal.taskVersions.keys.sorted() == ["errand"])

    appointment.dueDate = "2026-06-29"
    let sameDay = try RuntimeSchedulePlanner.propose(
        tasks: [appointment], request: request
    )
    #expect(sameDay.blocks.first?.startAt == "2026-06-29T14:30:00-04:00")
}

@Test func unavailableTimedAppointmentDoesNotMoveToTomorrow() throws {
    let appointment = RuntimeTask(
        id: "appointment",
        rawText: "Meet the teacher at 2:30",
        task: "meet the teacher",
        dueDate: "2026-06-29",
        dueTime: "14:30",
        durationMinutes: 30,
        status: "open",
        createdAt: "2026-06-29T08:00:00-04:00",
        updatedAt: "2026-06-29T08:00:00-04:00"
    )
    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: [appointment],
        request: RuntimeScheduleRequest(
            proposalID: "blocked-appointment",
            generatedAt: "2026-06-29T08:00:00-04:00",
            startDate: "2026-06-29",
            timezone: "America/New_York",
            workStart: "09:00",
            workEnd: "17:00",
            busy: [RuntimeBusyInterval(
                startAt: "2026-06-29T14:00:00-04:00",
                endAt: "2026-06-29T15:00:00-04:00"
            )]
        )
    )

    #expect(proposal.blocks.isEmpty)
    #expect(proposal.unscheduled.map(\.taskID) == ["appointment"])
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

@Test func planningPreferencesSkipDaysOffAndApplyDefaults() throws {
    let task = RuntimeTask(
        id: "weekend-task",
        rawText: "write report",
        task: "write report",
        dueDate: nil,
        dueTime: nil,
        status: "open",
        createdAt: "2026-08-21T18:00:00-04:00",
        updatedAt: "2026-08-21T18:00:00-04:00"
    )
    let proposal = try RuntimeSchedulePlanner.propose(
        tasks: [task],
        request: RuntimeScheduleRequest(
            proposalID: "working-rhythm",
            generatedAt: "2026-08-21T18:00:00-04:00",
            startDate: "2026-08-21",
            timezone: "America/New_York",
            workStart: "10:00",
            workEnd: "18:00",
            defaultDurationMinutes: 60,
            transitionBufferMinutes: 10,
            workDays: [1, 2, 3, 4, 5],
            includedUntimedTaskIDs: ["weekend-task"]
        )
    )

    #expect(proposal.blocks.first?.startAt == "2026-08-24T10:00:00-04:00")
    #expect(proposal.blocks.first?.durationMinutes == 60)
}

@Test func openLocalExportImportsAtomicallyAndPreservesAdvancedDetails() async throws {
    let data = Data(#"""
    {
      "schema_version": 11,
      "items": [{
        "id": "legacy-1",
        "raw_text": "Call Mom tomorrow",
        "task": "Call Mom",
        "due_date": "2026-08-19",
        "due_time": null,
        "status": "open",
        "source": "capture",
        "created_at": "2026-08-18T09:00:00-04:00",
        "updated_at": "2026-08-18T09:00:00-04:00",
        "priority": "high",
        "note": "Ask about the trip",
        "duration_minutes": 15
      }],
      "action_log": [],
      "digests": [],
      "meta": {},
      "plan_runs": [],
      "plan_sessions": []
    }
    """#.utf8)
    let parsed = try OpenLocalExportImporter.parse(data)
    #expect(parsed.tasks.map(\.task) == ["Call Mom"])
    #expect(parsed.preservedDetailCount == 1)
    #expect(parsed.tasks.first?.sourceArchive?.contains("Ask about the trip") == true)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try DurableTaskRuntime(
        store: TaskStateStore(directoryURL: directory)
    )
    _ = try await runtime.importOpenLocal(data)
    let reopened = try TaskStateStore(directoryURL: directory).load()
    #expect(reopened.tasks.map(\.id) == ["legacy-1"])
    #expect(reopened.taskOperations.map(\.id) == ["open-local-import:legacy-1"])
    await #expect(throws: OpenLocalImportError.destinationNotEmpty) {
        _ = try await runtime.importOpenLocal(data)
    }
}

@Test func invalidOpenLocalExportChangesNothing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hob-bad-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = try DurableTaskRuntime(
        store: TaskStateStore(directoryURL: directory)
    )
    await #expect(throws: OpenLocalImportError.invalidExport) {
        _ = try await runtime.importOpenLocal(Data("{}".utf8))
    }
    #expect(await runtime.snapshot().tasks.isEmpty)
}
