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
