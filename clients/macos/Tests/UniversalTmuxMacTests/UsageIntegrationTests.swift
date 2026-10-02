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

    func testNativeDevinAccountSignInAndReplacementControls() async throws {
        guard ProcessInfo.processInfo.environment["UT_USAGE_VISUAL_QA"] == "1" else { throw XCTSkip("Opt-in native UI; fixture authentication only") }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-devin-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "argus.devin.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SourceConfiguration(id: "devin-fleet", integration: .devin, label: "Fleet")
        var second = SourceConfiguration(id: "devin-personal", integration: .devin, label: "Personal")
        second.loginProfile = directory.appendingPathComponent("personal").path; second.accountIdentity = "personal@example.test"
        let config = IntegrationConfiguration(sources: [first, second])
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let store = UsageStore(registry: IntegrationRegistry(adapters: [], origin: .live, configuration: config), defaults: defaults,
            cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")),
            connections: ConnectionRepository(url: url, profilesDirectory: directory.appendingPathComponent("profiles")))
        store.makeRegistry = { config in
            IntegrationRegistry(adapters: config.sources.map { VisualDevinAccount(configuration: $0) }, origin: .live, configuration: config)
        }
        store.makeDevinAuthenticator = { executable in
            DevinAuthenticator(executable: executable, runner: VisualDevinStatus(), makeSession: { _, environment in
                VisualDevinLogin(profile: URL(fileURLWithPath: environment["HOME"]!))
            })
        }
        let controller = UsageController(store: store, defaults: defaults)
        controller.openConnections()
        let (window, host) = mount(UsageDashboard(controller: controller), width: 1200, height: 850)
        defer { window.close(); store.cancelLogin() }
        try await settle()
        XCTAssertTrue(press(host, identifier: "edit-devin-fleet"))
        try await settle(); try capture(host, name: "devin-edit-account")
        XCTAssertTrue(press(host, identifier: "save-connection"), "An unsigned Devin row must offer native sign-in")
        try await settle()
        XCTAssertNotNil(store.devinLoginProcess)
        try capture(host, name: "devin-sign-in")
        var opened: URL?
        let previousBrowser = UsageBrowser.open
        UsageBrowser.open = { opened = $0; return true }
        defer { UsageBrowser.open = previousBrowser }
        XCTAssertTrue(press(host, identifier: "open-account-sign-in"))
        XCTAssertEqual(opened?.host, "app.devin.ai", "The sign-in link must route through the host browser integration")
        store.devinAuthorizationCode = "fixture-only-code"
        try await settle()
        XCTAssertTrue(press(host, identifier: "finish-devin-login"))
        for _ in 0..<100 where store.loginSourceID != nil { try await Task.sleep(for: .milliseconds(10)) }
        try await settle()
        let saved = try IntegrationConfiguration.load(from: url)
        let profile = try XCTUnwrap(saved.sources[0].loginProfile)
        XCTAssertEqual(saved.sources[0].accountIdentity, "fleet@example.test")
        XCTAssertEqual(saved.sources[1].loginProfile, second.loginProfile)
        XCTAssertEqual(saved.sources[1].accountIdentity, second.accountIdentity)
        XCTAssertEqual(store.devinAuthorizationCode, "")
        try capture(host, name: "devin-connected-accounts")
        XCTAssertTrue(press(host, identifier: "edit-devin-fleet"))
        try await settle(); try capture(host, name: "devin-change-account")
        XCTAssertTrue(press(host, identifier: "change-account-devin-fleet"))
        try await settle()
        XCTAssertTrue(press(host, identifier: "cancel-account-sign-in"))
        for _ in 0..<100 where store.loginSourceID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try IntegrationConfiguration.load(from: url).sources[0].loginProfile, profile)
    }

    func testNativeUnavailableAccountsRemainVisibleAndOpenDetails() async throws {
        guard ProcessInfo.processInfo.environment["UT_USAGE_VISUAL_QA"] == "1" else {
            throw XCTSkip("Opt-in native UI; requires an approved desktop-testing window")
        }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "argus.status.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        store.sources = [IntegrationID.devin, .modal].map { provider in
            UsageSource(id: provider.rawValue, integration: provider, account: "Work", observedAt: .now,
                payload: .unavailable(UnavailableUsage(title: "Unavailable", message: "The account is connected, but usage is unavailable.")),
                origin: .live, accountIdentity: "person@example.test")
        }
        store.didLoad = true
        let controller = UsageController(store: store, defaults: defaults)
        let (fullWindow, fullHost) = mount(UsageDashboard(controller: controller), width: 1200, height: 850)
        defer { fullWindow.close() }
        try await settle(); try capture(fullHost, name: "unavailable-full")
        XCTAssertTrue(press(fullHost, identifier: "open-status-devin"))
        XCTAssertEqual(store.selection?.sourceID, "devin")
        try await settle(); try capture(fullHost, name: "unavailable-details")
        XCTAssertTrue(press(fullHost, identifier: "close-details"))

        let (compactWindow, compactHost) = mount(UsageDashboard(controller: controller), width: 585, height: 628)
        defer { compactWindow.close() }
        try await settle(); try capture(compactHost, name: "unavailable-compact")
        XCTAssertTrue(press(compactHost, identifier: "open-status-modal"))
        XCTAssertEqual(store.selection?.sourceID, "modal")
        controller.open()
        var opened = false
        let (ccWindow, ccHost) = mount(UsageCommandCenterSection(usage: controller) { opened = true }
            .padding(24).background(Theme.appBackground).environment(\.colorScheme, .dark), width: 900, height: 350)
        defer { ccWindow.close() }
        try await settle(); try capture(ccHost, name: "unavailable-command-center")
        XCTAssertTrue(press(ccHost, identifier: "usage-metric-status-devin"))
        XCTAssertTrue(opened)
        XCTAssertEqual(store.selection?.sourceID, "devin")
    }

    func testUsageCardDropsValidateSessionAndCurrentCards() async throws {
        let suite = "argus.card-drop.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        await store.refresh()
        let controller = UsageController(store: store, defaults: defaults)
        let before = controller.glances.map(\.id)
        let first = try XCTUnwrap(before.first), last = try XCTUnwrap(before.last), session = UUID()
        let payload = UsageCardDrag(sessionID: session, cardID: last)
        let decoded = try JSONDecoder().decode(UsageCardDrag.self, from: JSONEncoder().encode(payload))
        XCTAssertFalse(UsageCardDrag.drop([decoded], sessionID: UUID(), targetID: first, placement: .before, usage: controller))
        XCTAssertFalse(UsageCardDrag.drop([decoded, decoded], sessionID: session, targetID: first, placement: .before, usage: controller))
        XCTAssertFalse(UsageCardDrag.drop([decoded], sessionID: session, targetID: "removed", placement: .before, usage: controller))
        XCTAssertEqual(controller.glances.map(\.id), before)
        XCTAssertTrue(UsageCardDrag.drop([decoded], sessionID: session, targetID: first, placement: .before, usage: controller))
        XCTAssertEqual(controller.glances.first?.id, last)
    }

    func testNativeUsageCardArrangeControlsAndPersistence() async throws {
        guard ProcessInfo.processInfo.environment["UT_USAGE_VISUAL_QA"] == "1" else {
            throw XCTSkip("Opt-in native UI; requires an approved desktop-testing window")
        }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "argus.arrange.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        await store.refresh()
        let controller = UsageController(store: store, defaults: defaults)
        let original = controller.glances.map(\.id)
        let first = try XCTUnwrap(original.first), second = original[1]
        var opened = false
        let (window, host) = mount(UsageCommandCenterSection(usage: controller) { opened = true }
            .padding(24).background(Theme.appBackground).environment(\.colorScheme, .dark), width: 1100, height: 650)
        defer { window.close() }
        try await settle(); try capture(host, name: "arrange-default")
        XCTAssertTrue(press(host, identifier: "usage-arrange-cards"))
        try await settle(); try capture(host, name: "arrange-controls")
        XCTAssertTrue(press(host, identifier: "usage-move-right-\(first)"))
        try await settle()
        XCTAssertEqual(Array(controller.glances.prefix(2)).map(\.id), [second, first])
        XCTAssertFalse(opened, "Arranging must not navigate away from the cards")
        try capture(host, name: "arrange-moved")
        controller.reconcile()
        XCTAssertEqual(controller.glances.first?.id, second)
        XCTAssertEqual(UsageController(store: store, defaults: defaults).glances.first?.id, second)
        XCTAssertTrue(press(host, identifier: "usage-reset-card-order"))
        try await settle()
        XCTAssertEqual(controller.glances.map(\.id), original)
        XCTAssertTrue(press(host, identifier: "usage-arrange-cards"))
        try await settle()
        XCTAssertTrue(press(host, identifier: "usage-metric-\(first)"))
        XCTAssertTrue(opened, "Normal click-to-open still works after arranging")
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

@available(macOS 14.0, *)
private struct VisualDevinStatus: CommandRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        CommandOutput(status: 0, stdout: Data("Logged in\nEmail: fleet@example.test\nPlan: Enterprise\n".utf8), stderr: Data())
    }
}

