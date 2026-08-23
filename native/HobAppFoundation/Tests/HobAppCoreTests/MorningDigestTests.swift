// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import HobAppCore

@Test func morningDigestCombinesTodaysPlanAndOverdueWorkWithoutDuplicates() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let today = try #require(ISO8601DateFormatter().date(
        from: "2026-08-24T06:30:00-04:00"
    ))
    let tasks = [
        digestTask(id: "planned", task: "Call the vet", dueDate: "2026-08-24"),
        digestTask(id: "late", task: "Pay taxes", dueDate: "2026-08-23"),
        digestTask(id: "later", task: "Buy paint", dueDate: "2026-08-25"),
    ]
    let proposal = digestProposal(blocks: [RuntimeScheduleBlock(
        id: "block-planned",
        taskID: "planned",
        task: "Call the vet",
        startAt: "2026-08-24T09:30:00-04:00",
        endAt: "2026-08-24T10:00:00-04:00",
        durationMinutes: 30,
        priority: "normal"
    )])

    let digest = RuntimeMorningDigestBuilder.build(
        for: today,
        tasks: tasks,
        proposal: proposal,
        timezone: zone
    )

    #expect(digest.date == "2026-08-24")
    #expect(digest.items.map(\.taskID) == ["planned", "late"])
    #expect(digest.items[0].summary.contains("9:30"))
    #expect(digest.items[0].summary.hasSuffix("· Call the vet"))
    #expect(digest.items[1].summary == "Pay taxes · overdue")
}

@Test func emptyMorningDigestUsesTheFamiliarMessage() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let today = try #require(ISO8601DateFormatter().date(
        from: "2026-08-24T06:30:00-04:00"
    ))
    let digest = RuntimeMorningDigestBuilder.build(
        for: today,
        tasks: [],
        proposal: nil,
        timezone: zone
    )

    #expect(digest.items.isEmpty)
    #expect(digest.notificationBody == "Nothing on deck today.")
}

@Test func upcomingMorningDigestsCoverSevenLocalDates() throws {
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let today = try #require(ISO8601DateFormatter().date(
        from: "2026-11-01T01:30:00-04:00"
    ))
    let digests = RuntimeMorningDigestBuilder.upcoming(
        from: today,
        days: 7,
        tasks: [],
        proposal: nil,
        timezone: zone
    )

    #expect(digests.count == 7)
    #expect(digests.first?.date == "2026-11-01")
    #expect(digests.last?.date == "2026-11-07")
}

private func digestTask(
    id: String,
    task: String,
    dueDate: String
) -> RuntimeTask {
    RuntimeTask(
        id: id,
        rawText: task,
        task: task,
        dueDate: dueDate,
        dueTime: nil,
        status: "open",
        createdAt: "2026-08-20T12:00:00-04:00",
        updatedAt: "2026-08-20T12:00:00-04:00"
    )
}

private func digestProposal(
    blocks: [RuntimeScheduleBlock]
) -> RuntimeScheduleProposal {
    RuntimeScheduleProposal(
        id: "digest-proposal",
        generatedAt: "2026-08-24T06:30:00-04:00",
        startDate: "2026-08-24",
        timezone: "America/New_York",
        workStart: "09:00",
        workEnd: "17:30",
        taskVersions: Dictionary(uniqueKeysWithValues: blocks.map {
            ($0.taskID, "2026-08-20T12:00:00-04:00")
        }),
        blocks: blocks,
        unscheduled: [],
        assumptions: []
    )
}
