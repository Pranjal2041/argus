import XCTest
@testable import Argus

@MainActor
final class PlatformTests: XCTestCase {
    private let mac = Machine(id: "hub:mac", name: "mac", os: "darwin",
                              httpBase: URL(string: "http://100.64.0.1:8722")!, wsBase: URL(string: "ws://100.64.0.1:8722")!)

    private func record(_ input: String, screen: [String], wait: Double = 0) async throws -> [[String: Any]] {
        var events: [[String: Any]] = []
        let r = UtteranceRecorder(machine: mac, session: "train", screenTail: { screen }) { events.append($0) }
        r.feed(ArraySlice(Array(input.utf8)))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return events
    }

    func testJournalRecordsEchoedTextKeysAndContext() async throws {
        let events = try await record("ls -la\u{1b}[A\r", screen: ["$ ls -la"], wait: 1.8)
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e["kind"] as? String, "utterance")
        XCTAssertEqual(e["src"] as? String, "phone")
        XCTAssertEqual(e["said"] as? String, "ls -la")
        XCTAssertEqual(e["keys"] as? String, "↑⏎")
        XCTAssertEqual(e["machineID"] as? String, "hub:mac")
        XCTAssertNotNil(e["saw"] as? [String])
        XCTAssertTrue((e["ts"] as? String)?.hasSuffix("Z") == true)
    }

    func testJournalRedactsTextThatNeverEchoes() async throws {
        let events = try await record("hunter2-secret\r", screen: ["Password:"], wait: 8.5)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0]["said"])
        XCTAssertEqual(events[0]["redacted"] as? Bool, true)
        XCTAssertEqual(events[0]["saidChars"] as? Int, 14)
    }

    func testJournalPasteKeepsNewlinesAndBackspaceEdits() async throws {
        let events = try await record("\u{1b}[200~a\rb\u{1b}[201~x\u{7f}\r", screen: ["a", "b"], wait: 1.8)
        XCTAssertEqual(events.first?["said"] as? String, "a\nb")
        XCTAssertEqual(events.first?["keys"] as? String, "⏎")
    }

    func testWandbStoreKeepsFirstSeenAndRealNames() {
        let key = "test-\(UUID().uuidString)"
        let url = URL(string: "https://wandb.ai/team/proj/runs/abc123")!
        let first = WandbStore.merge([WandbRun(url: url, runId: "abc123", label: "brave-run-7",
                                               discoveredAt: Date(timeIntervalSinceNow: -60))], key: key)
        XCTAssertEqual(first.first?.label, "brave-run-7")
        let again = WandbStore.merge([WandbRun(url: url, runId: "abc123", label: "abc123")], key: key)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.label, "brave-run-7", "a bare id never replaces a real name")
        XCTAssertLessThan(again.first!.discoveredAt, Date(timeIntervalSinceNow: -30), "first-seen time is kept")
    }

    func testPathMathHandlesUnixAndWindows() {
        XCTAssertEqual(PathMath.parent("/a/b", sep: "/"), "/a")
        XCTAssertEqual(PathMath.parent("/a", sep: "/"), "/")
        XCTAssertEqual(PathMath.parent("/", sep: "/"), "")
        XCTAssertEqual(PathMath.parent("C:\\a", sep: "\\"), "C:\\")
        XCTAssertEqual(PathMath.parent("C:\\", sep: "\\"), "")
        XCTAssertEqual(PathMath.join("/a/", "b", sep: "/"), "/a/b")
        XCTAssertEqual(PathMath.join("C:\\x", "y", sep: "\\"), "C:\\x\\y")
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind.of("plot.PNG", size: 10), .image)
        XCTAssertEqual(FileKind.of("paper.pdf", size: 10), .pdf)
        XCTAssertEqual(FileKind.of("README.md", size: 10), .markdown)
        XCTAssertEqual(FileKind.of("train.py", size: 10), .text)
        XCTAssertEqual(FileKind.of("model.safetensors", size: 10), .other)
        XCTAssertEqual(FileKind.of("huge.log", size: 6_000_000), .other)
    }

    func testMachineNamesNormalizeAcrossForms() {
        XCTAssertEqual(FleetStore.normalizedHost("ut-babel-s9-20.tailnet.ts.net"), "babel-s9-20")
        XCTAssertEqual(FleetStore.normalizedHost("babel-s9-20"), "babel-s9-20")
        XCTAssertEqual(FleetStore.normalizedHost("ip-172-31-87-156.ec2.internal"), "ip-172-31-87-156")
    }

    func testThemesMirrorAndroid() {
        XCTAssertEqual(ThemePalette.all.count, 13)
        XCTAssertEqual(ThemePalette.argus.id, "argus")
        XCTAssertTrue(ThemePalette.all.allSatisfy { $0.ansi.count == 16 })
        XCTAssertEqual(ThemePalette.all.filter(\.isLight).map(\.id), ["solarized-light", "github-light"])
    }
}

extension FileKind: Equatable {}
