import XCTest
@testable import UniversalTmuxMac

@MainActor
final class LabAggregationTests: XCTestCase {
    func testSharedBabelStoreProducesOneCopyOfStoreOwnedRecords() {
        let n5 = machine("babel-n5-24")
        let u5 = machine("babel-u5-24")
        let brief = labBrief(set: "s-93k08z", machine: "babel-n5-24")
        let pending = LabKeyInfo(key: "pending-key", set: nil, project: "vlm_gating",
                                 machine: "babel-n5-24", cwd: "/shared/vlm_gating",
                                 session: "vlm_gating", status: "pending", created: "2026-07-11T16:00:00Z")
        let active = LabKeyInfo(key: "active-key", set: "s-93k08z", project: "vlm_gating",
                                machine: "babel-n5-24", cwd: "/shared/vlm_gating",
                                session: "vlm_gating", status: "active", created: "2026-07-11T15:00:00Z")
        let proposal = LabProposal(set: "s-93k08z", run: "R3", project: "vlm_gating",
                                   machine: "babel-n5-24", intent: "compare router loss",
                                   tier: "full", group: "ablation", argv: ["python", "train.py"],
                                   cwd: "/shared/vlm_gating", created: "2026-07-11T17:00:00Z")
        let global = LabHubNote(scope: "global", project: nil, id: "global-1",
                                time: "2026-07-10T00:00:00Z", author: "human",
                                text: "show the full parameters", hidden: false)

        let snapshots = [
            LabModel.MachineSnapshot(machine: n5, briefs: [brief], keys: [pending, active],
                                     proposals: [proposal],
                                     notes: LabModel.NotesResp(store: "one-nfs-store", notes: [global])),
            LabModel.MachineSnapshot(machine: u5, briefs: [brief], keys: [pending, active],
                                     proposals: [proposal],
                                     notes: LabModel.NotesResp(store: "one-nfs-store", notes: [global])),
        ]

        let result = LabModel.aggregate(snapshots, mirrored: [], mirrorHTTPBase: "")

        XCTAssertEqual(result.sets.count, 1)
        XCTAssertEqual(result.pendingKeys.count, 1)
        XCTAssertEqual(result.pendingRuns.count, 1)
        XCTAssertEqual(result.hubNotes.count, 2, "machine-scoped guidance still needs one group per node")
        XCTAssertEqual(result.sets.first?.machineID, n5.id, "the set keeps its actual home machine")
        XCTAssertEqual(result.sets.first?.storeID, "shared:babel")
        XCTAssertEqual(result.sets.first.flatMap { result.activeKeyBySet[$0.id] }, "active-key")

        let model = LabModel()
        model.pendingKeys = result.pendingKeys
        model.pendingRuns = result.pendingRuns
        XCTAssertEqual(model.attentionItems.count, 2)
        XCTAssertEqual(model.attentionItems.map(\.kind), [.proposal, .key])
        XCTAssertEqual(model.attentionItems.map(\.targetID),
                       [result.pendingRuns[0].id, result.pendingKeys[0].id])
        XCTAssertEqual(model.attentionItems[0].summary, "compare router loss")
    }

    func testSameRecordIDOnIndependentStoresRemainsIndependent() {
        let alpha = machine("alpha")
        let beta = machine("beta")
        let snapshots = [
            LabModel.MachineSnapshot(machine: alpha, briefs: [labBrief(set: "s-same", machine: "alpha")],
                                     keys: [], proposals: [],
                                     notes: LabModel.NotesResp(store: "store-a", notes: [])),
            LabModel.MachineSnapshot(machine: beta, briefs: [labBrief(set: "s-same", machine: "beta")],
                                     keys: [], proposals: [],
                                     notes: LabModel.NotesResp(store: "store-b", notes: [])),
        ]

        let result = LabModel.aggregate(snapshots, mirrored: [], mirrorHTTPBase: "")

        XCTAssertEqual(result.sets.count, 2)
        XCTAssertEqual(Set(result.sets.map(\.storeID)), Set(["store:store-a", "store:store-b"]))
    }

    func testBabelPrefixIsSafeFallbackWhenStoreIdentityRequestFails() {
        let brief = labBrief(set: "s-shared", machine: "babel-n5-24")
        let snapshots = [
            LabModel.MachineSnapshot(machine: machine("babel-n5-24"), briefs: [brief],
                                     keys: [], proposals: [], notes: nil),
            LabModel.MachineSnapshot(machine: machine("babel-u5-24"), briefs: [brief],
                                     keys: [], proposals: [], notes: nil),
        ]

        let result = LabModel.aggregate(snapshots, mirrored: [], mirrorHTTPBase: "")

        XCTAssertEqual(result.sets.count, 1)
        XCTAssertEqual(result.sets.first?.storeID, "shared:babel")
    }

    func testNewestResultActivityOrdersSetsAheadOfNewerCreatedButStaleSets() {
        let alpha = machine("alpha")
        let stale = labBrief(set: "s-stale", machine: "alpha",
                             created: "2026-07-12T12:00:00Z", latestAt: "2026-07-12T12:20:00Z")
        let updated = labBrief(set: "s-updated", machine: "alpha",
                               created: "2026-07-11T12:00:00Z", latestAt: "2026-07-12T13:00:00Z")

        let result = LabModel.aggregate([
            LabModel.MachineSnapshot(machine: alpha, briefs: [stale, updated], keys: [], proposals: [],
                                     notes: LabModel.NotesResp(store: "alpha-store", notes: [])),
        ], mirrored: [], mirrorHTTPBase: "")

        XCTAssertEqual(result.sets.map { $0.brief.set.id }, ["s-updated", "s-stale"])
    }

    private func machine(_ name: String) -> Machine {
        Machine(id: "ut-\(name).example.ts.net", name: name, host: name, isLocal: false,
                httpBase: "https://\(name):8722", wsBase: "wss://\(name):8722")
    }

    private func labBrief(set: String, machine: String,
                          created: String = "2026-07-11T15:00:00Z", latestAt: String? = nil) -> LabBrief {
        LabBrief(
            set: LabSetMeta(id: set, project: "vlm_gating", machine: machine,
                            cwd: "/shared/vlm_gating", created: created),
            policy: "full-only", notes: [], setEvents: [],
            runs: [LabRunSummary(id: "R2", group: "ablation", tier: "full", status: "running",
                                 started: "2026-07-11T16:00:00Z", latest: "healthy",
                                 latestAt: latestAt, exitCode: -1, archived: false)],
            archived: false
        )
    }
}
