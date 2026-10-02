import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class InteractiveLoginProcessTests: XCTestCase {
    func testFragmentedProtocolRepliesNeverContainApplicationCommands() {
        var terminal = LoginTerminalProtocol()
        XCTAssertTrue(terminal.receive(Data("regular output\u{1b}[".utf8)).isEmpty)
        XCTAssertEqual(String(decoding: terminal.receive(Data("6n\u{1b}[?u\u{1b}[c".utf8)), as: UTF8.self), "\u{1b}[1;1R\u{1b}[?0u\u{1b}[?1;2c")
        XCTAssertTrue(terminal.receive(Data("\u{1b}[?2004h\u{1b}[?2026h\u{1b}]8;;https://fixture.test\u{1b}\\".utf8)).isEmpty)
        XCTAssertEqual(terminal.receive(Data("\u{1b}[5n".utf8)), Data("\u{1b}[0n".utf8))
    }

    func testOwnedPromptReceivesCodeOverPrivateTTYWithoutEchoOrGlobalInput() async throws {
        let process = InteractiveLoginProcess(executable: "/bin/sh", arguments: ["-c", "test -t 0 || exit 2; printf 'Ready\\n'; IFS= read -r code; test \"$code\" = 'fixture-code' || exit 3; printf 'Accepted\\n'"],
            environment: ["HOME": NSTemporaryDirectory()], timeout: 5)
        try process.start()
        var output = "", sent = false, status: Int32?
        for try await event in process.events {
            switch event {
            case .output(let data):
                output += String(decoding: data, as: UTF8.self)
                if !sent && output.contains("Ready") { sent = true; try process.sendCode("fixture-code") }
            case .exited(let code): status = code
            }
        }
        await process.close()
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains("Accepted"))
        XCTAssertFalse(output.contains("fixture-code"))
    }

    func testCodesCannotInjectAdditionalInputAndCancellationStopsOwnedChild() async throws {
        let process = InteractiveLoginProcess(executable: "/bin/sh", arguments: ["-c", "printf 'Ready\\n'; sleep 30"],
            environment: ["HOME": NSTemporaryDirectory()], timeout: 5)
        for invalid in ["a\nb", "a\rb", "\u{1b}[A", "", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try process.sendCode(invalid))
        }
        try process.start()
        let start = Date()
        do {
            for try await event in process.events {
                if case .output = event { process.cancel() }
            }
            XCTFail("Cancellation must not look like successful authentication")
        } catch is CancellationError { }
        await process.close()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
