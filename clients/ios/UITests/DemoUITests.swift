import XCTest

/// The demo fleet runs entirely in-app: what App Review and first-time users see.
final class DemoUITests: XCTestCase {
    func testDemoTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-argus.hub", ""]
        app.launch()
        app.buttons["Explore the demo"].tap()
        let card = app.descendants(matching: .any).matching(identifier: "session-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "demo sessions should appear")
        sleep(2)
        attach(app, "demo-1-command-center")

        card.tap(); sleep(2)
        app.tap()
        app.typeText("ls\n"); sleep(1)
        attach(app, "demo-2-terminal")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "·")).firstMatch.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap(); sleep(1)

        app.tabBars.buttons["Machines"].tap(); sleep(1)
        attach(app, "demo-3-machines")
        app.tabBars.buttons["Lab"].tap(); sleep(3)
        attach(app, "demo-4-lab")
        app.tabBars.buttons["Files"].tap(); sleep(2)
        attach(app, "demo-5-files")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
