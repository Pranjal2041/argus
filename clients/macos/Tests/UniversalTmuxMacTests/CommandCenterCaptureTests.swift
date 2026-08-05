import XCTest
@testable import UniversalTmuxMac

final class CommandCenterCaptureTests: XCTestCase {
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
