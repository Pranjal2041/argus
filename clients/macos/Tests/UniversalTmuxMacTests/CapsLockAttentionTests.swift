import XCTest
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
}
