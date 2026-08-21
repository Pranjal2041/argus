import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

@MainActor
final class WebArtifactStoreTests: XCTestCase {
    private struct CachedRecipe: Codable {
        let recipe: WebArtifactRecipe
        let machineID: String
        let machineHTTPBase: String
    }

    func testCachedRecipeRemainsSearchableWhileItsMachineIsOffline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-artifact-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("cache.json")
        let now = Date()
        let recipe = WebArtifactRecipe(
            schemaVersion: 1,
            id: "recipe-1",
            name: "Evaluation dashboard",
            machineName: "babel-p9-28",
            machineHost: "babel-p9-28",
            sessionName: "old-panel-name",
            stableSessionID: "$12",
            sessionLineageID: "tmux:stable-lineage",
            workingDirectory: "/home/pranjala/project",
            command: "exec python dashboard.py --port 5800",
            url: "http://localhost:5800/dashboard",
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([
            CachedRecipe(recipe: recipe, machineID: "babel-p9-28", machineHTTPBase: "http://babel-p9-28:8722")
        ]).write(to: cacheURL)

        let store = WebArtifactStore(cacheURL: cacheURL)
        XCTAssertEqual(store.matching(query: "5800").map(\.id), ["recipe-1"])
        XCTAssertEqual(store.matching(query: "old-panel-name").map(\.id), ["recipe-1"])
        XCTAssertFalse(try XCTUnwrap(store.items.first).reachable)
    }

    func testLocalRecipeUsesTheOnlyBrokerThatReturnedItWhenUIAliasDiffers() {
        let recipe = recipe(machine: "Pranjals-MacBook-Pro-91.local")
        let local = Machine(
            id: "local",
            name: "this mac",
            host: "",
            isLocal: true,
            httpBase: "http://127.0.0.1:8722",
            wsBase: "ws://127.0.0.1:8722"
        )

        let owner = WebArtifactStore.ownerMachine(
            for: recipe,
            sourceMachineIDs: ["local"],
            machines: [local]
        )

        XCTAssertEqual(owner?.id, "local")
    }

    func testSharedBabelRecipeNeverFallsBackToAnArbitrarySibling() {
        let recipe = recipe(machine: "babel-x9-32")
        let first = remoteMachine(id: "babel-n5-24.tailnet.ts.net", name: "babel-n5-24")
        let second = remoteMachine(id: "babel-p9-28.tailnet.ts.net", name: "babel-p9-28")

        let owner = WebArtifactStore.ownerMachine(
            for: recipe,
            sourceMachineIDs: [first.id, second.id],
            machines: [first, second]
        )

        XCTAssertNil(owner)
    }

    func testSharedBabelRecipeStillChoosesItsExactLiveOwner() {
        let recipe = recipe(machine: "babel-p9-28")
        let first = remoteMachine(id: "babel-n5-24.tailnet.ts.net", name: "babel-n5-24")
        let ownerMachine = remoteMachine(id: "babel-p9-28.tailnet.ts.net", name: "babel-p9-28")

        let owner = WebArtifactStore.ownerMachine(
            for: recipe,
            sourceMachineIDs: [first.id, ownerMachine.id],
            machines: [first, ownerMachine]
        )

        XCTAssertEqual(owner?.id, ownerMachine.id)
    }

    func testDedicatedWebArtifactsViewHostsWithoutTheFileArtifactStore() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-artifact-view-\(UUID().uuidString)")
        let store = WebArtifactStore(cacheURL: root.appendingPathComponent("cache.json"))
        let dashboards = DashboardsModel(
            restoreSavedTabs: false,
            startPolling: false,
            persistTabState: false
        )
        let host = NSHostingView(rootView: WebArtifactsView()
            .environmentObject(AppState(isolatedForTesting: true))
            .environmentObject(store)
            .environmentObject(dashboards))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.size, NSSize(width: 900, height: 640))
    }

    func testDedicatedWebArtifactsViewRendersAtCompactWindowWidth() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-artifact-compact-view-\(UUID().uuidString)")
        let store = WebArtifactStore(cacheURL: root.appendingPathComponent("cache.json"))
        let dashboards = DashboardsModel(
            restoreSavedTabs: false,
            startPolling: false,
            persistTabState: false
        )
        let host = NSHostingView(rootView: WebArtifactsView()
            .environmentObject(AppState(isolatedForTesting: true))
            .environmentObject(store)
            .environmentObject(dashboards))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(host.frame.size, NSSize(width: 520, height: 640))
        XCTAssertNotNil(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    }

    func testWebArtifactsAndFileArtifactsAreMutuallyExclusiveDestinations() {
        let state = AppState(isolatedForTesting: true)
        state.showArtifacts = true
        state.presentWebArtifacts()
        XCTAssertTrue(state.showWebArtifacts)
        XCTAssertFalse(state.showArtifacts)

        state.presentArtifacts()
        XCTAssertTrue(state.showArtifacts)
        XCTAssertFalse(state.showWebArtifacts)
    }

    private func recipe(machine: String) -> WebArtifactRecipe {
        WebArtifactRecipe(
            schemaVersion: 1,
            id: "recipe-\(machine)",
            name: "Evaluation dashboard",
            machineName: machine,
            machineHost: machine,
            sessionName: "evaluation",
            stableSessionID: "$4",
            sessionLineageID: "tmux:lineage:$4",
            workingDirectory: "/home/pranjala/project",
            command: "exec python dashboard.py --port 5800",
            url: "http://localhost:5800/dashboard",
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func remoteMachine(id: String, name: String) -> Machine {
        Machine(
            id: id,
            name: name,
            host: name,
            isLocal: false,
            httpBase: "https://\(id):8722",
            wsBase: "wss://\(id):8722"
        )
    }
}
