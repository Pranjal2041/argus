import XCTest
import AppKit
import SwiftUI
import ArgusProtocol
@testable import UniversalTmuxMac

@MainActor
final class WorkspaceServiceRegressionTests: XCTestCase {
    func testBackgroundSessionTransitionsNeverRequireDesktopEffects() async {
        for lineage in ["tmux-lifetime", "conpty-lifetime"] {
            var state = "waiting"
            let monitor = BrokerSessionMonitor(fetch: { _, _ in
                .success([SessionInfo(name: "agent", state: state, lineageID: lineage)])
            }, probe: { _ in false })
            let app = AppState(sessionMonitor: monitor, runtime: .background)
            XCTAssertFalse(app.allowsDesktopEffects)
            for next in ["waiting", "working", "idle"] {
                state = next
                let done = expectation(description: next), group = DispatchGroup()
                app.refresh(app.machines[0], group: group, coalesce: false)
                group.notify(queue: .main) { done.fulfill() }
                await fulfillment(of: [done], timeout: 2)
                XCTAssertEqual(app.sessionsByMachine["local"]?.first?.state, next)
            }
        }
    }

    private func setup(legacy: Bool = false) throws -> (AppState, CommandCenterModel, UserDefaults, String) {
        let name = "workspace.service.tests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        let app = AppState(isolatedForTesting: true)
        app.machines[0].brokerID = legacy ? "" : "broker-one"
        app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: "first-lifetime")]
        let replica = app.sharedWorkspace.replica
        try replica.bind("first-workspace")
        try replica.acceptSnapshot(.object(["workspaceID": .string("first-workspace"), "cursor": .number(0), "records": .array([])]))
        let model = CommandCenterModel(defaults: defaults)
        model.bind(app)
        return (app, model, defaults, name)
    }

    func testEmptyPublicationRetainsCacheButNewLifetimeAndWorkspaceDoNot() throws {
        let (app, model, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        let cached = AgentStatus(label: "working", oneLiner: "Comparing the runs", updatedAt: .now)
        model.statuses["local/analysis"] = cached
        model.readSharedStatuses()
        XCTAssertEqual(model.statuses["local/analysis"], cached)
        defaults.set("first-workspace", forKey: "ut.workspace.id")
        let reopened = CommandCenterModel(defaults: defaults)
        reopened.bind(app); reopened.readSharedStatuses()
        XCTAssertEqual(reopened.statuses["local/analysis"], cached)
        app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: "replacement-lifetime")]
        model.readSharedStatuses()
        XCTAssertNil(model.statuses["local/analysis"])
        model.statuses["local/analysis"] = cached
        try app.sharedWorkspace.replica.bind("other-workspace")
        model.readSharedStatuses()
        XCTAssertTrue(model.statuses.isEmpty)
    }

    func testPublishedStatusAndExplicitDeletionReplaceLastKnownPresentation() throws {
        let (app, model, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        let replica = app.sharedWorkspace.replica
        let id = "broker-one/first-lifetime"
        try replica.enqueue("cc-status", id: id, data: .object([
            "label": .string("milestone"), "summary": .string("Report complete"), "updatedAt": .number(1000)
        ]))
        model.readSharedStatuses()
        XCTAssertEqual(model.statuses["local/analysis"]?.oneLiner, "Report complete")
        // A fresh authoritative snapshot with a tombstone is actual deletion.
        let clean = AppState(isolatedForTesting: true)
        clean.machines = app.machines; clean.sessionsByMachine = app.sessionsByMachine
        try clean.sharedWorkspace.replica.bind("first-workspace")
        let record = SharedWorkspaceRecord(collection: "cc-status", id: id, revision: 1, deleted: true)
        try clean.sharedWorkspace.replica.acceptSnapshot(.object([
            "workspaceID": .string("first-workspace"), "cursor": .number(1), "records": try .encode([record])
        ]))
        model.bind(clean); model.readSharedStatuses()
        XCTAssertNil(model.statuses["local/analysis"])
    }

    func testLegacyBrokerKeepsCollectingAndReadingWithoutInventingSharedIDs() async throws {
        for lineage in ["tmux-lifetime", "conpty-lifetime"] {
            let (app, model, defaults, name) = try setup(legacy: true)
            defer { defaults.removePersistentDomain(forName: name) }
            app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: lineage)]
            let ref = SessionRef(machineID: "local", session: "analysis")
            XCTAssertNil(app.sharedSessionKey(ref))
            XCTAssertNotNil(app.collectionSessionKey(ref))
            model.fetchBrokerStatuses = { _ in [.init(session: "analysis", label: "working", summary: "Live legacy summary", lookAtThis: nil, updatedAt: 100)] }
            await model.refreshLegacyStatuses()
            model.readSharedStatuses()
            XCTAssertEqual(model.statuses[ref.id]?.oneLiner, "Live legacy summary")
            model.fetchBrokerStatuses = { _ in nil }
            await model.refreshLegacyStatuses()
            XCTAssertEqual(model.statuses[ref.id]?.oneLiner, "Live legacy summary")
        }
    }

    func testLateLegacyResponseCannotAttachToReplacementSession() async throws {
        let (app, model, defaults, name) = try setup(legacy: true)
        defer { defaults.removePersistentDomain(forName: name) }
        model.fetchBrokerStatuses = { _ in
            app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: "replacement")]
            return [.init(session: "analysis", label: "idle", summary: "Old session", lookAtThis: nil, updatedAt: 100)]
        }
        await model.refreshLegacyStatuses()
        XCTAssertTrue(model.statuses.isEmpty)
    }

    func testRestoredSummaryRendersInActualCommandCenterTile() async throws {
        let (app, model, defaults, name) = try setup()
        defer { defaults.removePersistentDomain(forName: name) }
        model.statuses["local/analysis"] = AgentStatus(label: "working", oneLiner: "Comparing training runs and checking the evaluation results.", updatedAt: .now)
        model.readSharedStatuses()
        let view = AgentTileView(machineName: "Workspace host", session: app.sessionsByMachine["local"]![0],
            unseen: false, status: model.statuses["local/analysis"], inflight: false, size: .large,
            backlogged: false, onSetStatus: { _ in }, onBacklog: {}, onOpen: {})
        let host = NSHostingView(rootView: view.padding(24).background(Theme.appBackground))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["UT_CAPTURE_WORKSPACE_TEST"] == "1" {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-hotfix-command-center.png"))
        }
    }
}
