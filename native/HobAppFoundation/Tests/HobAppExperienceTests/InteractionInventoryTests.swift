// SPDX-License-Identifier: MIT
import Foundation
import Testing
import HobAppCore

@Test func interactionInventoryIsComplete() throws {
    // These names are verified against actual successful test results by the
    // coverage gate; merely listing a test here does not count as execution.
    let evidence: [RuntimeInteraction: [String]] = [
        .taskReview: ["staleDigestReplyKeepsReferencedTaskInsteadOfCapturingReply", "reminderEditorCanKeepAnItemIndefinitelyAndRestoreCheckIns"],
        .chooseTask: ["questionStateInvalidatesOnRevisionDayOrTimezoneChange"],
        .chooseDate: ["questionStateInvalidatesOnRevisionDayOrTimezoneChange"],
        .longRangeApproval: ["farFutureDateRequiresShortConfirmationBeforeWriting"],
        .eveningRecap: ["dailyCheckInsAreIndependentAndSupportEveryHour"],
        .reminderDone: ["captureStaysUntimedUntilUserPlansAndAdoptsIt"],
        .reminderSnooze: ["captureStaysUntimedUntilUserPlansAndAdoptsIt"],
        .reminderReplan: ["captureStaysUntimedUntilUserPlansAndAdoptsIt"],
        .taskEdit: ["todayTaskCanBeMarkedDoneAndUndone", "reminderListSeparatesFutureFromTodayAndHistory", "upcomingDatesRespectTimezoneDSTAndYearBoundaries", "reminderEditorMovesClearsAndPersistsWithoutCalendarWrites"],
        .scheduleApproval: ["captureStaysUntimedUntilUserPlansAndAdoptsIt"],
        .freeform: ["socialReplyStaysInConversationWithoutPlanningOrTaskChanges", "failedInterpretationKeepsSubmittedTextInConversation", "failedSaveNeverProducesASuccessfulConversationReply", "syncRevisionReplacesPendingQuestionInsteadOfRetargeting", "duplicateDeliveryConflictsFailClosedWithoutAnotherMutation"],
        .setupRecovery: ["setupReviewCanAlwaysCloseWithoutWeakeningFirstRun"],
    ]
    let live: [RuntimeInteraction: [String]] = [
        .taskReview: ["review-keep-0", "review-move-question", "review-drop-0", "ongoing-review-policy"],
        .chooseTask: ["ambiguous-target"],
        .chooseDate: ["family-restart-question", "ambiguous-date"],
        .freeform: ["family-double-send", "family-negative-progress", "family-focus-competition", "family-topic-switch", "family-cancel-question"],
        .reminderDone: ["notification-to-chat"],
        .eveningRecap: ["nonaction-4", "complete-0", "capture-0"],
    ]
    #expect(Set(evidence.keys) == Set(RuntimeInteraction.allCases))
    #expect(RuntimeInteraction.taskReview.offeredReplies.count == 3)
    for (reply, expected) in zip(RuntimeInteraction.taskReview.offeredReplies, [RuntimeTaskReviewReply.keep, .move, .drop]) {
        #expect(RuntimeTaskReviewReply.parse(reply) == expected)
    }
    if let path = ProcessInfo.processInfo.environment["HOB_INTERACTION_INVENTORY"] {
        let rows: [[String: Any]] = RuntimeInteraction.allCases.map { contract in
            ["contract": contract.rawValue, "offeredReplies": contract.offeredReplies,
             "requiredTests": evidence[contract] ?? [], "requiredScenarios": live[contract] ?? [],
             "requiredUILayer": [RuntimeInteraction.taskReview, .chooseTask, .chooseDate, .taskEdit].contains(contract)]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
