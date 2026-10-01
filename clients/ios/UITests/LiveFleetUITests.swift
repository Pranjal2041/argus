import XCTest

/// End-to-end against a live fleet. Opt-in: set ARGUS_UITEST_HUB to a reachable
/// hub broker (a Mac's tailnet name or IP) in the test scheme's environment.
final class LiveFleetUITests: XCTestCase {
    func testOpenFirstSessionTypeAndSeeOutput() throws {
        guard let hub = ProcessInfo.processInfo.environment["ARGUS_UITEST_HUB"], !hub.isEmpty else {
            throw XCTSkip("ARGUS_UITEST_HUB not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-argus.hub", hub]
        app.launch()

        // Section headers are cells too; a session row is a navigation button.
        let firstCard = app.collectionViews.buttons.firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 30), "no sessions discovered via \(hub)")
        attach(app, "1-command-center")
        firstCard.tap()

        sleep(6)   // attach handshake: RESIZE → PANE_SIZE → snapshot
        attach(app, "2-terminal")
        app.tap()   // the terminal takes keyboard focus on tap, as on a phone
        let marker = "argus-ios-\(Int(Date().timeIntervalSince1970))"
        app.typeText("echo \(marker)\n")
        sleep(3)
        attach(app, "3-after-input")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "·")).firstMatch.exists,
                      "status line should show machine · cols×rows once connected")
    }

    /// Visits every top-level screen (read-only) and keeps a screenshot of each.
    func testTourScreens() throws {
        guard let hub = ProcessInfo.processInfo.environment["ARGUS_UITEST_HUB"], !hub.isEmpty else {
            throw XCTSkip("ARGUS_UITEST_HUB not set")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-argus.hub", hub]
        app.launch()
        // The first launch asks for notification permission.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.collectionViews.buttons.firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        attach(app, "tour-1-command-center")

        app.tabBars.buttons["Machines"].tap(); sleep(2)
        attach(app, "tour-2-machines")

        app.tabBars.buttons["Files"].tap(); sleep(4)
        attach(app, "tour-3-files")

        app.tabBars.buttons["Lab"].tap(); sleep(4)
        attach(app, "tour-4-lab")

        app.tabBars.buttons["More"].tap(); sleep(1)
        attach(app, "tour-5-more")
        app.buttons["Settings"].tap(); sleep(1)
        attach(app, "tour-6-settings")

        app.tabBars.buttons["Command"].tap(); sleep(1)
        app.collectionViews.buttons.firstMatch.tap(); sleep(6)
        app.buttons["Render output"].tap(); sleep(4)
        attach(app, "tour-7-render-output")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
