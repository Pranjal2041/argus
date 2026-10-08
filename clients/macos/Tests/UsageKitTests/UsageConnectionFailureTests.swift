import AppKit
import SwiftUI
import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageConnectionFailureTests: XCTestCase {
    @MainActor func testHTTPAdapterPermissionFailurePreservesReadingAndRecoversThroughSameSharedContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-http-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = root.appendingPathComponent("fixture.env")
        try Data("OPENAI_ADMIN_KEY=fixture-not-a-secret".utf8).write(to: credential)
        var config = SourceConfiguration(id: "http-account", integration: .openaiAPI, label: "HTTP account")
        config.credentialFile = credential.path
        let client = PermissionRecoveryHTTPClient()
        let suite = "usage.failures.http.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(registry: IntegrationRegistry(adapters: [LiveOpenAIIntegration(configuration: config, client: client)],
            origin: .live, configuration: .init(sources: [config])), defaults: defaults, cache: .init(url: root.appendingPathComponent("cache.json")))
        let controller = UsageController(store: store, defaults: defaults)
        let readerStore = UsageStore(defaults: defaults)
        let sharedReader = UsageController(store: readerStore, defaults: defaults)
        await store.refresh()
        let timestamp = try XCTUnwrap(store.sources.first?.observedAt)
        XCTAssertEqual(store.sources.first?.spend?.spent, 12)
        await store.refresh()
        try sharedReader.applySharedSnapshot(controller.sharedSnapshot())
        XCTAssertEqual(readerStore.connectionStatus(sourceID: config.id).title, "Access required")
        XCTAssertEqual(readerStore.sources.first?.spend?.spent, 12)
        XCTAssertEqual(readerStore.sources.first?.observedAt.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(readerStore.sources.first?.isStale == true)
        await store.refresh(sourceID: config.id)
        try sharedReader.applySharedSnapshot(controller.sharedSnapshot())
        XCTAssertEqual(readerStore.connectionStatus(sourceID: config.id).title, "Connected")
        XCTAssertEqual(readerStore.sources.first?.spend?.spent, 12)
        XCTAssertFalse(readerStore.sources.first?.isStale == true)
        XCTAssertTrue(readerStore.failures.isEmpty)
    }

    @MainActor func testFailuresSurviveSharingWithoutReplacingReadingsOrContaminatingSiblingAccounts() async throws {
        let suite = "usage.failures.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let collectorStore = UsageStore(defaults: defaults)
        let collector = UsageController(store: collectorStore, defaults: defaults)
        var codex = reading("quota", provider: .codex), api = reading("spend", provider: .openaiAPI)
        codex.isStale = true; api.isStale = true
        collectorStore.sources = [codex, api, reading("sibling", provider: .codex)]
        collectorStore.failures = [failure(codex, .authentication("Sign in again to restore live usage.")),
                                   failure(api, .permission("The saved credential needs permission to read costs."))]
        let data = try collector.sharedSnapshot()
        let snapshot = try UsageWorkspaceWire.decoder.decode(UsageWorkspaceWire.Snapshot.self, from: data)
        XCTAssertEqual(snapshot.accounts.map(\.status), ["Connect account", "Access required", "Connected"])
        XCTAssertEqual(snapshot.accounts.map(\.stale), [true, true, false])
        let readerStore = UsageStore(defaults: defaults)
        let reader = UsageController(store: readerStore, defaults: defaults)
        try reader.applySharedSnapshot(data)
        XCTAssertEqual(readerStore.sources.first?.quota?.weeklyWindow?.usedPercent, 25)
        XCTAssertEqual(readerStore.sources[1].spend?.spent, 12)
        XCTAssertEqual(readerStore.sources.map(\.observedAt), collectorStore.sources.map(\.observedAt))
        XCTAssertEqual(readerStore.failures.compactMap { $0.descriptor?.sourceID }, ["quota", "spend"])
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "quota").title, "Connect account")
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "spend").title, "Access required")
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "quota").message, collectorStore.failures[0].error)
        XCTAssertTrue(readerStore.connectionStatus(sourceID: "quota").needsAttention)
        XCTAssertFalse(readerStore.connectionStatus(sourceID: "sibling").needsAttention)
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "sibling").title, "Connected")
        // A newer successful snapshot clears both the cached flag and the failure.
        collectorStore.sources[0].isStale = false
        collectorStore.failures.removeFirst()
        try reader.applySharedSnapshot(collector.sharedSnapshot())
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "quota").title, "Connected")
        XCTAssertNil(readerStore.connectionStatus(sourceID: "quota").message)
        XCTAssertEqual(readerStore.connectionStatus(sourceID: "spend").title, "Access required")
    }

    @MainActor func testLegacySnapshotsRetainFailureIdentityAndInferOnlyAuthenticationTitle() throws {
        let suite = "usage.failures.legacy.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults), readerStore = UsageStore(defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        let source = reading("quota", provider: .codex)
        store.sources = [source]
        store.failures = [failure(source, .authentication("Sign in again."))]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: controller.sharedSnapshot()) as? [String: Any])
        var failures = try XCTUnwrap(json["failures"] as? [[String: Any]])
        failures[0].removeValue(forKey: "errorTitle"); json["failures"] = failures
        let reader = UsageController(store: readerStore, defaults: defaults)
        try reader.applySharedSnapshot(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(readerStore.failures.first?.descriptor?.sourceID, source.id)
        XCTAssertEqual(readerStore.connectionStatus(sourceID: source.id).title, "Connect account")
        // Failure-only accounts still retain identity before their first reading.
        json["sources"] = []
        try reader.applySharedSnapshot(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(readerStore.connectionStatus(sourceID: source.id).title, "Connect account")
    }

    func testCachedReadingsAreNeverMarkedHealthyAndDisabledConnectionsDoNotWarn() {
        var source = reading("quota", provider: .codex)
        source.isStale = true
        let stale = UsageConnectionStatus(source: source, failure: nil)
        XCTAssertEqual(stale.title, "Cached")
        XCTAssertTrue(stale.needsAttention)
        XCTAssertEqual(stale.symbol, "exclamationmark.circle")
        let disabled = UsageConnectionStatus(source: source, failure: failure(source, .timeout), enabled: false)
        XCTAssertEqual(disabled.title, "Disabled")
        XCTAssertFalse(disabled.needsAttention)
        XCTAssertNil(disabled.message)
        XCTAssertNotEqual(disabled.symbol, "checkmark.circle")
        XCTAssertEqual(UsageConnectionStatus(source: nil, failure: nil).symbol, "minus.circle")
        source.payload = .unavailable(.init(title: "Connect account", message: "Sign in again.", needsAuthentication: true))
        let savedFailure = UsageConnectionStatus(source: source, failure: nil)
        XCTAssertEqual(savedFailure.title, "Sign in", "A cached unavailable result still describes a connection failure")
        XCTAssertEqual(savedFailure.message, "Sign in again.")
    }

    @MainActor func testNativeConnectionsRenderTheSharedFailureAndClearItAfterRecovery() async throws {
        guard ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" else {
            throw XCTSkip("Set UT_CAPTURE_WORKSPACE_TEST=1 to render and exercise native controls")
        }
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "usage.failures.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configs = [SourceConfiguration(id: "quota", integration: .codex, label: "Personal"),
                       SourceConfiguration(id: "spend", integration: .openaiAPI, label: "Work")]
        configs[0].codexHome = "/fixture/profile"
        let store = UsageStore(registry: IntegrationRegistry(adapters: [], configuration: .init(sources: configs)), defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        var codex = reading("quota", provider: .codex), api = reading("spend", provider: .openaiAPI)
        codex.isStale = true; api.isStale = true
        store.sources = [codex, api]
        store.failures = [failure(codex, .authentication("This profile has no active ChatGPT login after refreshing. Sign in again to restore live usage.")),
                          failure(api, .permission("The saved credential needs permission to read costs."))]
        var refreshedIDs: [String] = []
        store.remoteRefresh = { id in
            guard let id else { return }
            refreshedIDs.append(id)
            store.failures.removeAll { $0.descriptor?.sourceID == id }
            if let index = store.sources.firstIndex(where: { $0.id == id }) { store.sources[index].isStale = false }
        }
        // Exercise the real consumer path before rendering the native view.
        try controller.applySharedSnapshot(controller.sharedSnapshot())
        let host = NSHostingView(rootView: ScrollView { ConnectionsView(store: store).padding(24) }.background(Palette.background))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for recovered in [false, true] {
            if recovered {
                XCTAssertTrue(press(host, identifier: "check-quota"))
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(store.connectionStatus(sourceID: "quota").title, "Connected")
                XCTAssertEqual(store.connectionStatus(sourceID: "spend").title, "Access required")
                XCTAssertTrue(press(host, identifier: "check-spend"))
            }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let name = recovered ? "recovered" : "failed"
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-connection-\(name).png"))
        }
        XCTAssertEqual(refreshedIDs, ["quota", "spend"])
        XCTAssertTrue(store.failures.isEmpty)
    }

    @MainActor private func press(_ element: Any, identifier: String, depth: Int = 0) -> Bool {
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
        return (children ?? []).contains { press($0, identifier: identifier, depth: depth + 1) }
    }

    private func reading(_ id: String, provider: IntegrationID) -> UsageSource {
        UsageSource(id: id, integration: provider, account: id, observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            payload: provider == .codex
                ? .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 25, resetsAt: nil, durationMinutes: 10080)]))
                : .spend(SpendUsage(spent: 12, today: 2, dailySpend: [12], breakdown: [])), origin: .live,
            accountIdentity: "\(id)@example.test")
    }

    private func failure(_ source: UsageSource, _ error: IntegrationError) -> IntegrationResult {
        .init(integration: source.integration, sources: [], error: error.errorDescription,
            descriptor: .init(sourceID: source.id, integration: source.integration, label: source.account),
            needsAuthentication: error.needsAuthentication, errorTitle: error.title)
    }
}

@available(macOS 14.0, *)
private actor PermissionRecoveryHTTPClient: HTTPClient {
    private var requests = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests += 1
        if requests == 2 { return HTTPResponse(status: 403, data: Data(), retryAfter: nil) }
        let start = Int(UsageCalendar.monthStart(.now).timeIntervalSince1970)
        let data = Data("""
        {"data":[{"start_time":\(start),"results":[{"amount":{"value":12,"currency":"usd"},"project_id":"fixture"}]}],"has_more":false}
        """.utf8)
        return HTTPResponse(status: 200, data: data, retryAfter: nil)
    }
}
