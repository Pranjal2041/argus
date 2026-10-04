import SwiftTerm
import XCTest
@testable import Argus

@MainActor
final class TerminalLayoutTests: XCTestCase {
    private func machine() -> Machine {
        Machine(id: "m", name: "m", os: "linux", httpBase: URL(string: "http://x.demo.invalid:8722")!, wsBase: URL(string: "ws://x.demo.invalid:8722")!)
    }

    /// The emulator must have exactly the broker's grid, and every column must
    /// be visible inside the screen (nothing clipped at the right edge).
    func testPinnedGridIsExactAndFullyVisible() {
        for width in [375.0, 390.0, 430.0] {
            let c = PinnedTerminalContainer(connection: TerminalConnection(machine: machine(), handle: "x"))
            c.frame = CGRect(x: 0, y: 0, width: width, height: 640)
            c.layoutIfNeeded()
            c.setPane(cols: 52, rows: 26)
            c.layoutIfNeeded()
            let t = c.terminal.getTerminal()
            XCTAssertEqual(t.cols, 52)
            XCTAssertEqual(t.rows, 26)
            XCTAssertLessThanOrEqual(c.terminal.frame.maxX, width + 0.01)
            // Every column SwiftTerm draws fits in the frame.
            let drawn = c.terminal.getOptimalFrameSize().width
            XCTAssertLessThanOrEqual(drawn, c.terminal.frame.width + 0.01, "last column would be clipped")
            XCTAssertGreaterThanOrEqual(c.terminal.frame.minX, 0)
        }
    }
}
