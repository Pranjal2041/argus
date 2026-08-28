import XCTest
@testable import UniversalTmuxMac

final class GoToPathInputTests: XCTestCase {
    func testJoinsWrappedUnixPathAndDropsIndentation() {
        XCTAssertEqual(
            GoToPathInput.singleLine("/Users/pranjal/Developer/\n  universal_tmux/README.md"),
            "/Users/pranjal/Developer/universal_tmux/README.md"
        )
    }

    func testJoinsWrappedWindowsPathWithCRLF() {
        XCTAssertEqual(
            GoToPathInput.singleLine("D:\\gym_anything\\\r\n  docs\\plan.md"),
            "D:\\gym_anything\\docs\\plan.md"
        )
    }

    func testRemovesMultipleLineBreakKindsAndBlankLines() {
        XCTAssertEqual(
            GoToPathInput.singleLine("/tmp/one\n\n two\u{2028}three"),
            "/tmp/onetwothree"
        )
    }

    func testLeavesOrdinarySingleLinePathUnchanged() {
        let path = "/Users/pranjal/My Project/report final.md"
        XCTAssertEqual(GoToPathInput.singleLine(path), path)
    }
}
