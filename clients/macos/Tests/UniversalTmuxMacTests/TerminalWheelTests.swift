import AppKit
import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class TerminalWheelTests: XCTestCase {
    private final class RecordingView: TerminalView {
        var sent: [UInt8] = []
        var remoteInput: (([UInt8]) -> Void)?
        override func send(source: Terminal, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
            remoteInput?(Array(data))
        }
    }

    private struct Fixture: Decodable {
        let name: String
        let tracking: Int
        let encoding: Int
        let ansi: String
    }

    private func fixtures() throws -> [Fixture] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
            root.appendingPathComponent("internal/session/testdata/mouse-modes.json")))
    }

    private func view(cols: Int = 40) -> RecordingView {
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.resize(cols: cols, rows: 8)
        view.allowMouseReporting = false // The normal Argus selection policy.
        view.allowMouseWheelReporting = true
        return view
    }

    private func wheel(_ delta: Int32, at point: CGPoint = CGPoint(x: 4, y: 230)) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        cg.location = point
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testSnapshotRestoresWheelRoutingAndEncodingWithoutEnablingClicks() throws {
        let view = view()
        // Each restored mode replaces a DIFFERENT previous mode. Repeating in
        // reverse catches stale modes when reconnecting from a TUI to a shell.
        let modes = try fixtures()
        for fixture in modes + modes.reversed() {
            view.feed(text: fixture.ansi)
            view.sent = []
            view.scrollWheel(with: try wheel(1))
            if fixture.tracking == 0 {
                XCTAssertTrue(view.sent.isEmpty, fixture.name)
            } else if fixture.encoding == 1006 {
                XCTAssertTrue(String(decoding: view.sent, as: UTF8.self).hasPrefix("\u{1b}[<64;"), fixture.name)
            } else {
                XCTAssertEqual(Array(view.sent.prefix(4)), [27, 91, 77, 96], fixture.name)
            }
            XCTAssertFalse(view.allowMouseReporting)
        }
    }

    func testLiveModeChangesRouteBothDirectionsAndDoNotSendHorizontalWheels() throws {
        let view = view()
        // Raw live VT is the other transport path (e.g. a ConPTY stream).
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1003;1006h")
        view.scrollWheel(with: try wheel(1))
        XCTAssertTrue(String(decoding: view.sent, as: UTF8.self).hasPrefix("\u{1b}[<64;"))
        view.sent = []
        view.scrollWheel(with: try wheel(-1))
        XCTAssertTrue(String(decoding: view.sent, as: UTF8.self).hasPrefix("\u{1b}[<65;"))
        view.sent = []
        view.scrollWheel(with: try wheel(0))
        XCTAssertTrue(view.sent.isEmpty)
        view.feed(text: "\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1049l")
        view.scrollWheel(with: try wheel(1))
        XCTAssertTrue(view.sent.isEmpty)
    }

    func testPlainShellScrollsLocalHistoryAndRemoteWheelDoesNot() throws {
        let view = view()
        view.feed(text: (0..<80).map { "history line \($0)\r\n" }.joined())
        view.scroll(toPosition: 1)
        let bottom = view.scrollPosition
        view.scrollWheel(with: try wheel(4))
        XCTAssertLessThan(view.scrollPosition, bottom)
        XCTAssertTrue(view.sent.isEmpty)
        let before = view.scrollPosition
        view.feed(text: "\u{1b}[?1000;1006h")
        view.scrollWheel(with: try wheel(1))
        XCTAssertEqual(view.scrollPosition, before)
        XCTAssertFalse(view.sent.isEmpty)
    }

    func testSelectionSurvivesOutputWhileWheelsGoToApplication() throws {
        let view = view()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1003;1006hselectable conversation")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 4, y: 230), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        view.mouseDown(with: click)
        let selected = view.getSelection()
        XCTAssertEqual(selected, "selectable")
        XCTAssertTrue(view.sent.isEmpty, "Selection must stay local")
        view.feed(text: "\u{1b}[4;1Hbackground redraw\r\n")
        XCTAssertEqual(view.getSelection(), selected)
        view.scrollWheel(with: try wheel(1))
        XCTAssertFalse(view.sent.isEmpty)
        XCTAssertTrue(view.selectionActive)
    }

    func testPointerMotionPolicyDoesNotDisableWheelReporting() throws {
        let view = view()
        view.feed(text: "\u{1b}[?1003;1006h")
        let move = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: NSPoint(x: 4, y: 230), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: move)
        XCTAssertTrue(view.sent.isEmpty)
        view.scrollWheel(with: try wheel(1))
        XCTAssertFalse(view.sent.isEmpty)
        view.sent = []
        view.allowMouseReporting = true
        view.mouseMoved(with: move)
        XCTAssertFalse(view.sent.isEmpty)
    }

    func testLegacyCoordinatesClampBeforeByteConversionOnWideTerminals() throws {
        let view = view(cols: 300)
        view.frame.size.width = 5000
        view.feed(text: "\u{1b}[?1000h")
        view.scrollWheel(with: try wheel(1, at: CGPoint(x: 4900, y: 230)))
        XCTAssertEqual(Array(view.sent.prefix(5)), [27, 91, 77, 96, 255])
    }

    func testWheelPreservesModifiersAndCanBeDisabledIndependently() throws {
        let view = view()
        view.feed(text: "\u{1b}[?1000;1006h")
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                      wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        // AppKit turns Shift+vertical-wheel into a horizontal wheel. Use the
        // remaining modifiers to exercise vertical-wheel protocol modifiers.
        cg.flags = [.maskAlternate, .maskControl]
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertTrue(String(decoding: view.sent, as: UTF8.self).hasPrefix("\u{1b}[<88;"))
        view.sent = []
        view.allowMouseWheelReporting = false
        view.allowMouseReporting = true
        view.scrollWheel(with: try wheel(1))
        XCTAssertTrue(view.sent.isEmpty)
    }

    func testWheelRendersEarlierContentInAlternateScreen() throws {
        let view = view()
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1003;1006h\u{1b}[HConversation item 20 (newest)")
        var item = 20
        view.remoteInput = { [weak view] bytes in
            guard let view, String(decoding: bytes, as: UTF8.self).hasPrefix("\u{1b}[<64;") else { return }
            item -= 1
            view.feed(text: "\u{1b}[H\u{1b}[2KConversation item \(item) (earlier)\r\nWheel reached the application; selection stays local.")
        }
        try capture(view, name: "wheel-before")
        view.scrollWheel(with: try wheel(1))
        XCTAssertEqual(item, 19)
        XCTAssertEqual(view.getTerminal().getCharacter(col: 18, row: 0), "1")
        try capture(view, name: "wheel-after")
    }

    private func capture(_ view: TerminalView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ARGUS_TERMINAL_QA_DIR"] else { return }
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
    }
}
