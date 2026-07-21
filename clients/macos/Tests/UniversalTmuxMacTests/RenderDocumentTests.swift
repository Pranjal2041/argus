import AppKit
import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class RenderDocumentTests: XCTestCase {
    func testDocumentCarriesResolvedTerminalStylesAndExactTableRows() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        view.nativeBackgroundColor = NSColor(hex: "#12141A")
        view.nativeForegroundColor = NSColor(hex: "#E7E9EE")
        let terminal = view.getTerminal()
        terminal.resize(cols: 30, rows: 6)
        terminal.feed(text:
            "\u{1b}[1;38;2;10;120;240;48;2;30;40;50mHeading\u{1b}[0m\r\n" +
            "┌──────┬──────┐\r\n" +
            "│ left │ right│\r\n" +
            "└──────┴──────┘\r\n" +
            "\u{1b}[4;58;2;200;30;40munder\u{1b}[0m"
        )

        let styled = terminal.getStyledText(maxVisualLines: 20)
        let document = RenderDocument(source: "# Heading", styled: styled, view: view,
                                      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

        XCTAssertEqual(document.terminal.background, "#12141A")
        XCTAssertEqual(document.terminal.fontFamily, view.font.familyName)
        XCTAssertEqual(document.terminal.lines[0].runs.map(\.text).joined(), "Heading")
        XCTAssertEqual(document.terminal.lines[1].runs.map(\.text).joined(), "┌──────┬──────┐")
        let headingStyle = document.terminal.styles[document.terminal.lines[0].runs[0].style]
        XCTAssertEqual(headingStyle.foreground, "#0A78F0")
        XCTAssertEqual(headingStyle.background, "#1E2832")
        XCTAssertTrue(headingStyle.bold)
        let underlineStyle = document.terminal.styles[document.terminal.lines[4].runs[0].style]
        XCTAssertEqual(underlineStyle.underline, "solid")
        XCTAssertEqual(underlineStyle.underlineColor, "#C81E28")

        let encoded = try JSONEncoder().encode(document)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["terminal"])
        XCTAssertEqual(object["source"] as? String, "# Heading")
        XCTAssertEqual(object["sourceOrigin"] as? String, "terminal")
    }

    func testPlainSourceCleanupDoesNotAlterRichTerminalRows() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let terminal = view.getTerminal()
        terminal.resize(cols: 20, rows: 3)
        terminal.feed(text: "⏺ **answer**")

        let rawStyled = terminal.getStyledText(maxVisualLines: 10)
        let source = RenderExtract.clean("⏺ **answer**")
        let document = RenderDocument(source: source, styled: rawStyled, view: view)

        XCTAssertEqual(document.source, "**answer**")
        XCTAssertEqual(document.sourceOrigin, "terminal")
        XCTAssertEqual(document.terminal.lines[0].runs.map(\.text).joined(), "⏺ **answer**")
    }

    func testLogicalSourceJoinsOnlySoftWrappedRows() {
        let styled = StyledTerminalText(columns: 12, lines: [
            StyledTerminalLine(
                runs: [StyledTerminalRun(text: "wrapped   ", attribute: .empty, link: nil)],
                isWrapped: false
            ),
            StyledTerminalLine(
                runs: [StyledTerminalRun(text: "line", attribute: .empty, link: nil)],
                isWrapped: true
            ),
            StyledTerminalLine(runs: [], isWrapped: false),
            StyledTerminalLine(
                runs: [StyledTerminalRun(text: "next", attribute: .empty, link: nil)],
                isWrapped: false
            ),
        ])

        XCTAssertEqual(RenderExtract.joiningWrappedRows(styled), "wrappedline\n\nnext")
    }

    func testRenderCaptureIncludesContentOlderThanFourHundredRows() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let terminal = view.getTerminal()
        terminal.changeScrollback(1_000)
        terminal.resize(cols: 20, rows: 5)
        terminal.feed(text: (0..<650).map { "point-\($0)" }.joined(separator: "\r\n"))

        let styled = RenderCapture.completeTerminal(terminal)

        XCTAssertEqual(styled.lines.count, 650)
        XCTAssertEqual(styled.lines.first?.text, "point-0")
        XCTAssertEqual(styled.lines.last?.text, "point-649")
    }
}
