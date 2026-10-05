import XCTest
import AppKit
import SwiftUI
import ArgusProtocol
@testable import UniversalTmuxMac

@MainActor
final class StatusCorrectionTests: XCTestCase {
    private func fixture(stable: Bool = false) throws -> (AppState, CommandCenterModel, UserDefaults, String, SessionRef) {
        let name = "status-corrections.\(UUID())", defaults = UserDefaults(suiteName: name)!
        let app = AppState(isolatedForTesting: true)
        app.machines[0].brokerID = stable ? "broker" : ""
        app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: "tmux-first")]
        try app.sharedWorkspace.replica.bind("workspace")
        try app.sharedWorkspace.replica.acceptSnapshot(.object(["workspaceID": .string("workspace"), "cursor": .number(0), "records": .array([])]))
        let model = CommandCenterModel(defaults: defaults); model.bind(app)
        let ref = SessionRef(machineID: "local", session: "analysis")
        model.statuses[ref.id] = AgentStatus(label: "idle", oneLiner: "A retained summary", updatedAt: Date(timeIntervalSince1970: 100))
        return (app, model, defaults, name, ref)
    }

    func testSharedStatusUsesDurableQueueAndIsImmediatelyVisible() async throws {
        let (app, model, defaults, name, ref) = try fixture(stable: true)
        defer { defaults.removePersistentDomain(forName: name) }
        model.sendBrokerCorrection = { _, _, _ in XCTFail("must use shared identity"); return nil }
        try await model.submitManualLabel(ref: ref, label: "working")
        XCTAssertEqual(model.statuses[ref.id]?.label, "working")
        XCTAssertEqual(app.sharedWorkspace.replica.pending.last?.id, "broker/tmux-first")
        XCTAssertEqual(app.sharedWorkspace.replica.pending.last?.collection, "cc-overrides")
        model.readSharedStatuses()
        XCTAssertEqual(model.statuses[ref.id]?.label, "working")
    }

    func testBothNativeSessionPathsRetainPendingCorrectionAcrossRefreshAndRelaunch() async throws {
        for lineage in ["tmux-first", "conpty-first"] {
            let (app, model, defaults, name, ref) = try fixture()
            defer { defaults.removePersistentDomain(forName: name) }
            app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: lineage)]
            var sent: [String] = []
            model.sendBrokerCorrection = { _, ref, label in sent.append(ref.session + "/" + label); return nil }
            try await model.submitManualLabel(ref: ref, label: "working")
            XCTAssertEqual(sent, ["analysis/working"])
            XCTAssertTrue(app.sharedWorkspace.replica.pending.isEmpty)
            model.fetchBrokerStatuses = { _ in [.init(session: "analysis", label: "idle", summary: "New text, old label", lookAtThis: nil, updatedAt: 101)] }
            await model.refreshLegacyStatuses(); model.readSharedStatuses()
            XCTAssertEqual(model.statuses[ref.id]?.label, "working")
            defaults.set("workspace", forKey: "ut.workspace.id")
            let reopened = CommandCenterModel(defaults: defaults); reopened.bind(app)
            reopened.fetchBrokerStatuses = model.fetchBrokerStatuses
            await reopened.refreshLegacyStatuses()
            XCTAssertEqual(reopened.statuses[ref.id]?.label, "working")
            reopened.fetchBrokerStatuses = { _ in [.init(session: "analysis", label: "working", summary: "Accepted", lookAtThis: nil, updatedAt: 102)] }
            await reopened.refreshLegacyStatuses()
            reopened.fetchBrokerStatuses = { _ in [.init(session: "analysis", label: "idle", summary: "Finished later", lookAtThis: nil, updatedAt: 103)] }
            await reopened.refreshLegacyStatuses()
            XCTAssertEqual(reopened.statuses[ref.id]?.label, "idle", "A correction is not a permanent lock")
        }
    }

    func testRejectedSaveRestoresPriorStatusAndReportsError() async throws {
        let (app, model, defaults, name, ref) = try fixture()
        defer { withExtendedLifetime(app) {}; defaults.removePersistentDomain(forName: name) }
        model.sendBrokerCorrection = { _, _, _ in throw ArgusFailure("offline", "Broker is offline") }
        do { try await model.submitManualLabel(ref: ref, label: "working"); XCTFail("must report failed save") } catch { }
        XCTAssertEqual(model.statuses[ref.id]?.label, "idle")
        XCTAssertTrue(model.correctionIssue?.contains("offline") == true)
    }

    func testRapidChangesSerializeWritesAndLateFailureCannotRevertNewChoice() async throws {
        let (app, model, defaults, name, ref) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var release: CheckedContinuation<Void, Error>?
        let started = expectation(description: "first save")
        var sent: [String] = []
        model.sendBrokerCorrection = { _, _, label in
            sent.append(label)
            if label == "working" { try await withCheckedThrowingContinuation { release = $0; started.fulfill() } }
            return nil
        }
        let first = Task { try await model.submitManualLabel(ref: ref, label: "working") }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await model.submitManualLabel(ref: ref, label: "stuck") }
        await Task.yield()
        XCTAssertEqual(sent, ["working"])
        release?.resume(throwing: ArgusFailure("offline", "Old save failed"))
        _ = try? await first.value; try await second.value
        XCTAssertEqual(sent, ["working", "stuck"])
        XCTAssertEqual(model.statuses[ref.id]?.label, "stuck")
        XCTAssertNil(model.correctionIssue)
        app.sessionsByMachine["local"] = [SessionInfo(name: "analysis", lineageID: "replacement")]
        model.readSharedStatuses()
        XCTAssertNil(model.statuses[ref.id])
    }

    func testUnboundSharedQueueCannotClaimSuccess() async throws {
        let (app, model, defaults, name, ref) = try fixture(stable: true)
        defer { defaults.removePersistentDomain(forName: name) }
        try app.sharedWorkspace.replica.bind("offline-workspace")
        do { try await model.submitManualLabel(ref: ref, label: "working"); XCTFail("must fail") } catch { }
        XCTAssertTrue(app.sharedWorkspace.replica.pending.isEmpty)
    }

    func testReceiptAcknowledgesCorrectionEvenWhenNextModelLabelDiffers() async throws {
        let (app, model, defaults, name, ref) = try fixture()
        defer { withExtendedLifetime(app) {}; defaults.removePersistentDomain(forName: name) }
        model.sendBrokerCorrection = { _, _, _ in 1234 }
        try await model.submitManualLabel(ref: ref, label: "working")
        model.fetchBrokerStatuses = { _ in [.init(session: "analysis", label: "idle", summary: "Already completed", lookAtThis: nil, updatedAt: 102, appliedOverrideTS: 1234)] }
        await model.refreshLegacyStatuses()
        XCTAssertEqual(model.statuses[ref.id]?.label, "idle", "Publication acknowledges delivery, not a permanent status lock")
    }

    func testStatusActionAndSaveFailureRenderInProductionComponents() async throws {
        let (app, model, defaults, name, ref) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let sent = expectation(description: "tile action saved")
        model.sendBrokerCorrection = { _, _, _ in sent.fulfill(); return nil }
        func tile() -> AgentTileView {
            AgentTileView(machineName: "Workspace host", session: app.sessionsByMachine["local"]![0],
                unseen: false, status: model.statuses[ref.id], inflight: false, size: .large, backlogged: false,
                onSetStatus: { model.setManualLabel(ref: ref, label: $0) }, onBacklog: {}, onOpen: {})
        }
        tile().onSetStatus("working")
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(model.statuses[ref.id]?.label, "working")
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            CommandCenterStatusNotice(issue: "Could not save status for another session: Broker is offline. Try again.")
            tile()
        }.padding(24).background(Theme.appBackground))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/argus-status-mac.png"))
    }
}
