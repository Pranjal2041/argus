import XCTest
@testable import SwiftTerm

private final class TestTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class BufferResizeTests: XCTestCase {
    func testResizeDoesNotMaterializeUnusedScrollbackCapacity() {
        let buffer = Buffer(cols: 80, rows: 24, tabStopWidth: 8, scrollback: 100_000)
        buffer.fillViewportRows()

        XCTAssertEqual(buffer.lines.count, 24)
        XCTAssertEqual(buffer.lines.getArray().compactMap { $0 }.count, 24)

        buffer.resize(newCols: 200, newRows: 40)

        XCTAssertEqual(buffer.lines.count, 40)
        XCTAssertEqual(buffer.lines.getArray().compactMap { $0 }.count, 40)

        buffer.resize(newCols: 120, newRows: 30)

        XCTAssertEqual(buffer.lines.count, 30)
        // Shrinking retains the ten reusable row objects, but must not fill any
        // of the remaining ~100k capacity slots.
        XCTAssertEqual(buffer.lines.getArray().compactMap { $0 }.count, 40)
    }

    func testSynchronizedFrameSnapshotUsesContentSizeNotHistoryCapacity() {
        let delegate = TestTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(
            cols: 80, rows: 25, scrollback: 100_000
        ))

        XCTAssertEqual(terminal.buffer.lines.count, 25)
        XCTAssertEqual(terminal.buffer.lines.maxLength, 100_025)

        terminal.feed(text: "\u{1b}[?2026h")

        XCTAssertFalse(terminal.displayBuffer === terminal.buffer)
        XCTAssertEqual(terminal.displayBuffer.lines.count, 25)
        XCTAssertEqual(terminal.displayBuffer.lines.maxLength, 25)

        terminal.feed(text: "\u{1b}[?2026l")
        XCTAssertTrue(terminal.displayBuffer === terminal.buffer)
    }
}
