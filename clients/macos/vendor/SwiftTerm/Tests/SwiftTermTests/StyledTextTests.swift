import XCTest
@testable import SwiftTerm

final class StyledTextTests: XCTestCase {
    private final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    func testStyledSnapshotPreservesEmphasisColorSpacingAndTableGeometry() {
        let terminal = Terminal(delegate: Delegate(), options: TerminalOptions(
            cols: 24, rows: 8, scrollback: 100
        ))
        terminal.feed(text:
            "\u{1b}[1;34mHeading\u{1b}[0m\r\n" +
            "\u{1b}[31mleft\u{1b}[4Cright\u{1b}[0m\r\n" +
            "┌────┬────┐\r\n" +
            "│ A  │ B  │\r\n" +
            "└────┴────┘\r\n" +
            "\u{1b}]8;;https://example.com/docs\u{1b}\\docs\u{1b}]8;;\u{1b}\\"
        )

        let snapshot = terminal.getStyledText(maxVisualLines: 20)

        XCTAssertEqual(snapshot.lines.map(\.text).prefix(5), [
            "Heading",
            "left    right",
            "┌────┬────┐",
            "│ A  │ B  │",
            "└────┴────┘",
        ])
        XCTAssertTrue(snapshot.lines[0].runs[0].attribute.style.contains(.bold))
        XCTAssertEqual(snapshot.lines[0].runs[0].attribute.fg, .ansi256(code: 4))
        // Cursor-forward gaps are unwritten cells. A faithful extraction must
        // emit their visual spaces instead of collapsing the words together.
        XCTAssertEqual(snapshot.lines[1].runs.map(\.text).joined(), "left    right")
        XCTAssertEqual(snapshot.lines[5].runs[0].text, "docs")
        XCTAssertEqual(snapshot.lines[5].runs[0].link, "https://example.com/docs")
    }

    func testStyledSnapshotRecordsSoftWrapsAndBoundsVisualRows() {
        let terminal = Terminal(delegate: Delegate(), options: TerminalOptions(
            cols: 6, rows: 4, scrollback: 20
        ))
        terminal.feed(text: "1234567\r\nlast")

        let all = terminal.getStyledText(maxVisualLines: 20)
        XCTAssertEqual(all.lines[0].text, "123456")
        XCTAssertEqual(all.lines[1].text, "7")
        XCTAssertTrue(all.lines[1].isWrapped)

        let tail = terminal.getStyledText(maxVisualLines: 1)
        XCTAssertEqual(tail.lines.map(\.text), ["last"])
    }

    func testStyledSelectionUsesExclusiveEndAndRetainsAttributes() {
        let terminal = Terminal(delegate: Delegate(), options: TerminalOptions(
            cols: 20, rows: 3, scrollback: 20
        ))
        terminal.feed(text: "zero \u{1b}[3;4mstyled\u{1b}[0m tail")

        let selected = terminal.getStyledText(
            start: Position(col: 5, row: 0),
            end: Position(col: 11, row: 0)
        )

        XCTAssertEqual(selected.text, "styled")
        XCTAssertTrue(selected.lines[0].runs[0].attribute.style.contains(.italic))
        XCTAssertTrue(selected.lines[0].runs[0].attribute.style.contains(.underline))
    }
}
