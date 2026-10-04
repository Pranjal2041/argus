import XCTest
import AppKit
import SwiftUI
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageWorkspaceTests: XCTestCase {
    @MainActor func testNativeCollectorConnectionsAndEditorRender() async throws {
        let suite = "usage.workspace.visual.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../testdata/workspace/usage-connections-v1.json").standardizedFileURL
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let store = UsageStore(defaults: defaults)
        store.remoteAccountRequest = { _ in state }
        let received = await store.remoteAccountAction(["action": "state"])
        XCTAssertTrue(received)
        XCTAssertEqual(store.configuration?.sources.count, 2)
        store.editConnection(try XCTUnwrap(store.configuration?.sources.first))
        XCTAssertTrue(store.connectionDraft?.hasSavedCredentials == true)
        let host = NSHostingView(rootView: ScrollView { ConnectionsView(store: store).padding(24) }.background(Palette.background))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-connections-native.png"))
        }
    }
    @MainActor
    func testNormalizedSnapshotRoundTripsQuotaStorageAndConsumptionWithoutConfiguration() async throws {
        let suite = "usage.workspace.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let collectorStore = UsageStore(defaults: defaults)
        await collectorStore.refresh()
        let collector = UsageController(store: collectorStore, defaults: defaults)
        let data = try collector.sharedSnapshot()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNotNil(json["accounts"])
        let text = String(decoding: data, as: UTF8.self)
        for key in ["credentialReference", "executables", "access_token", "refresh_token", "cookieJar"] {
            XCTAssertFalse(text.contains("\"\(key)\""))
        }
        let readerStore = UsageStore(defaults: defaults)
        let reader = UsageController(store: readerStore, defaults: defaults)
        try reader.applySharedSnapshot(data)
        XCTAssertEqual(readerStore.sources.map(\.id), collectorStore.sources.map(\.id))
        XCTAssertEqual(reader.glances.map(\.value), collector.glances.map(\.value))
        XCTAssertEqual(reader.warnings.map(\.id), collector.warnings.map(\.id))
        XCTAssertEqual(reader.warnings.map(\.detail), collector.warnings.map(\.detail))
        for (received, sent) in zip(reader.warnings, collector.warnings) {
            XCTAssertEqual(received.resetsAt?.timeIntervalSince1970 ?? 0, sent.resetsAt?.timeIntervalSince1970 ?? 0, accuracy: 0.001)
        }
        XCTAssertEqual(reader.lastRefresh?.timeIntervalSince1970 ?? 0, collector.lastRefresh?.timeIntervalSince1970 ?? 0, accuracy: 0.001)
    }

    @MainActor
    func testAllRefreshEntryPointsUseRemoteCommandAndSettingsDoNotEcho() async throws {
        let suite = "usage.workspace.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        var commands: [String?] = []
        controller.remoteRefresh = { commands.append($0) }
        await controller.refresh()
        await store.refresh(sourceID: "another-account")
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[1], "another-account")
        XCTAssertTrue(store.sources.isEmpty)
        var settingsWrites = 0
        controller.sharedSettingsChanged = { settingsWrites += 1 }
        controller.policy.quotaRemaining = 15
        XCTAssertEqual(settingsWrites, 1)
        let settings = try controller.sharedSettings()
        try controller.applySharedSettings(settings)
        XCTAssertEqual(settingsWrites, 1)
        XCTAssertEqual(controller.policy.quotaRemaining, 15)
    }
}
