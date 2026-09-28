// SPDX-License-Identifier: MIT
import Testing
import HobAppCore
@testable import HobAppleIntelligence

@Test func completionTargetMatchingHandlesNaturalWordFormsAndTimePhrases() {
    let tasks = [
        RuntimeTask(
            id: "a1", rawText: "Plan to make an apple galeat",
            task: "Plan to make an apple galeat", dueDate: nil, dueTime: nil,
            status: "open", createdAt: "2026-09-01T07:00:00-04:00",
            updatedAt: "2026-09-01T07:00:00-04:00"
        ),
        RuntimeTask(
            id: "a2", rawText: "Climbing tonight", task: "Climbing tonight",
            dueDate: "2026-09-03", dueTime: nil, status: "open",
            createdAt: "2026-09-03T07:00:00-04:00",
            updatedAt: "2026-09-03T07:00:00-04:00"
        ),
    ]

    #expect(AppleFoundationInterpreter.uniquelyGroundedTarget(
        message: "I did climb a few days ago", open: tasks
    ) == 2)
}
