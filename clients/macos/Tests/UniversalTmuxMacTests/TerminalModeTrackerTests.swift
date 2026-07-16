import XCTest
@testable import UniversalTmuxMac

final class TerminalModeTrackerTests: XCTestCase {
    func testRestoresSetAndResetModesAcrossSplitFrames() {
        let tracker = DECPrivateModeTracker()
        tracker.feed(Array("\u{1b}[?2004h\u{1b}[?10".utf8))
        tracker.feed(Array("00;1006h\u{1b}[?1000l".utf8))

        XCTAssertEqual(
            String(decoding: tracker.restorationBytes(), as: UTF8.self),
            "\u{1b}[?1006;2004h\u{1b}[?1000l"
        )
    }

    func testResetClearsKnownModesAndSnapshotOwnedModesAreOmitted() {
        let tracker = DECPrivateModeTracker()
        tracker.feed(Array("\u{1b}[?25l\u{1b}[?2004h\u{1b}[?1049h\u{1b}[?2026h\u{1b}c".utf8))

        XCTAssertEqual(
            String(decoding: tracker.restorationBytes(), as: UTF8.self),
            "\u{1b}[?25h\u{1b}[?2004l"
        )
    }
}
