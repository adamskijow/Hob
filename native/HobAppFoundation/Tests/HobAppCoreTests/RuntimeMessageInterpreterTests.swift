// SPDX-License-Identifier: MIT
import Testing
@testable import HobAppCore

@Test func generatedClockCanonicalizesEquivalentModelRenderings() {
    #expect(RuntimeGeneratedClock.normalize("14:30") == "14:30")
    #expect(RuntimeGeneratedClock.normalize("2:30 PM") == "14:30")
    #expect(RuntimeGeneratedClock.normalize("2:30 p.m.") == "14:30")
    #expect(RuntimeGeneratedClock.normalize("230pm") == "14:30")
    #expect(RuntimeGeneratedClock.normalize("2 PM") == "14:00")
    #expect(RuntimeGeneratedClock.normalize("02:30") == "02:30")
    #expect(RuntimeGeneratedClock.normalize("230") == "02:30")
    #expect(RuntimeGeneratedClock.normalize("12am") == "00:00")
    #expect(RuntimeGeneratedClock.normalize("12pm") == "12:00")
}

@Test func generatedClockRejectsInvalidOrSemanticValues() {
    #expect(RuntimeGeneratedClock.normalize("") == nil)
    #expect(RuntimeGeneratedClock.normalize("none") == nil)
    #expect(RuntimeGeneratedClock.normalize("afternoon") == nil)
    #expect(RuntimeGeneratedClock.normalize("25:00") == nil)
    #expect(RuntimeGeneratedClock.normalize("2:75 PM") == nil)
    #expect(RuntimeGeneratedClock.normalize("14 PM") == nil)
}

@Test func generatedClockPreservesEvidenceAndLetsModelChooseMeridiem() {
    let message = "Meet Claude at 230, then the department at 330"
    #expect(RuntimeGeneratedClock.normalizeEvidence(
        "230",
        interpretation: "pm",
        in: message
    ) == "14:30")
    #expect(RuntimeGeneratedClock.normalizeEvidence(
        "330",
        interpretation: "pm",
        in: message
    ) == "15:30")
    #expect(RuntimeGeneratedClock.normalizeEvidence(
        "14:30",
        interpretation: "pm",
        in: "Meet at 14:30"
    ) == "14:30")
    #expect(RuntimeGeneratedClock.normalizeEvidence(
        "230",
        interpretation: "explicit",
        in: message
    ) == nil)
    #expect(RuntimeGeneratedClock.normalizeEvidence(
        "430",
        interpretation: "pm",
        in: message
    ) == nil)
}

@Test func durationRequiresQuotedEffortEvidence() {
    let message = "Finish taxes in about 90 minutes at 230"
    #expect(RuntimeConstraintEvidence.isSupportedDuration(
        "about 90 minutes",
        in: message
    ))
    #expect(!RuntimeConstraintEvidence.isSupportedDuration("230", in: message))
    #expect(!RuntimeConstraintEvidence.isSupportedDuration(
        "about 60 minutes",
        in: message
    ))
}

@Test func generatedActionsRejectAlternativeCopiesOfOneTask() {
    let alternatives = ["09:00", "11:00", "13:00"].map { time in
        RuntimeAction(type: "capture", task: "Take Willow for a haircut", time: time)
    }
    #expect(!RuntimeGeneratedActions.areDistinct(alternatives))
    #expect(RuntimeGeneratedActions.areDistinct([
        RuntimeAction(type: "capture", task: "Take Willow for a haircut", time: "14:30"),
        RuntimeAction(type: "capture", task: "Buy milk"),
    ]))
}
