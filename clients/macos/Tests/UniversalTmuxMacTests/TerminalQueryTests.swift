import AppKit
import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class TerminalQueryTests: XCTestCase {
    private struct Fixture: Decodable { let name: String; let live: String; let passive: String }
    private final class RecordingView: TerminalView {
        var replies: [UInt8] = []
        override func send(source: Terminal, data: ArraySlice<UInt8>) {
            replies.append(contentsOf: data)
        }
    }

    func testBrokerPassiveStreamsNeverAnswerButRawOwnerStillCan() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
            root.appendingPathComponent("internal/terminalquery/testdata/streams.json")))
        for fixture in fixtures {
            let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view // Offscreen; enables the normal display scheduler.
            view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
            view.resize(cols: 60, rows: 8)
            // The unfiltered/raw owner path must still answer. This also proves
            // the fixture exercised real response-producing emulator controls.
            view.feed(text: fixture.live)
            XCTAssertFalse(view.replies.isEmpty, fixture.name)
            view.replies.removeAll()
            let pump = TerminalStreamPump(applyOutput: { view.feed(byteArray: $0) },
                                          applySize: { view.resize(cols: $0, rows: $1) })
            // Reconnect and repeat the capture; slice controls across feeds.
            for _ in 0..<3 {
                pump.enqueueOutput(Array(fixture.passive.utf8))
                while pump.hasPendingEvents { pump.consumeOne(maxOutputBytes: 1) }
                XCTAssertTrue(view.replies.isEmpty, fixture.name)
                let terminal = view.getTerminal()
                let prompt = "Confirm action? [y/n]"
                let text = (0..<prompt.count).compactMap { terminal.getCharacter(col: $0, row: 0) }.map(String.init).joined()
                XCTAssertEqual(text, prompt, fixture.name)
            }
            if let directory = ProcessInfo.processInfo.environment["ARGUS_TERMINAL_QA_DIR"] {
                view.requestDisplayRefresh()
                try await Task.sleep(nanoseconds: 50_000_000)
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("queries-" + fixture.name + ".png"))
            }
            pump.stop()
        }
    }
}
