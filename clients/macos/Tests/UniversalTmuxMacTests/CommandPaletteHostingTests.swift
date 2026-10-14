import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class CommandPaletteHostingTests: XCTestCase {
    private func makePalette(state: AppState? = nil, query: String = "") -> CommandPalette {
        CommandPalette(
            machineName: { $0 },
            state: state ?? AppState(isolatedForTesting: true),
            terminals: TerminalController(),
            lab: LabModel(),
            artifacts: ArtifactStore(loadImmediately: false, logEvents: false),
            recovery: WorkspaceRecoveryController(),
            query: query
        )
    }

    func testDetachedPaletteCanRenderWithExplicitDependencies() {
        let palette = makePalette()
        let host = NSHostingView(rootView: palette)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 407)

        // Force SwiftUI to evaluate the palette just as PaletteWindow does. A missing
        // EnvironmentObject dependency traps during this layout pass (the original
        // Cmd-P crash), so successfully producing a non-empty layout is the regression.
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testRestoreWorkspaceIsAvailableFromCommandPalette() {
        XCTAssertTrue(makePalette().items.contains { $0.title == "Restore Previous Workspace…" })
    }

    func testBacklogCommandIsSearchableAndTogglesTheExistingPreference() throws {
        let state = AppState(isolatedForTesting: true)
        let selection = state.selection
        let palette = makePalette(state: state, query: "backlog")
        let hide = try XCTUnwrap(palette.items.first { $0.title == "Hide Backlogged Panels in Sidebar" })
        hide.run()
        XCTAssertTrue(state.hideBackloggedPanels)
        XCTAssertEqual(state.selection, selection)
        XCTAssertFalse(palette.items.contains { $0.title == hide.title })
        let show = try XCTUnwrap(palette.items.first { $0.title == "Show Backlogged Panels in Sidebar" })
        show.run()
        XCTAssertFalse(state.hideBackloggedPanels)
        XCTAssertEqual(state.selection, selection)
    }

    func testBacklogCommandRendersInFilteredPalette() throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let monitor = BrokerSessionMonitor(fetch: { _, _ in .failure(.invalidSnapshot) }, probe: { _ in false })
        let state = AppState(isolatedForTesting: true, sessionMonitor: monitor)
        state.hideBackloggedPanels = true
        let host = NSHostingView(rootView: makePalette(state: state, query: "backlog"))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 407)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        if let path = ProcessInfo.processInfo.environment["UT_BACKLOG_PALETTE_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        func find(_ value: Any, depth: Int = 0) -> NSObject? {
            guard depth < 40, let node = value as? NSObject else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier")
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: identifier),
               node.perform(identifier)?.takeUnretainedValue() as? String == "palette-item:a:Show Backlogged Panels in Sidebar" { return node }
            let values = node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil
            return (values ?? []).compactMap { find($0, depth: depth + 1) }.first
        }
        let command = try XCTUnwrap(find(host))
        let press = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(command.responds(to: press))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(command.method(for: press), to: Press.self)(command, press)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(state.hideBackloggedPanels, "Activating the rendered command must update the same preference as Settings")
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
