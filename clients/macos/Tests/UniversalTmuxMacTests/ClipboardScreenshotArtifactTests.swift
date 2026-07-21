import XCTest
@testable import UniversalTmuxMac

final class ClipboardScreenshotArtifactTests: XCTestCase {
    func testInactiveClipboardChangeIsConsumedAndCannotLeakIntoForeground() {
        var gate = ForegroundClipboardChangeGate(changeCount: 40)

        XCTAssertFalse(gate.consume(changeCount: 41, eligible: false))
        XCTAssertFalse(gate.consume(changeCount: 41, eligible: true))
        XCTAssertEqual(gate.observedChangeCount, 41)
    }

    func testActivationBaselineIgnoresEverythingCopiedWhileAway() {
        var gate = ForegroundClipboardChangeGate(changeCount: 10)

        gate.reset(changeCount: 27)

        XCTAssertFalse(gate.consume(changeCount: 27, eligible: true))
        XCTAssertTrue(gate.consume(changeCount: 28, eligible: true))
    }

    func testOneForegroundClipboardGenerationCanBeImportedOnlyOnce() {
        var gate = ForegroundClipboardChangeGate(changeCount: 5)

        XCTAssertTrue(gate.consume(changeCount: 6, eligible: true))
        XCTAssertFalse(gate.consume(changeCount: 6, eligible: true))
    }

    func testClipboardChangeWithoutVisiblePanelIsNotDeferred() {
        var gate = ForegroundClipboardChangeGate(changeCount: 1)

        XCTAssertFalse(gate.consume(changeCount: 2, eligible: false))
        XCTAssertFalse(gate.consume(changeCount: 2, eligible: true))
    }
}
