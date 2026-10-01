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

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
