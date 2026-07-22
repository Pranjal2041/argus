import Foundation
import XCTest
@testable import UniversalTmuxMac

final class DashboardTabCleanupTests: XCTestCase {
    @MainActor
    func testLegacySavedTabsMigrateWithoutBeingTreatedAsStale() throws {
        let suiteName = "DashboardTabCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "tabs"
        let legacyPayload: [[String: Any]] = [[
            "url": "http://legacy.example",
            "host": "legacy-host",
            "title": "Legacy"
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacyPayload), forKey: key)
        let migrationStarted = Date()

        let model = DashboardsModel(restoreSavedTabs: true, startPolling: false,
                                    persistTabState: true, tabDefaults: defaults,
                                    tabsKey: key)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertGreaterThanOrEqual(model.tabs[0].lastViewedAt, migrationStarted)
        XCTAssertEqual(model.inactiveTabCount(), 0)
        let rewrittenData = try XCTUnwrap(defaults.data(forKey: key))
        let rewritten = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rewrittenData) as? [[String: Any]]
        )
        XCTAssertNotNil(rewritten.first?["lastViewedAt"])
    }

    @MainActor
    func testInactiveCleanupClosesOnlyOldBackgroundTabs() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldBackground = tab("old", viewedAt: now.addingTimeInterval(-90_000))
        let recentBackground = tab("recent", viewedAt: now.addingTimeInterval(-3_600))
        let oldActive = tab("active", viewedAt: now.addingTimeInterval(-200_000))
        let model = model(with: [oldBackground, recentBackground, oldActive], active: oldActive)

        XCTAssertEqual(model.inactiveTabCount(now: now), 1)
        XCTAssertEqual(model.closeInactiveTabs(now: now), 1)
        XCTAssertEqual(model.tabs.map(\.id), [recentBackground.id, oldActive.id])
        XCTAssertEqual(model.activeID, oldActive.id)
    }

    @MainActor
    func testSelectingAnOldTabRefreshesItsActivityTime() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let first = tab("first", viewedAt: now.addingTimeInterval(-100_000))
        let second = tab("second", viewedAt: now)
        let model = model(with: [first, second], active: second)

        model.select(first.id, at: now)

        XCTAssertEqual(model.activeID, first.id)
        XCTAssertEqual(first.lastViewedAt, now)
        XCTAssertEqual(model.inactiveTabCount(now: now), 0)
    }

    @MainActor
    func testDirectionalAndOtherTabCleanupUseTheChosenTabAsFallback() {
        let first = tab("first")
        let second = tab("second")
        let third = tab("third")
        let fourth = tab("fourth")
        let model = model(with: [first, second, third, fourth], active: first)

        XCTAssertEqual(model.closeTabs(toLeftOf: third.id), 2)
        XCTAssertEqual(model.tabs.map(\.id), [third.id, fourth.id])
        XCTAssertEqual(model.activeID, third.id)

        XCTAssertEqual(model.closeOtherTabs(keeping: fourth.id), 1)
        XCTAssertEqual(model.tabs.map(\.id), [fourth.id])
        XCTAssertEqual(model.activeID, fourth.id)
    }

    @MainActor
    func testClosingActiveTabSelectsItsNearestNeighbor() {
        let first = tab("first")
        let second = tab("second")
        let third = tab("third")
        let model = model(with: [first, second, third], active: second)

        XCTAssertEqual(model.close(second.id), 1)

        XCTAssertEqual(model.tabs.map(\.id), [first.id, third.id])
        XCTAssertEqual(model.activeID, third.id)
    }

    @MainActor
    private func model(with tabs: [DashboardTab], active: DashboardTab) -> DashboardsModel {
        let model = DashboardsModel(restoreSavedTabs: false, startPolling: false,
                                    persistTabState: false)
        model.tabs = tabs
        model.activeID = active.id
        return model
    }

    @MainActor
    private func tab(_ title: String, viewedAt: Date = Date()) -> DashboardTab {
        DashboardTab(title: title, host: "local",
                     url: URL(string: "http://\(title).example"),
                     lastViewedAt: viewedAt)
    }
}
