import XCTest
import ArgusProtocol
@testable import UniversalTmuxMac

final class WrappedServiceTests: XCTestCase {
    func testAllWindowsReadOneSnapshotAndPreserveWindowBoundaries() throws {
        let now = try XCTUnwrap(WrappedStats.Event.parse("2026-10-05T12:00:00Z"))
        let events = [
            WrappedStats.Event(["kind": "utterance", "ts": "2026-10-04T12:00:00Z", "session": "one", "machineID": "host", "said": "Cool! Compare the results", "folder": "/project/one"]),
            WrappedStats.Event(["kind": "utterance", "ts": "2026-09-01T12:00:00Z", "session": "two", "machineID": "host", "said": "Review the earlier run", "folder": "/project/two"]),
            WrappedStats.Event(["kind": "status", "ts": "2026-10-04T12:00:01Z", "session": "one", "machineID": "host", "machine": "Worker", "to": "working"])
        ]
        var reads = 0
        let result = WrappedStats.compute(periods: [0, 7, 30, 90, 365], now: now) { reads += 1; return events }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual((result["0"]?["totals"] as? [String: Any])?["events"] as? Int, 3)
        XCTAssertEqual((result["7"]?["totals"] as? [String: Any])?["events"] as? Int, 2)
        XCTAssertEqual((result["30"]?["totals"] as? [String: Any])?["utterances"] as? Int, 1)
        XCTAssertEqual((result["90"]?["totals"] as? [String: Any])?["utterances"] as? Int, 2)
        XCTAssertEqual(events[0].saidCharacterCount, "Cool! Compare the results".count)
        XCTAssertEqual(events[0].sessionKey, "host|one")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testLongUnicodeMessagesRetainCountsAndFirstWordWithoutRepeatedFullSplits() throws {
        let now = try XCTUnwrap(WrappedStats.Event.parse("2026-10-05T12:00:00Z"))
        let long = "  Cool! " + String(repeating: "👩🏽‍💻 café results\n", count: 8000)
        let event = WrappedStats.Event(["kind": "utterance", "ts": "2026-10-04T12:00:00Z", "session": "one", "machineID": "host", "said": long])
        let result = WrappedStats.compute(events: [event], days: 7, now: now)
        XCTAssertEqual((result["totals"] as? [String: Any])?["chars"] as? Int, long.count)
        XCTAssertEqual((result["catchphrase"] as? [String: Any])?["word"] as? String, "cool!")
        let superlatives = result["superlatives"] as? [String: Any]
        XCTAssertEqual((superlatives?["longestMessage"] as? [String: Int])?["chars"], long.count)
    }

    @MainActor func testSlowDerivedJobCannotBlockIndependentPublicationOrStartTwice() async {
        let slow = WorkspaceRecurringJob(interval: 300), publisher = WorkspaceRecurringJob(interval: 30)
        let started = expectation(description: "derived computation started")
        let published = expectation(description: "journal published while computation is blocked")
        let finished = expectation(description: "computation released")
        var release: CheckedContinuation<Void, Never>?
        let now = Date()
        XCTAssertTrue(slow.runIfDue(now: now) {
            await withCheckedContinuation { continuation in release = continuation; started.fulfill() }
            finished.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(slow.runIfDue(now: now.addingTimeInterval(600)) { XCTFail("duplicate compute") })
        XCTAssertTrue(publisher.runIfDue(now: now) { published.fulfill() })
        await fulfillment(of: [published], timeout: 2)
        XCTAssertFalse(publisher.runIfDue(now: now.addingTimeInterval(10)) { XCTFail("interval bypass") })
        release?.resume()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testActualJournalStatisticsPerformanceWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["UT_WRAPPED_LIVE_CHECK"] == "1" else {
            throw XCTSkip("Opt-in read-only check of this installation's journal")
        }
        let started = Date()
        let result = WrappedStats.compute(periods: [0, 7, 30, 90, 365])
        let bytes = try JSONSerialization.data(withJSONObject: ["kind": "wrapped", "periods": result])
        let total = (result["0"]?["totals"] as? [String: Any])?["events"] as? Int ?? 0
        print("Wrapped real archive: \(total) events, \(bytes.count) bytes, \(Date().timeIntervalSince(started)) seconds")
        XCTAssertGreaterThan(total, 0)
        try bytes.write(to: URL(fileURLWithPath: "/tmp/argus-wrapped-live-stats.json"), options: .atomic)
    }
}
