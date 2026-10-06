import AppKit
import SwiftUI
import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class AccountLoginPresentationTests: XCTestCase {
    func testHandoffRequiresMatchingIntentAndConsumesOnlyOnce() {
        let url = URL(string: "https://login.example.test/authorize")!
        var handoff = AccountLoginHandoff()
        XCTAssertNil(handoff.consume(attemptID: "one", url: url, automatically: true))
        handoff.begin("one")
        XCTAssertNil(handoff.consume(attemptID: "one", url: nil, automatically: true))
        XCTAssertEqual(handoff.consume(attemptID: "one", url: url, automatically: true), url)
        XCTAssertNil(handoff.consume(attemptID: "one", url: url, automatically: true))
        handoff.begin("two")
        XCTAssertNil(handoff.consume(attemptID: "one", url: url, automatically: true))
        XCTAssertNil(handoff.consume(attemptID: "two", url: url, automatically: true))
        handoff.begin("three"); handoff.reset()
        XCTAssertNil(handoff.consume(attemptID: "three", url: url, automatically: true))
    }

    func testHandoffDoesNotOpenManualOrUnsafeURLs() {
        for address in ["file:///tmp/secret", "javascript:alert(1)", "http://example.test/login", "https://user:password@example.test/login"] {
            var handoff = AccountLoginHandoff(); handoff.begin("one")
            XCTAssertNil(handoff.consume(attemptID: "one", url: URL(string: address), automatically: true))
        }
        var handoff = AccountLoginHandoff(); handoff.begin("one")
        XCTAssertNil(handoff.consume(attemptID: "one", url: URL(string: "https://example.test/login"), automatically: false))
    }

    @MainActor func testRequestingClientOpensImmediateAndDelayedURLsAcrossProvidersOnce() async {
        for provider in ["codex", "claude", "devin"] {
            for immediate in [false, true] {
                let store = makeStore(), service = LoginServiceFixture()
                service.urlReady = immediate
                store.remoteAccountRequest = service.handle
                var opened: [URL] = []
                store.openAccountLoginURL = { opened.append($0); return true }
                let connected = await store.remoteAccountAction(["action": "connect", "sourceID": provider])
                XCTAssertTrue(connected)
                XCTAssertEqual(opened.count, immediate ? 1 : 0)
                service.urlReady = true
                for _ in 0..<3 { _ = await store.remoteAccountAction(["action": "state"]) }
                XCTAssertEqual(opened, [service.url])
                XCTAssertTrue(store.loginInstructions?.browserOpened == true)
                XCTAssertEqual(store.loginContext?.id, service.attemptID)
                let observer = makeStore()
                observer.remoteAccountRequest = service.handle
                observer.openAccountLoginURL = { _ in XCTFail("Observer must not open another client's attempt"); return false }
                _ = await observer.remoteAccountAction(["action": "state"])
                XCTAssertEqual(observer.loginInstructions?.url, service.url)
                _ = await store.remoteAccountAction(["action": "cancel"])
                XCTAssertNil(store.loginSourceID)
                XCTAssertNil(store.loginInstructions)
                XCTAssertFalse(store.remoteAccountActionPending)
                _ = await store.remoteAccountAction(["action": "connect", "sourceID": provider])
                XCTAssertEqual(opened.count, 2, "A new explicit attempt can open again")
            }
        }
    }

    @MainActor func testDeviceCodeLegacyAndForeignAttemptsRemainManual() async {
        for mode in ["device", "legacy", "foreign"] {
            let store = makeStore(), service = LoginServiceFixture()
            service.automatic = mode != "device"
            store.remoteAccountRequest = { request in
                var state = await service.handle(request)
                if mode == "legacy" { state.removeValue(forKey: "loginAttemptID") }
                if mode == "foreign" { state["loginAttemptID"] = "another-client" }
                if mode == "device" { state["userCode"] = "TEST-ONLY" }
                return state
            }
            store.openAccountLoginURL = { _ in XCTFail("\(mode) cannot automatically open"); return false }
            _ = await store.remoteAccountAction(["action": "connect", "sourceID": "codex"])
            _ = await store.remoteAccountAction(["action": "state"])
            XCTAssertEqual(store.loginInstructions?.url, service.url)
        }
    }

    @MainActor func testFailedLaunchIsNotRetriedByPollingAndManualRetryWorks() async {
        let store = makeStore(), service = LoginServiceFixture()
        store.remoteAccountRequest = service.handle
        var launches = 0
        store.openAccountLoginURL = { _ in launches += 1; return launches > 1 }
        _ = await store.remoteAccountAction(["action": "connect", "sourceID": "codex"])
        for _ in 0..<3 { _ = await store.remoteAccountAction(["action": "state"]) }
        XCTAssertEqual(launches, 1)
        XCTAssertNotNil(store.loginBrowserError)
        XCTAssertEqual(store.loginInstructions?.url, service.url)
        store.openAccountLoginPage()
        XCTAssertEqual(launches, 2)
        XCTAssertNil(store.loginBrowserError)
    }

    @MainActor func testNewConnectionSaveAlsoOwnsItsLoginPresentation() async {
        let store = makeStore(), service = LoginServiceFixture()
        store.remoteAccountRequest = service.handle
        var opened = false
        store.openAccountLoginURL = { _ in opened = true; return true }
        var draft = ConnectionDraft(integration: .claude); draft.label = "New account"
        let saved = await store.saveConnection(draft)
        XCTAssertTrue(saved)
        XCTAssertTrue(opened)
        XCTAssertNotNil(service.requests.first?["loginAttemptID"])
    }

    @MainActor func testLatePollCannotResurrectCancelledAttempt() async throws {
        let store = makeStore(), service = LoginServiceFixture()
        store.remoteAccountRequest = service.handle
        store.openAccountLoginURL = { _ in true }
        _ = await store.remoteAccountAction(["action": "connect", "sourceID": "codex"])
        var pending: CheckedContinuation<[String: Any], Never>?
        let stale = service.state
        store.remoteAccountRequest = { request in
            if request["action"] as? String == "state" { return await withCheckedContinuation { pending = $0 } }
            return await service.handle(request)
        }
        let poll = Task { await store.remoteAccountAction(["action": "state"]) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        _ = await store.remoteAccountAction(["action": "cancel"])
        continuation.resume(returning: stale)
        let applied = await poll.value
        XCTAssertFalse(applied)
        XCTAssertNil(store.loginSourceID)
        XCTAssertNil(store.loginInstructions)
        XCTAssertEqual(service.requests.last?["loginAttemptID"] as? String, stale["loginAttemptID"] as? String)
    }

    @MainActor func testWorkspaceSwitchInvalidatesPendingCommandAndDuplicateCommandsAreSuppressed() async throws {
        let store = makeStore(), service = LoginServiceFixture()
        let controller = UsageController(store: store, defaults: testDefaults())
        var pending: CheckedContinuation<[String: Any], Never>?
        var calls = 0, response: [String: Any] = [:]
        store.remoteAccountRequest = { request in
            calls += 1; response = await service.handle(request)
            return await withCheckedContinuation { pending = $0 }
        }
        store.openAccountLoginURL = { _ in XCTFail("Old workspace must not open a browser"); return false }
        let command = Task { await store.remoteAccountAction(["action": "connect", "sourceID": "codex"]) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        XCTAssertTrue(store.remoteAccountActionPending)
        let duplicate = await store.remoteAccountAction(["action": "connect", "sourceID": "claude"])
        _ = await store.remoteAccountAction(["action": "state"])
        XCTAssertFalse(duplicate); XCTAssertEqual(calls, 1)
        controller.clearSharedPresentation()
        continuation.resume(returning: response)
        let applied = await command.value
        XCTAssertFalse(applied)
        XCTAssertNil(store.loginSourceID)
        XCTAssertNil(store.remoteAccountConfiguration)
        XCTAssertFalse(store.remoteAccountActionPending)
    }

    @MainActor func testServiceCorrelatesImmediateLoginAndAllowsCancellationDuringCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("login-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = IntegrationConfiguration(sources: [.init(id: "claude", integration: .claude, label: "Work")])
        let repo = ConnectionRepository(url: root.appendingPathComponent("config.json"), profilesDirectory: root.appendingPathComponent("profiles"))
        try config.save(to: repo.url)
        let before = try Data(contentsOf: repo.url)
        let store = UsageStore(registry: .init(adapters: [], origin: .live, configuration: config),
            defaults: testDefaults(), cache: .init(url: root.appendingPathComponent("cache.json")), connections: repo)
        let started = try await store.handleAccountService(["action": "connect", "sourceID": "claude", "loginAttemptID": "first"])
        XCTAssertEqual(started["loginAttemptID"] as? String, "first")
        XCTAssertEqual(started["opensBrowserAutomatically"] as? Bool, true)
        XCTAssertNotNil(started["url"])
        store.refreshing = true
        let stale = try await store.handleAccountService(["action": "cancel", "loginAttemptID": "older"])
        XCTAssertEqual(stale["loginAttemptID"] as? String, "first")
        let cancelled = try await store.handleAccountService(["action": "cancel", "loginAttemptID": "first"])
        XCTAssertNil(cancelled["loginSourceID"])
        XCTAssertNil(cancelled["loginAttemptID"])
        XCTAssertNil(cancelled["url"])
        XCTAssertEqual(try Data(contentsOf: repo.url), before)
        store.refreshing = false
        var draft = ConnectionDraft(integration: .claude); draft.label = "New account"
        let saved = try await store.handleAccountService(["action": "save", "draft": draft.serviceFields, "loginAttemptID": "saved"])
        XCTAssertEqual(saved["loginAttemptID"] as? String, "saved")
        XCTAssertEqual(saved["opensBrowserAutomatically"] as? Bool, true)
        XCTAssertNotNil(saved["url"])
        _ = try await store.handleAccountService(["action": "cancel", "loginAttemptID": "saved"])
    }

    @MainActor func testNativeConnectionsOpenFromClickAndReleaseControlsOnCancel() async throws {
        guard ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" else {
            throw XCTSkip("Set UT_CAPTURE_WORKSPACE_TEST=1 to render and exercise native controls")
        }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let store = makeStore(), service = LoginServiceFixture()
        store.remoteAccountRequest = service.handle
        var opened: [URL] = []
        store.openAccountLoginURL = { opened.append($0); return true }
        _ = await store.remoteAccountAction(["action": "state"])
        let host = NSHostingView(rootView: ScrollView { ConnectionsView(store: store).padding(24) }.background(Palette.background))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        for provider in ["codex", "claude"] {
            service.urlReady = provider == "claude"
            XCTAssertTrue(press(host, "connect-\(provider)"))
            try await Task.sleep(for: .milliseconds(100))
            if !service.urlReady {
                service.urlReady = true
                _ = await store.remoteAccountAction(["action": "state"])
            }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(opened.last, service.url)
            XCTAssertEqual(store.loginSourceID, provider)
            try capture(host, "\(provider)-pending")
            XCTAssertTrue(press(host, "cancel-account-sign-in"))
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(store.loginSourceID)
            XCTAssertFalse(store.remoteAccountActionPending)
            try capture(host, "\(provider)-cancelled")
        }
        XCTAssertEqual(opened.count, 2, "The rendered controls start exactly one browser handoff per click")
    }

    @MainActor private func testDefaults() -> UserDefaults {
        let suite = "login-presentation-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor private func makeStore() -> UsageStore { UsageStore(defaults: testDefaults()) }

    @MainActor private func capture(_ host: NSView, _ name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-login-handoff-\(name).png"))
    }

    @MainActor private func press(_ element: Any, _ identifier: String, depth: Int = 0) -> Bool {
        guard depth < 40, let node = element as? NSObject else { return false }
        let idSelector = NSSelectorFromString("accessibilityIdentifier")
        let childSelector = NSSelectorFromString("accessibilityChildren")
        let found = node.responds(to: idSelector) ? node.perform(idSelector)?.takeUnretainedValue() as? String : nil
        if found == identifier {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard node.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
        }
        let children = node.responds(to: childSelector) ? node.perform(childSelector)?.takeUnretainedValue() as? [Any] : nil
        return (children ?? []).contains { press($0, identifier, depth: depth + 1) }
    }
}

@MainActor @available(macOS 14.0, *)
private final class LoginServiceFixture {
    var attemptID: String?, sourceID: String?
    var urlReady = true, automatic = true
    var requests: [[String: Any]] = []
    var url: URL { URL(string: "https://login.example.test/\(sourceID ?? "none")")! }
    var state: [String: Any] {
        var codex = SourceConfiguration(id: "codex", integration: .codex, label: "Personal")
        codex.codexHome = "/fixture/profile"; codex.accountIdentity = "personal@example.test"
        let claude = SourceConfiguration(id: "claude", integration: .claude, label: "Work")
        var state: [String: Any] = ["connections": [codex, claude].map { ConnectionDraft(source: $0).serviceFields }]
        state["loginSourceID"] = sourceID; state["loginAttemptID"] = attemptID
        state["loginIntegration"] = sourceID
        state["message"] = sourceID == nil ? "Sign-in cancelled." : "Finish signing in to this account in UT Browser."
        if urlReady, sourceID != nil { state["url"] = url.absoluteString }
        state["opensBrowserAutomatically"] = automatic
        return state
    }
    func handle(_ request: [String: Any]) async -> [String: Any] {
        requests.append(request)
        switch request["action"] as? String {
        case "connect", "save":
            sourceID = request["sourceID"] as? String ?? "claude"
            attemptID = request["loginAttemptID"] as? String
        case "cancel": sourceID = nil; attemptID = nil
        default: break
        }
        return state
    }
}