@available(macOS 14.0, *)
private struct VisualDevinAccount: UsageIntegration {
    let id = IntegrationID.devin
    let configuration: SourceConfiguration
    var descriptor: IntegrationDescriptor? { configuration.descriptor }
    func fetchSources() async throws -> [UsageSource] {
        [UsageSource(id: configuration.id, integration: .devin, account: configuration.label, observedAt: .now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 32, durationMinutes: 10080)])),
            origin: .live, accountIdentity: configuration.accountIdentity)]
    }
}

@available(macOS 14.0, *)
private final class VisualDevinLogin: LoginProcessServing, @unchecked Sendable {
    let events: AsyncThrowingStream<LoginProcessEvent, Error>
    let continuation: AsyncThrowingStream<LoginProcessEvent, Error>.Continuation
    let profile: URL
    init(profile: URL) {
        let stream = AsyncThrowingStream<LoginProcessEvent, Error>.makeStream()
        events = stream.stream; continuation = stream.continuation; self.profile = profile
    }
    func start() throws {
        continuation.yield(.output(Data("Visit https://app.devin.ai/auth/cli/continue?state=fixture&code_challenge=fixture&code_challenge_method=S256 to sign in.\n".utf8)))
    }
    func sendCode(_ code: String) throws {
        let directory = profile.appendingPathComponent("data/devin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture-only".utf8).write(to: directory.appendingPathComponent("credentials.toml"))
        continuation.yield(.exited(0)); continuation.finish()
    }
    func cancel() { continuation.finish(throwing: CancellationError()) }
    func close() async { cancel() }
}
