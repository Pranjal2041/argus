import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac
@testable import UsageKit

@available(macOS 14.0, *)
@MainActor
final class UsageIntegrationTests: XCTestCase {
    func testCredentialWorkerExitsWithoutStartingTheAppForMissingKey() async throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/UniversalTmuxMac")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let result = await Task.detached {
            do {
                _ = try UsageCredentialProcess(executable: executable).perform(.init(operation: .read, reference: "argus-usage-nonexistent-test-\(UUID())"))
                return false
            } catch let error as IntegrationError {
                return error.needsAuthentication && error.errorDescription?.contains("macOS has not authorized") == true
            } catch { return false }
        }.value
        XCTAssertTrue(result, "The isolated worker must return an actionable missing-key response without a dialog or app lifecycle")
    }

    func testUsageParticipatesInCommonWorkspaceNavigation() throws {
        let app = AppState()
        for destination in WorkspaceDestination.allCases where destination != .session {
            try app.navigate(to: .usage)
            XCTAssertTrue(app.showUsage)
            XCTAssertEqual(app.workspaceDestination, .usage)
            try app.navigate(to: destination)
            XCTAssertEqual(app.showUsage, destination == .usage)
            XCTAssertEqual(app.workspaceDestination, destination)
        }
        try app.navigate(to: .usage)
        app.showOverview = true
        XCTAssertFalse(app.showUsage)
        try app.navigate(to: .usage)
        app.selection = SessionRef(machineID: "fixture", session: "terminal")
        XCTAssertFalse(app.showUsage)
    }

    func testNativeUsageSurfacesAndInteractions() async throws {
        guard ProcessInfo.processInfo.environment["UT_USAGE_VISUAL_QA"] == "1" else {
            throw XCTSkip("Opt-in native visual/interaction capture; demo data only")
        }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "argus.usage.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        await controller.refresh()
        var opened = false
        let cc = UsageCommandCenterSection(usage: controller) { opened = true }
            .padding(24).background(Theme.appBackground).environment(\.colorScheme, .dark)
        let (window, host) = mount(cc, width: 1100, height: 540)
        defer { window.close() }
        try await settle()
        try capture(host, name: "command-center")
        let warning = try XCTUnwrap(controller.warnings.first)
        let dismissed = press(host, identifier: "usage-dismiss-\(warning.id)")
        XCTAssertTrue(dismissed, "The actual warning dismiss button must be reachable")
        try await settle()
        XCTAssertFalse(controller.warnings.contains { $0.id == warning.id })
        try capture(host, name: "dismissed")
        XCTAssertTrue(press(host, identifier: "usage-open-dashboard"))
        XCTAssertTrue(opened)

        let (fullWindow, fullHost) = mount(UsageDashboard(controller: controller), width: 1280, height: 900)
        defer { fullWindow.close() }
        try await settle(); try capture(fullHost, name: "dashboard")
        XCTAssertTrue(press(fullHost, identifier: "open-codex-research"))
        try await settle()
        XCTAssertEqual(store.selection?.sourceID, "codex-research")
        try capture(fullHost, name: "account-detail")
        controller.open()
        let (compactWindow, compactHost) = mount(UsageDashboard(controller: controller), width: 585, height: 628)
        defer { compactWindow.close() }
        try await settle(); try capture(compactHost, name: "compact")
        XCTAssertTrue(press(compactHost, identifier: "compact-claude-demo-9"))
        try await settle(); try capture(compactHost, name: "compact-detail")
        XCTAssertEqual(store.selection?.sourceID, "claude-demo-9")

        controller.openConnections()
        let (settingsWindow, settingsHost) = mount(UsageWarningSettings(controller: controller), width: 560, height: 660)
        defer { settingsWindow.close() }
        try await settle(); try capture(settingsHost, name: "settings")
        XCTAssertTrue(press(settingsHost, identifier: "usage-restore-warnings"))
        XCTAssertTrue(controller.warnings.contains { $0.id == warning.id })

        // Render the real connection editor without saving or contacting any
        // service. Switching provider controls must not leak draft credentials.
        store.showNewConnection(.devin)
        store.appearance = .light
        fullWindow.appearance = NSAppearance(named: .aqua)
        try await settle(); try capture(fullHost, name: "connections-light")
        XCTAssertTrue(press(fullHost, identifier: "choose-provider-modal"))
        try await settle(); try capture(fullHost, name: "connection-modal")
        XCTAssertTrue(press(fullHost, identifier: "choose-provider-devin"))
        try await settle(); try capture(fullHost, name: "connection-devin")
    }

    private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.setFrameSize(NSSize(width: width, height: height))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        return (window, host)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/argus-usage-\(name).png"))
    }

    private func press(_ element: Any, identifier: String, depth: Int = 0) -> Bool {
        guard depth < 40, let node = element as? NSObject else { return false }
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        let childSelector = NSSelectorFromString("accessibilityChildren")
        let found = node.responds(to: idSelector) ? node.perform(idSelector)?.takeUnretainedValue() as? String : nil
        if found == identifier {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if node.responds(to: selector) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
            }
            node.accessibilityPerformAction(.press)
            return true
        }
        let children = node.responds(to: childSelector) ? node.perform(childSelector)?.takeUnretainedValue() as? [Any] : nil
        for child in children ?? [] {
            if press(child, identifier: identifier, depth: depth + 1) { return true }
        }
        return false
    }
}
