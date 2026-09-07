import AppKit
import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class TerminalSnapshotTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Geometry: Decodable { let Cols: Int; let Rows: Int }
        let name: String
        let snapshot: Geometry
        let ansi: String
        let nextX: Int
        let nextY: Int
    }

    func testBrokerSnapshotsPreserveInteractiveContinuation() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("internal/session/testdata/screen-snapshots.json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        for fixture in fixtures {
            let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
            view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
            view.resize(cols: fixture.snapshot.Cols, rows: fixture.snapshot.Rows)
            let terminal = view.getTerminal()
            let pump = TerminalStreamPump(
                applyOutput: { view.feed(byteArray: $0) },
                applySize: { view.resize(cols: $0, rows: $1) }
            )
            for _ in 0..<2 {
                pump.enqueueOutput(Array(fixture.ansi.utf8))
                pump.enqueueOutput(Array("Z".utf8))
                while pump.hasPendingEvents { pump.consumeOne(maxOutputBytes: 17) }
                XCTAssertEqual(terminal.getCharacter(col: fixture.nextX, row: fixture.nextY), "Z", fixture.name)
                let cursor = terminal.getCursorLocation()
                XCTAssertEqual(cursor.x, fixture.nextX + 1, fixture.name)
                XCTAssertEqual(cursor.y, fixture.nextY, fixture.name)
                if fixture.name == "history-blank-rows" {
                    XCTAssertEqual(terminal.getCharacter(col: 0, row: 0), "v")
                }
            }
            // Capture our own view, never the desktop / Screen Recording API.
            if let directory = ProcessInfo.processInfo.environment["ARGUS_TERMINAL_QA_DIR"] {
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(fixture.name + ".png"))
            }
            pump.stop()
        }
    }
}
