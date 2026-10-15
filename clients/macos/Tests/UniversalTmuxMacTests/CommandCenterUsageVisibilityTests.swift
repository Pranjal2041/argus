import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac
@testable import UsageKit

@available(macOS 14.0, *)
@MainActor
final class CommandCenterUsageVisibilityTests: XCTestCase {
    private func state(defaults: UserDefaults? = nil) -> AppState {
        AppState(isolatedForTesting: true,
                 sessionMonitor: BrokerSessionMonitor(fetch: { _, _ in .failure(.invalidSnapshot) }, probe: { _ in false }),
                 presentationPreferences: defaults)
    }

    private func palette(_ state: AppState) -> CommandPalette {
        CommandPalette(machineName: { $0 }, state: state, terminals: TerminalController(), lab: LabModel(),
                       artifacts: ArtifactStore(loadImmediately: false, logEvents: false),
                       recovery: WorkspaceRecoveryController(), query: "usage")
    }

    func testVisibilityPersistsWithoutChangingNavigationOrOtherPreferences() throws {
        let suite = "argus.usage-visibility.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = state(defaults: defaults)
        XCTAssertFalse(first.hideCommandCenterUsage)
        first.hideBackloggedPanels = true
        let selection = first.selection, destination = first.workspaceDestination
        let commands = palette(first)
        try XCTUnwrap(commands.items.first { $0.title == "Hide Usage in Command Center" }).run()
        XCTAssertTrue(first.hideCommandCenterUsage)
        XCTAssertTrue(defaults.bool(forKey: AppState.hideCommandCenterUsageKey))
        XCTAssertEqual(first.selection, selection)
        XCTAssertEqual(first.workspaceDestination, destination)

        let reopened = state(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reopened.hideCommandCenterUsage)
        XCTAssertTrue(reopened.hideBackloggedPanels)
        let reopenedCommands = palette(reopened)
        try XCTUnwrap(reopenedCommands.items.first { $0.title == "Open Usage" }).run()
        XCTAssertEqual(reopened.workspaceDestination, .usage)
        XCTAssertTrue(reopened.hideCommandCenterUsage, "Opening the full page must not undo the strip preference")
        try reopened.navigate(to: .commandCenter)
        XCTAssertTrue(reopened.hideCommandCenterUsage)
        try XCTUnwrap(reopenedCommands.items.first { $0.title == "Show Usage in Command Center" }).run()
        XCTAssertFalse(state(defaults: defaults).hideCommandCenterUsage)
        XCTAssertTrue(reopened.hideBackloggedPanels)
    }

    func testIsolatedAndBackgroundStatesDoNotWriteProductionVisibility() {
        let before = UserDefaults.standard.object(forKey: AppState.hideCommandCenterUsageKey) as? NSNumber
        for app in [state(), AppState(runtime: .background)] {
            app.hideCommandCenterUsage.toggle()
        }
        XCTAssertEqual(UserDefaults.standard.object(forKey: AppState.hideCommandCenterUsageKey) as? NSNumber, before)
    }

    func testRenderedPaletteHidesAndRestoresTheEntireSectionWithoutStoppingUsage() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "argus.usage-visibility-ui.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = state(defaults: defaults)
        let store = UsageStore(registry: .demo, defaults: defaults)
        await store.refresh()
        // Both successful readings and unavailable accounts belong to the same
        // presentation boundary, regardless of provider or connection state.
        store.sources.append(UsageSource(id: "unavailable-account", integration: .devin, account: "Fixture",
            observedAt: .now, payload: .unavailable(UnavailableUsage(title: "Sign in", message: "Fixture account")), origin: .live))
        store.failures = [IntegrationResult(integration: .devin, sources: [], error: "Fixture account",
            descriptor: IntegrationDescriptor(sourceID: "unavailable-account", integration: .devin, label: "Fixture"),
            needsAuthentication: true, errorTitle: "Sign in")]
        let usage = UsageController(store: store, defaults: defaults)
        let cards = usage.glances.map(\.id), warnings = usage.warnings.map(\.id)
        XCTAssertFalse(cards.isEmpty)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertGreaterThan(usage.connectionIssueCount, 0)
        let section = UsageCommandCenterSection(state: app, usage: usage) { try? app.navigate(to: .usage) }
        let surface = ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Command Center").font(.title.bold()).foregroundStyle(Theme.textPrimary)
                section
                Text("Session panels remain available").foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("session-content")
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 1100, height: 620, alignment: .topLeading)
            .background(Theme.appBackground).environment(\.colorScheme, .dark)
        let (sectionWindow, sectionHost) = mount(surface, width: 1100, height: 620)
        let (paletteWindow, paletteHost) = mount(palette(app), width: 560, height: 407)
        defer { sectionWindow.contentView = nil; paletteWindow.contentView = nil }
        try await settle()
        try capture(sectionHost, name: "shown")
        try capture(paletteHost, name: "palette-hide")
        XCTAssertNotNil(find(sectionHost, id: "usage-command-center"))
        try press(paletteHost, id: "palette-item:a:Hide Usage in Command Center")
        try await settle()
        XCTAssertTrue(app.hideCommandCenterUsage)
        XCTAssertTrue(defaults.bool(forKey: AppState.hideCommandCenterUsageKey))
        XCTAssertNil(find(sectionHost, id: "usage-command-center"))
        XCTAssertNil(find(sectionHost, id: "usage-refresh"))
        XCTAssertNotNil(find(sectionHost, id: "session-content"))
        XCTAssertEqual(usage.glances.map(\.id), cards)
        XCTAssertEqual(usage.warnings.map(\.id), warnings)
        try capture(sectionHost, name: "hidden")
        try capture(paletteHost, name: "palette-show")

        var refreshes = 0
        usage.remoteRefresh = { _ in refreshes += 1 }
        await usage.refresh()
        XCTAssertEqual(refreshes, 1, "Hidden presentation must not disable collection")
        try press(paletteHost, id: "palette-item:a:Open Usage")
        XCTAssertEqual(app.workspaceDestination, .usage)
        XCTAssertTrue(app.hideCommandCenterUsage)
        try app.navigate(to: .commandCenter)
        try press(paletteHost, id: "palette-item:a:Show Usage in Command Center")
        try await settle()
        XCTAssertFalse(app.hideCommandCenterUsage)
        XCTAssertNotNil(find(sectionHost, id: "usage-command-center"))
        try capture(sectionHost, name: "restored")
    }

    private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["UT_USAGE_VISIBILITY_SCREENSHOTS"] else { return }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("usage-\(name).png"))
    }

    private func find(_ value: Any, id: String, depth: Int = 0) -> NSObject? {
        guard depth < 40, let node = value as? NSObject else { return nil }
        let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        if node.responds(to: identifier), node.perform(identifier)?.takeUnretainedValue() as? String == id { return node }
        let values = node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil
        return (values ?? []).compactMap { find($0, id: id, depth: depth + 1) }.first
    }

    private func press(_ host: NSView, id: String) throws {
        let node = try XCTUnwrap(find(host, id: id)), selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(node.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector))
    }
}
