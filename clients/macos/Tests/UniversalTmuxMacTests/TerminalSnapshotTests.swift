import AppKit
import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class TerminalSnapshotTests: XCTestCase {
    func testLowDataWarmPaneKeepsItsRenderedScreenAndLiveTransport() async throws {
        guard ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" else { throw XCTSkip("Opt-in native render") }
        _ = NSApplication.shared
        let harness = BrokerClientHarness()
        harness.onCreate = { $0.openDelay = 0.001 }
        let connection = PaneConn(url: harness.url, traceRef: "warm-render", client: harness.client)
        defer { connection.disconnect() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        container.addSubview(connection.view)
        connection.applyLayout()
        try await Task.sleep(for: .milliseconds(30))
        let socket = harness.transports[0]
        let screen = "\u{1b}[2J\u{1b}[H\u{1b}[36mARGUS / LOW DATA MODE\u{1b}[0m\r\n\r\n" +
            "Live terminal retained across a brief pane switch.\r\n" +
            "One connection. One screen snapshot.\r\n\r\n" +
            "\u{1b}[32muser@remote\u{1b}[0m ~/project $ ready"
        socket.emit(.data(Data([Op.snapshotBegin, 0])))
        socket.emit(.data(Data([Op.paneSize, 0, 0, 80, 0, 24])))
        socket.emit(.data(Data([Op.output, 0] + Array(screen.utf8))))
        socket.emit(.data(Data([Op.snapshotEnd, 0])))
        try await Task.sleep(for: .milliseconds(100))
        connection.setVisible(false)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: true)
        connection.setVisible(true)
        connection.applyNetworkPolicy(.init(lowData: true), appActive: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(harness.transports.count, 1)
        XCTAssertFalse(socket.invalidated)
        XCTAssertFalse(socket.sent.contains { $0.first == Op.requestSnapshot })
        let buffer = String(decoding: connection.view.getTerminal().getBufferAsData(), as: UTF8.self)
        XCTAssertTrue(buffer.contains("user@remote"))
        XCTAssertTrue(buffer.contains("One connection. One screen snapshot."))
        connection.view.displayIfNeeded()
        let bitmap = try XCTUnwrap(connection.view.bitmapImageRepForCachingDisplay(in: connection.view.bounds))
        connection.view.cacheDisplay(in: connection.view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/argus-low-data-warm.png"))
    }

    func testOrderedSnapshotsDoNotRequestAnotherSnapshotButLegacyAndLiveSizesDo() async throws {
        for ordered in [true, false] {
            let harness = BrokerClientHarness()
            harness.onCreate = { $0.openDelay = 0.001 }
            let connection = PaneConn(url: harness.url, traceRef: "snapshot-\(ordered)", client: harness.client)
            defer { connection.disconnect() }
            try await Task.sleep(for: .milliseconds(20))
            let socket = harness.transports[0]
            func frame(_ op: UInt8, _ payload: [UInt8] = []) {
                socket.emit(.data(Data([op, 0] + payload)))
            }
            if ordered { frame(Op.snapshotBegin) }
            frame(Op.paneSize, [0, 80, 0, 24])
            frame(Op.output, Array("\u{1b}[2J\u{1b}[Hsnapshot ready".utf8))
            if ordered { frame(Op.snapshotEnd) }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(connection.pinnedCols, 80)
            XCTAssertEqual(socket.sent.filter { $0.first == Op.requestSnapshot }.count, ordered ? 0 : 1)
            // A real live resize still needs exactly one settled redraw.
            frame(Op.paneSize, [0, 100, 0, 30])
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(connection.pinnedCols, 100)
            XCTAssertEqual(socket.sent.filter { $0.first == Op.requestSnapshot }.count, ordered ? 1 : 2)
        }
    }

    func testSnapshotArrivalCancelsAnAlreadyScheduledRepaint() async throws {
        let harness = BrokerClientHarness()
        harness.onCreate = { $0.openDelay = 0.001 }
        let connection = PaneConn(url: harness.url, traceRef: "snapshot-cancel", client: harness.client)
        defer { connection.disconnect() }
        try await Task.sleep(for: .milliseconds(20))
        let socket = harness.transports[0]
        socket.emit(.data(Data([Op.paneSize, 0, 0, 80, 0, 24])))
        try await Task.sleep(for: .milliseconds(30))
        socket.emit(.data(Data([Op.snapshotBegin, 0])))
        socket.emit(.data(Data([Op.paneSize, 0, 0, 80, 0, 24])))
        socket.emit(.data(Data([Op.snapshotEnd, 0])))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(socket.sent.allSatisfy { $0.first != Op.requestSnapshot })
    }

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
