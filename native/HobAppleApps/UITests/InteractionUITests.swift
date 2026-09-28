// SPDX-License-Identifier: MIT
import XCTest

final class InteractionUITests: XCTestCase {
  @MainActor func testSettingsStayOpenWhileChangingControlsAndRunningActions() {
    let app = launch("upcoming-empty")
    let settings = app.buttons["Connections and setup"]
    XCTAssertTrue(settings.waitForExistence(timeout: 10))
    settings.tap()

    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    let nightly = app.switches["Nightly “What got done?”"]
    XCTAssertTrue(nightly.exists)
    nightly.tap()
    XCTAssertTrue(app.navigationBars["Settings"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Persistent Hob settings"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    app.swipeUp()
    let sync = app.buttons["Sync now"]
    XCTAssertTrue(sync.waitForExistence(timeout: 10))
    sync.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
  }

  @MainActor func testSetupShowsOptionalTimedNightlyCheckIn() {
    let app = launch("setup-check-ins")
    XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 10))
    app.buttons["Continue"].tap()

    XCTAssertTrue(app.switches["Morning digest"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.switches["Nightly “What got done?”"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["7:00 AM"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["8:00 PM"].exists)
  }

  @MainActor func testUpcomingGroupsHistoryAndManualDateClearing() {
    let app = launch("upcoming")
    app.tabBars.buttons["Upcoming"].tap()
    XCTAssertTrue(app.staticTexts["Tomorrow"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["This week"].exists)
    XCTAssertTrue(app.staticTexts["Later"].exists)
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "2:30 PM")).firstMatch
        .exists)
    XCTAssertFalse(app.staticTexts["Finished errand"].exists)
    XCTAssertFalse(app.staticTexts["Buy soap"].exists)
    XCTAssertFalse(app.buttons["Plan on-deck work"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Upcoming grouped reminders"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["hob.upcoming.tomorrow"].tap()
    XCTAssertTrue(app.switches["hob.edit.hasDate"].waitForExistence(timeout: 10))
    app.switches["hob.edit.hasDate"].tap()
    app.buttons["Close"].tap()
    XCTAssertTrue(app.buttons["hob.history"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["hob.upcoming.tomorrow"].exists)
    app.buttons["hob.history"].tap()
    XCTAssertTrue(app.staticTexts["Finished errand"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Missed appointment"].exists)
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Book haircut"].waitForExistence(timeout: 10))
    app.tabBars.buttons["Upcoming"].tap()
    XCTAssertFalse(app.buttons["hob.upcoming.tomorrow"].exists)
  }

  @MainActor func testUpcomingEmptyStateHasNoSchedulePrompt() {
    let app = launch("upcoming-empty")
    app.tabBars.buttons["Upcoming"].tap()
    XCTAssertTrue(app.staticTexts["Nothing coming up"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["hob.history"].exists)
    XCTAssertFalse(app.staticTexts["No schedule yet"].exists)
    XCTAssertFalse(app.buttons["Plan on-deck work"].exists)
  }
  @MainActor private func launch(_ scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["HOB_UI_TEST_SCENARIO"] = scenario
    app.launchEnvironment["HOB_UI_TEST_SESSION"] = UUID().uuidString
    app.launch()
    return app
  }
  @MainActor private func send(_ text: String, app: XCUIApplication) {
    let input = app.descendants(matching: .any)["hob.composer"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    if !input.isHittable { app.swipeUp() }
    input.tap()
    input.typeText(text)
    app.buttons["hob.send"].tap()
  }
  @MainActor func testOfferedReviewAnswerUsesVisibleQuestion() {
    let app = launch("review")
    let question = app.staticTexts["hob.question.taskReview"]
    XCTAssertTrue(question.waitForExistence(timeout: 10))
    XCTAssertTrue(question.label.contains("stays"))
    send("Stays", app: app)
    XCTAssertTrue(app.staticTexts["Keeping it on deck."].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Added “Stays”"].exists)
  }

  @MainActor func testOngoingItemStaysOnTodayAndSuppressesFutureReview() {
    let app = launch("ongoing")
    XCTAssertTrue(app.staticTexts["hob.question.taskReview"].waitForExistence(timeout: 10))
    app.staticTexts["Take my morning pill"].firstMatch.tap()
    let ongoing = app.switches["hob.edit.keepIndefinitely"]
    XCTAssertTrue(ongoing.waitForExistence(timeout: 10))
    XCTAssertEqual(ongoing.value as? String, "0")
    ongoing.tap()
    XCTAssertFalse(app.buttons["hob.edit.save"].exists)
    app.buttons["Close"].tap()
    XCTAssertTrue(app.staticTexts["Take my morning pill"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.images["hob.today.ongoing.a1"].exists)
    XCTAssertFalse(app.staticTexts["hob.question.taskReview"].exists)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["Take my morning pill"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.images["hob.today.ongoing.a1"].exists)
    XCTAssertFalse(app.staticTexts["hob.question.taskReview"].exists)
    app.staticTexts["Take my morning pill"].firstMatch.tap()
    XCTAssertEqual(app.switches["hob.edit.keepIndefinitely"].value as? String, "1")
  }
  @MainActor func testDateAnswerSurvivesSocialReplyAndRelaunch() {
    let app = launch("review")
    XCTAssertTrue(app.staticTexts["hob.question.taskReview"].waitForExistence(timeout: 10))
    send("Move", app: app)
    XCTAssertTrue(app.staticTexts["When should I move it to?"].waitForExistence(timeout: 10))
    send("Thanks", app: app)
    XCTAssertTrue(app.staticTexts["Anytime."].waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.staticTexts["When should I move it to?"].waitForExistence(timeout: 10))
    send("Friday", app: app)
    XCTAssertTrue(app.staticTexts["Moved: Plan picnic."].waitForExistence(timeout: 10))
  }
  @MainActor func testTaskChoiceUsesNamedCandidate() {
    let app = launch("chooseTask")
    send("The call is done", app: app)
    XCTAssertTrue(
      app.staticTexts["Do you mean Call Alex or Call Sam?"].waitForExistence(timeout: 10))
    send("Call Alex", app: app)
    XCTAssertTrue(app.staticTexts["Done: Call Alex."].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Call Sam"].exists)
  }
}
