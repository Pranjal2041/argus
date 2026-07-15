import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class CommandPaletteHostingTests: XCTestCase {
    func testDetachedPaletteCanRenderWithExplicitDependencies() {
        let palette = CommandPalette(
            machineName: { $0 },
            state: AppState(isolatedForTesting: true),
            terminals: TerminalController(),
            lab: LabModel()
        )
        let host = NSHostingView(rootView: palette)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 407)

        // Force SwiftUI to evaluate the palette just as PaletteWindow does. A missing
        // EnvironmentObject dependency traps during this layout pass (the original
        // Cmd-P crash), so successfully producing a non-empty layout is the regression.
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testAppStateInitializationCannotMutateProductionTodosUnderXCTest() {
        XCTAssertTrue(AppState.isRunningTests, "XCTest process detection must fail closed")
        let defaults = UserDefaults.standard
        let beforeData = defaults.data(forKey: "ut.todoBoards.v1")
        let beforeTimestamp = defaults.object(forKey: "ut.todoBoards.updatedAt") as? NSNumber

        _ = AppState() // automatic XCTest detection must isolate even without the flag

        XCTAssertEqual(defaults.data(forKey: "ut.todoBoards.v1"), beforeData)
        XCTAssertEqual(defaults.object(forKey: "ut.todoBoards.updatedAt") as? NSNumber,
                       beforeTimestamp)
    }
}
