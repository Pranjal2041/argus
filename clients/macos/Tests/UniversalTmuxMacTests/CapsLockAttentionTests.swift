import XCTest
import IOKit.hidsystem
@testable import UniversalTmuxMac

final class CapsLockAttentionTests: XCTestCase {
    func testEnteringNeedsYouPulsesOnlyOnceForTheSameItem() {
        var state = AttentionBlinkState()

        XCTAssertEqual(state.update(ids: ["agent-a"], enabled: true), .pulse)
        XCTAssertEqual(state.update(ids: ["agent-a"], enabled: true), .none)
    }

    func testAnotherAgentEnteringProducesANewImmediatePulse() {
        var state = AttentionBlinkState()
        _ = state.update(ids: ["agent-a"], enabled: true)

        XCTAssertEqual(state.update(ids: ["agent-a", "agent-b"], enabled: true), .pulse)
    }

    func testPartialResolutionKeepsReminderStateWithoutRepulsing() {
        var state = AttentionBlinkState()
        _ = state.update(ids: ["agent-a", "agent-b"], enabled: true)

        XCTAssertEqual(state.update(ids: ["agent-b"], enabled: true), .none)
        XCTAssertEqual(state.ids, ["agent-b"])
        XCTAssertTrue(state.enabled)
    }

    func testResolvingAllAttentionStopsBlinking() {
        var state = AttentionBlinkState()
        _ = state.update(ids: ["agent-a"], enabled: true)

        XCTAssertEqual(state.update(ids: [], enabled: true), .stop)
    }

    func testToggleCanEnableAndDisableWhileAttentionIsPending() {
        var state = AttentionBlinkState()
        XCTAssertEqual(state.update(ids: ["agent-a"], enabled: false), .none)
        XCTAssertEqual(state.update(ids: ["agent-a"], enabled: true), .pulse)
        XCTAssertEqual(state.update(ids: ["agent-a"], enabled: false), .stop)
    }

    func testCompletionCannotInterruptNeedsYou() {
        XCTAssertFalse(shouldStartCompletionPulse(
            enabled: true, transitionIDs: ["agent-a"], needsYouPending: true))
        XCTAssertTrue(shouldStartCompletionPulse(
            enabled: true, transitionIDs: ["agent-a"], needsYouPending: false))
    }

    func testHIDAccessIsNotReportedAsHardwareCompatibility() {
        XCTAssertEqual(capsLockInputAccess(from: kIOHIDAccessTypeGranted), .granted)
        XCTAssertEqual(capsLockInputAccess(from: kIOHIDAccessTypeDenied), .denied)
        XCTAssertEqual(capsLockInputAccess(from: kIOHIDAccessTypeUnknown), .notDetermined)
    }

    func testVisibleWorkingToIdleIsACompletion() {
        XCTAssertTrue(isVisibleWorkingToIdleTransition(
            previous: "working", current: "idle",
            isAgentSession: false, isHidden: false, isBacklogged: false))
    }

    func testCompletionRequiresTheExactWorkingToIdleEdge() {
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: nil, current: "idle",
            isAgentSession: false, isHidden: false, isBacklogged: false))
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: "working", current: "waiting",
            isAgentSession: false, isHidden: false, isBacklogged: false))
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: "idle", current: "idle",
            isAgentSession: false, isHidden: false, isBacklogged: false))
    }

    func testNonUserFacingSessionsStaySilentOnCompletion() {
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: "working", current: "idle",
            isAgentSession: true, isHidden: false, isBacklogged: false))
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: "working", current: "idle",
            isAgentSession: false, isHidden: true, isBacklogged: false))
        XCTAssertFalse(isVisibleWorkingToIdleTransition(
            previous: "working", current: "idle",
            isAgentSession: false, isHidden: false, isBacklogged: true))
    }
}
