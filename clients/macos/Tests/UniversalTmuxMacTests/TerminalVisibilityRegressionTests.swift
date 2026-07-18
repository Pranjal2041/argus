import XCTest
@testable import UniversalTmuxMac

final class TerminalVisibilityRegressionTests: XCTestCase {
    func testRepeatedVisibleViewUpdatesAreNotRevealEvents() {
        var state = PaneVisibilityState(initiallyVisible: true)

        for _ in 0..<20 {
            XCTAssertEqual(state.update(true), .unchanged)
        }
        XCTAssertTrue(state.isVisible)
    }

    func testOnlyARealHiddenToVisibleEdgeRequestsRevealWork() {
        var state = PaneVisibilityState(initiallyVisible: true)

        XCTAssertEqual(state.update(false), .becameHidden)
        XCTAssertEqual(state.update(false), .unchanged)
        XCTAssertEqual(state.update(true), .becameVisible)
        XCTAssertEqual(state.update(true), .unchanged)
    }

    func testRepeatedVisiblePaneUpdatesDoNotRestartTheSocket() throws {
        let ref = "test/repeated-visible-\(UUID().uuidString)"
        let connection = PaneConn(
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:1/ws?session=diagnostic")),
            traceRef: ref
        )

        for _ in 0..<20 { connection.setVisible(true) }
        connection.disconnect()
        TerminalConnectionTrace.flush()

        let data = try Data(contentsOf: TerminalConnectionTrace.logURL)
        let events = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let bytes = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }.filter { $0["ref"] as? String == ref }

        XCTAssertEqual(events.filter { $0["event"] as? String == "broker.dial_started" }.count, 1)
        XCTAssertEqual(events.filter { $0["event"] as? String == "broker.nudge" }.count, 0)
    }
}
