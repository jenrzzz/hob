import XCTest

/// Against a running hob with something pending (see README, "Smoke test").
/// Skips, rather than fails, when the inbox is empty.
final class HobUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        app = XCUIApplication()
        app.launchEnvironment["HOB_URL"] = env["HOB_URL"] ?? "http://localhost:3400"
        app.launchEnvironment["HOB_KEY"] = env["HOB_KEY"] ?? ""
        app.launch()
    }

    func testPetitionIsDeniedWithAComment() throws {
        let row = app.cells.containing(.staticText, identifier: "pending").containing(.staticText, identifier: "petitions").firstMatch
        let present = row.waitForExistence(timeout: 15)
        if !present { snapshot("petition-skipped") }
        try XCTSkipUnless(present, "no pending petition to open")
        row.tap()
        XCTAssertTrue(app.staticTexts["Wants"].waitForExistence(timeout: 15), "the petition loaded")
        expect("Your decision", "petition")
        XCTAssertTrue(app.staticTexts["Steward"].exists)

        app.buttons["Deny"].firstMatch.tap()                     // the segmented picker
        comment("Not yet: nothing reads the calendar, and I want to see the spec first.")
        app.buttons["decide"].tap()
        expect("denied", "petition-denied")
        XCTAssertTrue(app.staticTexts["Decision"].exists, "decided by a person now")
    }

    func testRequestIsDeniedWithAComment() throws {
        let row = app.cells.containing(.staticText, identifier: "pending")
            .containing(NSPredicate(format: "elementType == %d AND label BEGINSWITH 'asks for'", XCUIElement.ElementType.staticText.rawValue)).firstMatch
        let present = row.waitForExistence(timeout: 15)
        if !present { snapshot("request-skipped") }
        try XCTSkipUnless(present, "no pending request to open")
        row.tap()
        XCTAssertTrue(app.staticTexts["Asks for"].waitForExistence(timeout: 15), "the request loaded")
        expect("Your decision", "request")

        comment("Not this week.")
        app.buttons["deny"].tap()
        expect("denied", "request-denied")
    }

    /// Waits for a text, then screenshots either way so a failure shows what was on screen.
    private func expect(_ text: String, _ name: String, timeout: TimeInterval = 15) {
        // A Form is lazy: what is below the fold does not exist yet, so scroll while looking.
        let form = app.collectionViews.firstMatch
        var found = app.staticTexts[text].firstMatch.waitForExistence(timeout: timeout)
        for _ in 0..<8 where !found {
            if form.exists { form.swipeUp() } else { app.swipeUp() }
            found = app.staticTexts[text].firstMatch.waitForExistence(timeout: 1)
        }
        for _ in 0..<8 where !found {
            if form.exists { form.swipeDown() } else { app.swipeDown() }
            found = app.staticTexts[text].firstMatch.waitForExistence(timeout: 1)
        }
        snapshot(found ? name : "\(name)-FAILED")
        XCTAssertTrue(found, "expected \"\(text)\" on screen")
    }

    private func comment(_ text: String) {
        let field = app.descendants(matching: .any)
            .matching(NSPredicate(format: "placeholderValue == 'Comment (kept as the rationale)'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    /// PNGs into SHOT_DIR (TEST_RUNNER_SHOT_DIR on the xcodebuild line), and the result bundle.
    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
