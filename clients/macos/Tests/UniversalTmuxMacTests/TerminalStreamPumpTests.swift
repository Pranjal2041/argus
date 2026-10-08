import SwiftTerm
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class TerminalStreamPumpTests: XCTestCase {
    func testSlicesLargeOutputWithoutReorderingPaneSizeEvents() {
        var applied: [String] = []
        let pump = TerminalStreamPump(
            applyOutput: { applied.append(String(decoding: $0, as: UTF8.self)) },
            applySize: { applied.append("size:\($0)x\($1)") }
        )
        pump.enqueueOutput(Array("abcdefghijklmnopqrst".utf8))
        pump.enqueueSize(cols: 120, rows: 40)
        pump.enqueueOutput(Array("xyz".utf8))

        while pump.hasPendingEvents {
            pump.consumeOne(maxOutputBytes: 8)
        }

        XCTAssertEqual(applied, [
            "abcdefgh", "ijklmnop", "qrst", "size:120x40", "xyz",
        ])
    }

    func testStopDropsBacklogAndRejectsLaterOutput() {
        var output = ""
        let pump = TerminalStreamPump(
            applyOutput: { output += String(decoding: $0, as: UTF8.self) },
            applySize: { _, _ in }
        )
        pump.enqueueOutput(Array("before".utf8))
        pump.stop()
        pump.enqueueOutput(Array("after".utf8))

        XCTAssertFalse(pump.hasPendingEvents)
        XCTAssertFalse(pump.consumeOne(maxOutputBytes: 8))
        XCTAssertEqual(output, "")
    }

    func testSnapshotBoundariesStayOrderedAcrossOutputSlicesAndSizeChanges() {
        var events: [String] = []
        let pump = TerminalStreamPump(
            applyOutput: { events.append(String(decoding: $0, as: UTF8.self)) },
            applySize: { events.append("size:\($0)x\($1)") },
            applySnapshot: { events.append($0 ? "begin" : "end") }
        )
        pump.enqueueOutput(Array("live".utf8))
        pump.enqueueSnapshot(true)
        pump.enqueueSize(cols: 80, rows: 24)
        pump.enqueueOutput(Array("snapshot".utf8))
        pump.enqueueSnapshot(false)
        pump.enqueueOutput(Array("tail".utf8))
        while pump.hasPendingEvents { pump.consumeOne(maxOutputBytes: 4) }
        XCTAssertEqual(events, ["live", "begin", "size:80x24", "snap", "shot", "end", "tail"])
        pump.stop()
        pump.enqueueSnapshot(true)
        XCTAssertFalse(pump.hasPendingEvents)
    }

    func testHiddenPumpKeepsCompleteOrderedHistory() {
        var replayed: [UInt8] = []
        let pump = TerminalStreamPump(
            applyOutput: { replayed.append(contentsOf: $0) },
            applySize: { _, _ in }
        )
        let bytes = Array(String(repeating: "hidden-history\r\n", count: 2_000).utf8)

        pump.setVisible(false)
        pump.enqueueOutput(bytes)
        while pump.hasPendingEvents {
            pump.consumeOne(maxOutputBytes: 1_024)
        }

        XCTAssertEqual(replayed, bytes)
    }

    func testCoordinatorReplaysLargeSnapshotIncrementallyIntoSwiftTerm() async {
        let view = TerminalView(frame: .zero)
        view.resize(cols: 120, rows: 40)
        view.getTerminal().changeScrollback(100_000)
        let body = String(repeating: "snapshot row with enough text to exercise parsing\r\n", count: 12_000)
        let bytes = Array((body + "final-marker").utf8)
        let heartbeat = expectation(description: "main queue remained responsive")
        let finished = expectation(description: "snapshot drained")
        var applied = 0
        var slices = 0
        var replayed: [UInt8] = []
        let pump = TerminalStreamPump(
            applyOutput: { chunk in
                XCTAssertTrue(Thread.isMainThread)
                view.feed(byteArray: chunk)
                applied += chunk.count
                slices += 1
                replayed.append(contentsOf: chunk)
                if applied == bytes.count { finished.fulfill() }
            },
            applySize: { _, _ in }
        )

        pump.enqueueOutput(bytes)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            heartbeat.fulfill()
        }
        await fulfillment(of: [heartbeat, finished], timeout: 10, enforceOrder: true)

        XCTAssertEqual(applied, bytes.count)
        XCTAssertEqual(replayed, bytes)
        XCTAssertGreaterThan(slices, 10, "large frames must yield instead of becoming one blocking feed")
        let data = view.getTerminal().getBufferAsData()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("final-marker"), "terminal tail: \(text.suffix(160))")
    }
}
