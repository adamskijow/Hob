// SPDX-License-Identifier: MIT
import Testing
import HobAppCore
@testable import HobAppleIntelligence

@Test func negatedFieldAndPolicyEditsNeverMutate() {
    let task = RuntimeTask(id: "a1", rawText: "Call Alex", task: "Call Alex", dueDate: "2026-09-18", dueTime: "15:00",
        status: "open", createdAt: "2026-09-18T08:00:00-04:00", updatedAt: "2026-09-18T08:00:00-04:00")
    for message in ["Don't remove the time from Call Alex", "Don't keep it forever", "Do not clear its date", "Never delete Call Alex"] {
        let actions = AppleFoundationInterpreter.directGroundedActions(message: message, open: [task], recentChange: true, focused: [1])
        #expect(actions?.map(\.type) == ["social"], "\(message)")
    }
}

@Test func compoundCommandsPreserveEveryClause() {
    for (message, expected) in [
        ("Move Call Alex to Friday and buy milk", ["Move Call Alex to Friday", "buy milk"]),
        ("Call Alex takes 30 minutes and add buy milk", ["Call Alex takes 30 minutes", "add buy milk"]),
        ("Buy milk and bread", []),
        ("Clean kitchen; call Sam", ["Clean kitchen", "call Sam"])
    ] {
        #expect((AppleFoundationInterpreter.independentClauses(in: message) ?? []) == expected)
    }
}

@Test func explicitCommandsDoNotTreatTaskTitlesAsIntent() {
    for title in ["Stays", "Keep", "Done", "Move", "Not done", "Remove", "Tomorrow"] {
        let tasks = ["Plan picnic", title].enumerated().map { index, name in
            RuntimeTask(id: "a\(index)", rawText: name, task: name, dueDate: nil, dueTime: nil,
                        status: "open", createdAt: "2026-09-07T08:00:00-04:00", updatedAt: "2026-09-07T08:00:00-04:00")
        }
        for verb in ["Remove", "Delete", "Drop"] {
            for message in ["\(verb) \(title)", "Please \(verb.lowercased()) the \(title) task"] {
                let actions = AppleFoundationInterpreter.directGroundedActions(message: message, open: tasks, recentChange: true, focused: [1])
                #expect(actions?.map(\.type) == ["drop"], "\(message)")
                #expect(actions?.first?.target == "2", "\(message)")
            }
        }
    }
}

@Test func namedCommandBoundariesPreserveNegationAndAmbiguity() {
    let task = RuntimeTask(id: "a1", rawText: "Stays", task: "Stays", dueDate: nil, dueTime: nil,
                           status: "open", createdAt: "2026-09-07T08:00:00-04:00", updatedAt: "2026-09-07T08:00:00-04:00")
    for message in ["Don't remove Stays", "Should I remove Stays?", "Remove Stays and buy milk", "Remove Stays now"] {
        let actions = AppleFoundationInterpreter.directGroundedActions(message: message, open: [task], recentChange: true, focused: [1])
        #expect(actions?.contains { ["keep", "complete", "drop"].contains($0.type) } != true, "\(message)")
    }
    let duplicate = RuntimeTask(id: "a2", rawText: task.rawText, task: task.task, dueDate: nil, dueTime: nil,
                                status: "open", createdAt: task.createdAt, updatedAt: task.updatedAt)
    #expect(AppleFoundationInterpreter.directGroundedActions(message: "Remove Stays", open: [task, duplicate], recentChange: true, focused: [1]) == nil)
    #expect(AppleFoundationInterpreter.directGroundedActions(message: "It needs to stay on", open: [task], recentChange: true, focused: [1])?.map(\.type) == ["keep"])
}

@Test func reviewAnswersDoNotSwallowNewTasksOrNegation() {
    for reply in ["Stays", "Keep please", "Yes, keep it please"] {
        #expect(RuntimeTaskReviewReply.parse(reply) == .keep)
    }
    for reply in ["Drop", "Remove it please", "Delete that"] {
        #expect(RuntimeTaskReviewReply.parse(reply) == .drop)
    }
    for reply in ["Move", "Move to Friday", "Please reschedule it to tomorrow"] {
        #expect(RuntimeTaskReviewReply.parse(reply) == .move)
    }
    for message in ["Keep the receipts", "Drop off library books", "Move the sofa",
                    "Don't drop it", "No, keep it", "Move it Thursday or Friday"] {
        #expect(RuntimeTaskReviewReply.parse(message) == nil)
    }
}

@Test func affirmativeAndNegatedReportsNeverShareCompletionEffects() {
    for (task, past) in [("Clean oven", "cleaned the oven"), ("Mail parcel", "mailed the parcel"),
                          ("Pay invoice", "paid the invoice"), ("Buy milk", "bought milk")] {
        let open = [RuntimeTask(id: "a1", rawText: task, task: task, dueDate: nil, dueTime: nil,
                               status: "open", createdAt: "2026-09-07T08:00:00-04:00", updatedAt: "2026-09-07T08:00:00-04:00")]
        let affirmative = AppleFoundationInterpreter.directGroundedActions(
            message: "I \(past)", open: open, recentChange: true, focused: [])
        #expect(affirmative?.map(\.type) == ["complete"], "\(past)")
        for prefix in ["I haven't", "I have not", "I never"] {
            let negative = AppleFoundationInterpreter.directGroundedActions(
                message: "\(prefix) \(past)", open: open, recentChange: true, focused: [])
            #expect(negative?.map(\.type) == ["social"], "\(prefix) \(past)")
        }
    }
}

@Test func sharedTaskWordsDoNotResolveAnAmbiguousTarget() {
    let open = ["Call Alex", "Call Sam"].enumerated().map { index, title in
        RuntimeTask(id: "a\(index)", rawText: title, task: title, dueDate: nil, dueTime: nil,
                    status: "open", createdAt: "2026-09-07T08:00:00-04:00", updatedAt: "2026-09-07T08:00:00-04:00")
    }
    #expect(AppleFoundationInterpreter.uniquelyGroundedTarget(message: "The call is done", open: open) == nil)
    #expect(AppleFoundationInterpreter.uniquelyGroundedTarget(message: "Call Sam is done", open: open) == 2)
    #expect(AppleFoundationInterpreter.uniquelyGroundedTarget(message: "Call Sam is done", open: open.reversed()) == 1)
}

@Test func ongoingLanguageChangesReviewPolicyWithoutCompletingOrRecurring() {
    let task = RuntimeTask(id: "a1", rawText: "Take my morning pill", task: "Take my morning pill",
                           dueDate: nil, dueTime: nil, status: "open",
                           createdAt: "2026-08-01T08:00:00-04:00", updatedAt: "2026-08-01T08:00:00-04:00")
    for message in ["Keep it forever", "This should stay indefinitely", "Don't ask me whether to keep this again"] {
        let action = AppleFoundationInterpreter.directGroundedActions(
            message: message, open: [task], recentChange: true, focused: [1])?.first
        #expect(action?.type == "revise", "\(message)")
        #expect(action?.target == "1", "\(message)")
        #expect(action?.reviewPolicy == "never", "\(message)")
        #expect(action?.recurrence == nil, "\(message)")
    }
    let restored = AppleFoundationInterpreter.directGroundedActions(
        message: "Ask me again about it", open: [task], recentChange: true, focused: [1])?.first
    #expect(restored?.type == "revise")
    #expect(restored?.reviewPolicy == "standard")
    #expect(AppleFoundationInterpreter.directGroundedActions(
        message: "Keep it for tomorrow", open: [task], recentChange: true, focused: [1])?.first?.reviewPolicy == nil)
}
