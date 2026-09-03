import XCTest
@testable import UniversalTmuxMac

final class CommandCenterCaptureTests: XCTestCase {
    func testStatusCommandPinsLunaHighAndKeepsConversationDurable() {
        let output = URL(fileURLWithPath: "/tmp/status.txt")
        let initial = CodexStatusCommand.initialArguments(finalMessageURL: output)
        let resumed = CodexStatusCommand.resumeArguments(
            sessionID: "019f630d-5663-7722-bc65-5fd298a497ec",
            finalMessageURL: output
        )

        XCTAssertTrue(initial.contains("gpt-5.6-luna"))
        XCTAssertTrue(initial.contains("model_reasoning_effort=\"high\""))
        XCTAssertTrue(initial.contains("read-only"))
        XCTAssertFalse(initial.contains("--ephemeral"))
        XCTAssertEqual(Array(resumed.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(resumed.contains("019f630d-5663-7722-bc65-5fd298a497ec"))
        XCTAssertTrue(resumed.contains("gpt-5.6-luna"))
    }

    func testStatusCommandParsesCodexSessionID() {
        let stream = #"{"type":"thread.started","thread_id":"019f630d-5663-7722-bc65-5fd298a497ec"}"#
            + "\n" + #"{"type":"turn.started"}"#
        XCTAssertEqual(
            CodexStatusCommand.sessionID(in: stream),
            "019f630d-5663-7722-bc65-5fd298a497ec"
        )
    }

    func testWorkingChromeOnlyCaptureIsTransient() {
        let chrome = """
        ◦                 •

        ›

          · ~\\spatial_bench                         Goal achieved (1h 12m)
        """
        XCTAssertTrue(ccCaptureLooksTransient(chrome, state: "working"))
    }

    func testSameSparseCaptureIsAllowedWhenSessionIsIdle() {
        XCTAssertFalse(ccCaptureLooksTransient("›", state: "idle"))
    }

    func testShortErrorIsNeverDiscarded() {
        XCTAssertFalse(ccCaptureLooksTransient("API Error", state: "working"))
    }

    func testSubstantiveWorkingCaptureIsAccepted() {
        let output = "R8 progressed to 28 actions and 29 frames; verifier is still running."
        XCTAssertFalse(ccCaptureLooksTransient(output, state: "working"))
    }

    func testLiveWorkingSignalOverridesQuietModelLabels() {
        for label in ["idle", "look", "milestone"] {
            let generated = AgentStatus(label: label, oneLiner: "Tests completed.",
                                        lookAtThis: nil, updatedAt: Date())
            let reconciled = ccReconcileLiveState(generated, state: "working")
            XCTAssertEqual(reconciled.label, "working")
            XCTAssertEqual(reconciled.oneLiner, generated.oneLiner)
        }
    }

    func testLiveWorkingSignalDoesNotSuppressAttentionLabels() {
        for label in ["needs-decision", "stuck", "drifting", "no-progress"] {
            let generated = AgentStatus(label: label, oneLiner: "Action is needed.",
                                        lookAtThis: nil, updatedAt: Date())
            XCTAssertEqual(ccReconcileLiveState(generated, state: "working").label, label)
        }
    }

    func testStaleWorkingStateDoesNotOverrideCurrentIdle() {
        let generated = AgentStatus(label: "idle", oneLiner: "Done.",
                                    lookAtThis: nil, updatedAt: Date())
        XCTAssertEqual(ccReconcileLiveState(generated, state: "idle").label, "idle")
    }
}
