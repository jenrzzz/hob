import XCTest

/// Signing in through the browser sheet, against a development hob (no OIDC
/// issuer, so its sign-in is the developer form). Needs HOB_URL and
/// HOB_SIGN_IN_AS (a person's principal name) in the scheme, and no key saved
/// on the simulator (`xcrun simctl keychain <udid> reset`); skips otherwise.
final class SignInUITests: XCTestCase {
    func testSignInThroughTheBrowserSheet() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let name = env["HOB_SIGN_IN_AS"] ?? ""
        try XCTSkipIf(name.isEmpty, "HOB_SIGN_IN_AS is not set")

        let app = XCUIApplication()
        app.launchEnvironment["HOB_URL"] = env["HOB_URL"] ?? "http://localhost:3400"
        app.launch()
        let signIn = app.buttons["Sign in"]
        try XCTSkipUnless(signIn.waitForExistence(timeout: 10), "already signed in: reset the simulator's keychain")
        signIn.tap()

        // "Hob" Wants to Use "localhost" to Sign In: a system prompt that
        // lives in SpringBoard or in the app, depending on the iOS version.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        tapSystemButton("Continue", in: [app, springboard])

        let web = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        tap(web.buttons["Sign in as a developer"], "login")
        let field = web.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(name)
        tap(web.buttons["Sign In"], "developer-form")
        XCTAssertTrue(web.staticTexts["Sign in the Hob app?"].waitForExistence(timeout: 15), "the confirm page")
        snapshot("confirm")
        tap(web.buttons["Sign in"], "confirm")

        // Signed in: notifications are asked for, then the inbox.
        tapSystemButton("Allow", in: [springboard, app], timeout: 10)
        XCTAssertTrue(app.navigationBars["Hob"].waitForExistence(timeout: 20), "landed in the inbox")
        snapshot("inbox")
    }

    private func tapSystemButton(_ label: String, in apps: [XCUIApplication], timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in apps {
                let button = candidate.alerts.buttons[label].exists ? candidate.alerts.buttons[label] : candidate.buttons[label]
                if button.exists && button.isHittable {
                    button.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func tap(_ element: XCUIElement, _ name: String) {
        let found = element.waitForExistence(timeout: 20)
        if !found { snapshot("\(name)-FAILED") }
        XCTAssertTrue(found, "\(name): \(element) not found")
        element.tap()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"], !dir.isEmpty {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
