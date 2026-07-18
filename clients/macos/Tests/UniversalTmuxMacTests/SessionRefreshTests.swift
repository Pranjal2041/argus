import XCTest
@testable import UniversalTmuxMac

final class SessionRefreshTests: XCTestCase {
    func testForegroundSnapshotReplacesOnlyVisibleSessions() {
        let current = [
            SessionInfo(name: "visible", activity: 100, state: "idle"),
            SessionInfo(name: "vanished", activity: 100),
            SessionInfo(name: "hidden", activity: 100, hidden: true),
            SessionInfo(name: "agent", activity: 100, agent: true),
        ]
        let fetched = [
            SessionInfo(name: "visible", activity: 200, state: "working"),
            SessionInfo(name: "new", activity: 200),
        ]

        let merged = mergeSessionSnapshot(
            current: current,
            fetched: fetched,
            scope: .foreground,
            machineID: "local",
            locallyHidden: []
        )
        XCTAssertEqual(merged.map(\.name), ["agent", "hidden", "new", "visible"])
        XCTAssertEqual(merged.first(where: { $0.name == "visible" })?.state, "working")
        XCTAssertFalse(merged.contains(where: { $0.name == "vanished" }))
    }

    func testFullSnapshotIsAuthoritativeForBackgroundSessions() {
        let current = [
            SessionInfo(name: "visible"),
            SessionInfo(name: "old-agent", agent: true),
            SessionInfo(name: "old-hidden", hidden: true),
        ]
        let merged = mergeSessionSnapshot(
            current: current,
            fetched: [SessionInfo(name: "visible")],
            scope: .all,
            machineID: "local",
            locallyHidden: []
        )
        XCTAssertEqual(merged.map(\.name), ["visible"])
    }

    func testContinuousActivityDoesNotChurnSnapshotEveryTwoSeconds() {
        var current: [SessionInfo] = []
        for i in 0..<15 {
            current.append(SessionInfo(name: "visible-\(i)", activity: 1_000, tmuxID: "$v\(i)"))
        }
        for i in 0..<12 {
            current.append(SessionInfo(name: "hidden-\(i)", activity: 1_000, hidden: true, tmuxID: "$h\(i)"))
        }
        for i in 0..<32 {
            current.append(SessionInfo(name: "agent-\(i)", activity: 1_000, agent: true, tmuxID: "$a\(i)"))
        }
        current.sort { $0.name < $1.name }
        let foreground = current.filter { !$0.agent && !$0.hidden }.map {
            var changed = $0
            changed.activity += 2
            return changed
        }

        let merged = mergeSessionSnapshot(
            current: current,
            fetched: foreground,
            scope: .foreground,
            machineID: "local",
            locallyHidden: []
        )
        XCTAssertEqual(merged, current)
    }

    func testActivityPublishesAfterThirtySecondsOrWithStateChange() {
        let old = SessionInfo(name: "work", activity: 1_000, state: "idle")
        let advanced = mergeSessionSnapshot(
            current: [old],
            fetched: [SessionInfo(name: "work", activity: 1_030, state: "idle")],
            scope: .all,
            machineID: "local",
            locallyHidden: []
        )
        XCTAssertEqual(advanced[0].activity, 1_030)

        let stateChanged = mergeSessionSnapshot(
            current: [old],
            fetched: [SessionInfo(name: "work", activity: 1_002, state: "working")],
            scope: .all,
            machineID: "local",
            locallyHidden: []
        )
        XCTAssertEqual(stateChanged[0].activity, 1_002)
        XCTAssertEqual(stateChanged[0].state, "working")
    }
}
