import XCTest
@testable import Argus

/// Lab decoding and the shared-store reduction, mirroring Android's
/// LabAggregatorTest / LabLifecycleTest so both clients agree on identity.
final class LabTests: XCTestCase {
    // MARK: Decoding

    func testGoNullSlicesAndOmittedFieldsDecode() throws {
        let empty = #"{"sets":null}"#
        XCTAssertEqual(try JSONDecoder().decode(LabSetsResponse.self, from: Data(empty.utf8)).sets?.count ?? 0, 0)
        XCTAssertNil(try JSONDecoder().decode(LabKeysResponse.self, from: Data(#"{"keys":null}"#.utf8)).keys)
        XCTAssertNil(try JSONDecoder().decode(LabMirrorResponse.self, from: Data(#"{"mirror":null}"#.utf8)).mirror)

        let brief = """
        {"set":{"id":"s-1","project":"p","machine":"alpha","cwd":"/w","created":"2026-07-11T15:00:00Z"},
         "policy":"all","notes":null,"runs":[
           {"id":"R1","status":"running (3m)","exitCode":-1,"started":"2026-07-11T16:00:00Z"},
           {"id":"R2","status":"done","exitCode":0,"archived":true},
           {"id":"R3","status":"proposed (awaiting approval)"}
         ]}
        """
        let b = try JSONDecoder().decode(LabBrief.self, from: Data(brief.utf8))
        XCTAssertEqual(b.policy, "all")
        XCTAssertTrue(b.notes.isEmpty)
        XCTAssertTrue(b.setEvents.isEmpty)
        XCTAssertEqual(b.runs.map(\.exitCode), [-1, 0, -1], "missing exitCode means no mechanical ending")
        XCTAssertEqual(b.runs.map(\.archived), [false, true, false])
        XCTAssertNil(b.set.store)

        let noPolicy = try JSONDecoder().decode(LabBrief.self, from: Data(#"{"set":{"id":"s-2"}}"#.utf8))
        XCTAssertEqual(noPolicy.policy, "full-only")
    }

    func testEventDataIsLenientFreeFormMap() throws {
        let json = """
        {"events":[
          {"id":"e1","time":"2026-07-11T16:00:00Z","author":"machine","kind":"run-start",
           "data":{"argv":["python","train.py"],"machine":"babel-n5-24","tmuxSession":"vlm","params":null,
                   "dataFiles":[{"path":"/d/eval.jsonl","size":12,"sha256":"abc"}],
                   "snapshot":{"baseSha":"0123456789abcdef","patchBytes":42},"env":{"os":"linux","python":"Python 3.11"}}},
          {"id":"e2","time":"2026-07-11T17:00:00Z","author":"machine","kind":"run-end",
           "data":{"exit":2.0,"durationSec":3725,"drift":["/d/eval.jsonl"],"tail":"..."}},
          {"id":"e3","time":"2026-07-11T17:01:00Z","author":"human","kind":"decision","data":{"approve":true}},
          {"id":"e4","time":"2026-07-11T17:02:00Z","author":"human","kind":"hide","data":{"target":"e9"}},
          "not an event"
        ]}
        """
        let events = try JSONDecoder().decode(LabEventsResponse.self, from: Data(json.utf8)).events?.compactMap(\.value) ?? []
        XCTAssertEqual(events.count, 4, "a malformed element is dropped, not fatal")
        let detail = LabRunDetail(events: events)
        XCTAssertEqual(detail.envelope?.argv, ["python", "train.py"])
        XCTAssertEqual(detail.envelope?.params, [])
        XCTAssertEqual(detail.envelope?.dataFiles.first?.sha256, "abc")
        XCTAssertEqual(detail.envelope?.snapshot?.patchBytes, 42)
        XCTAssertEqual(LabEnvFacts.summary(detail.envelope?.env), "Python 3.11 · linux")
        XCTAssertEqual(detail.end?.exitCode, 2)
        XCTAssertEqual(LabFormat.duration(detail.end?.durationSec), "1h 2m")
        XCTAssertEqual(detail.end?.drift, ["/d/eval.jsonl"])
        XCTAssertNil(events[2].data?.target)
        XCTAssertEqual(events[3].data?.target, "e9")
    }

    func testUnattendedStateAndHubNotes() throws {
        let u = try JSONDecoder().decode(LabUnattendedState.self, from: Data(#"{"enabled":true,"updatedAt":1752249600000}"#.utf8))
        XCTAssertTrue(u.enabled)
        XCTAssertEqual(u.updatedAt, 1_752_249_600_000)
        let notes = try JSONDecoder().decode(LabNotesResponse.self, from: Data(#"{"store":"abc","notes":[{"scope":"global","id":"n1","time":"t","author":"human","text":"x","hidden":true}]}"#.utf8))
        XCTAssertEqual(notes.store, "abc")
        XCTAssertEqual(notes.notes?.compactMap(\.value).first?.hidden, true)
    }

    func testRFC3339AndAgo() {
        let now = LabTime.date("2026-07-11T18:00:00Z")!
        XCTAssertEqual(LabTime.ago("2026-07-11T17:59:30Z", now: now), "now")
        XCTAssertEqual(LabTime.ago("2026-07-11T17:15:00Z", now: now), "45m")
        XCTAssertEqual(LabTime.ago("2026-07-11T13:00:00-02:00", now: now), "3h")
        XCTAssertEqual(LabTime.ago("2026-07-09T18:00:00.5Z", now: now), "1d")
        XCTAssertEqual(LabTime.ago("garbage", now: now), "garbage")
    }

    // MARK: Lifecycle

    func testPhaseMappingIsIndependentOfArchive() {
        let cases: [(String, LabPhase)] = [
            ("proposed (awaiting approval)", .needs), ("approved (launch with --proposal R3)", .approved),
            ("running (1h 02m)", .running), ("failed (exit 2)", .failed), ("stopped", .stopped),
            ("denied", .rejected), ("done", .finished), ("recorded", .recorded), ("", .recorded),
        ]
        for (status, phase) in cases { XCTAssertEqual(LabPhase.of(status), phase, status) }

        let stopped = LabRunSummary(id: "R2", status: "stopped", stoppedAt: "2026-07-16T03:00:00Z",
                                    stopReason: "wrapper disappeared", latestAt: "2026-07-15T22:00:00Z", archived: true)
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertEqual(stopped.activityAt(), "2026-07-16T03:00:00Z")
        XCTAssertEqual(LabRunSummary(id: "R12", status: "done").number, 12)
    }

    // MARK: Aggregation

    func testSharedBabelStoreProducesOneCopyAndRoutesToOwner() {
        let n5 = broker("babel-n5-24"), u5 = broker("babel-u5-24")
        let b = brief("s-93k08z", "babel-n5-24")
        let pending = LabKeyInfo(key: "pending-key-full-secret", project: "vlm_gating", machine: "babel-n5-24",
                                 cwd: "/shared/vlm_gating", session: "vlm_gating", status: "pending", created: "2026-07-11T16:00:00Z")
        var active = pending
        active.key = "active-key"; active.set = "s-93k08z"; active.status = "active"; active.created = "2026-07-11T15:00:00Z"
        let proposal = LabProposal(set: "s-93k08z", run: "R3", project: "vlm_gating", machine: "babel-u5-24",
                                   intent: "compare router loss", tier: "full", group: "ablation",
                                   argv: ["python", "train.py"], cwd: "/shared/vlm_gating", created: "2026-07-11T17:00:00Z")
        let global = LabHubNote(scope: "global", id: "global-1", time: "2026-07-10T00:00:00Z", author: "human", text: "show the full parameters")
        let snaps = [
            LabBrokerSnapshot(broker: n5, reportedStoreID: "one-nfs-store", briefs: [b], keys: [pending, active], proposals: [proposal], notes: [global]),
            LabBrokerSnapshot(broker: u5, reportedStoreID: "one-nfs-store", briefs: [b], keys: [pending, active], proposals: [proposal], notes: [global]),
        ]
        let r = LabAggregator.aggregate(snaps)
        XCTAssertEqual(r.sets.count, 1)
        XCTAssertEqual(r.pendingKeys.count, 1)
        XCTAssertEqual(r.pendingRuns.count, 1)
        XCTAssertEqual(r.notes.count, 2, "machine guidance stays addressable per node")
        XCTAssertEqual(r.sets[0].broker.labBrokerID, n5.labBrokerID)
        XCTAssertEqual(r.pendingKeys[0].broker.labBrokerID, n5.labBrokerID)
        XCTAssertEqual(r.pendingRuns[0].broker.labBrokerID, u5.labBrokerID, "terminal/data routing follows the proposing machine")
        XCTAssertEqual(r.sets[0].storeID, "shared:babel")
        XCTAssertEqual(r.activeKeyBySet[r.sets[0].id], "active-key")

        // Attention: newest first, Android reference/summary strings and ids.
        XCTAssertEqual(r.attention.map(\.kind), [.proposal, .key])
        XCTAssertEqual(r.attention[0].summary, "compare router loss")
        XCTAssertEqual(r.attention[0].reference, "R3")
        XCTAssertEqual(r.attention[0].targetID, "ut-babel-u5-24.example.ts.net/s-93k08z/R3")
        XCTAssertEqual(r.attention[0].id, "proposal/ut-babel-u5-24.example.ts.net/s-93k08z/R3")
        XCTAssertEqual(r.attention[1].reference, "ACCESS")
        XCTAssertEqual(r.attention[1].summary, "Approve agent access to a new isolated experiment set.")
        XCTAssertEqual(r.attention[1].targetID, "ut-babel-n5-24.example.ts.net/pending-key-full-secret", "full key, not the 8-char prefix")
        XCTAssertEqual(r.attention[1].id, "key/ut-babel-n5-24.example.ts.net/pending-key-full-secret")
        XCTAssertEqual(r.attention[1].created, LabTime.date("2026-07-11T16:00:00Z"))
        XCTAssertEqual(r.attention[1].machineName, "babel-n5-24")
    }

    func testBlankIntentFallsBackToReviewCopy() {
        let p = LabProposal(set: "s", run: "R1", project: "p", machine: "alpha", intent: "  ", created: "2026-07-11T17:00:00Z")
        let r = LabAggregator.aggregate([LabBrokerSnapshot(broker: broker("alpha"), reportedStoreID: "a", briefs: [], keys: [], proposals: [p], notes: [])])
        XCTAssertEqual(r.attention.first?.summary, "Review this experiment before it starts.")
    }

    func testSameRecordOnIndependentStoresRemainsIndependent() {
        let r = LabAggregator.aggregate([
            LabBrokerSnapshot(broker: broker("alpha"), reportedStoreID: "store-a", briefs: [brief("s-same", "alpha")], keys: [], proposals: [], notes: []),
            LabBrokerSnapshot(broker: broker("beta"), reportedStoreID: "store-b", briefs: [brief("s-same", "beta")], keys: [], proposals: [], notes: []),
        ])
        XCTAssertEqual(r.sets.count, 2)
        XCTAssertEqual(Set(r.sets.map(\.storeID)), ["store:store-a", "store:store-b"])
    }

    func testReportedSharedStoreDeduplicatesNonBabelPeersAndRoutesByMachine() {
        let alpha = broker("alpha"), beta = broker("beta")
        let shared = brief("s-shared", "ut-beta.example.ts.net")   // owner reported as a broker host
        let r = LabAggregator.aggregate([
            LabBrokerSnapshot(broker: alpha, reportedStoreID: "cluster-store", briefs: [shared], keys: [], proposals: [], notes: []),
            LabBrokerSnapshot(broker: beta, reportedStoreID: " cluster-store ", briefs: [shared], keys: [], proposals: [], notes: []),
        ])
        XCTAssertEqual(r.sets.count, 1)
        XCTAssertEqual(r.sets[0].storeID, "store:cluster-store")
        XCTAssertEqual(r.sets[0].broker.labBrokerID, beta.labBrokerID)
    }

    func testStoreKeyFallbacks() {
        XCTAssertEqual(LabAggregator.storeKey(broker("babel-n5-24"), reported: "x"), "shared:babel")
        let hostOnly = Machine(id: "h", name: "gpu box", os: "linux",
                               httpBase: URL(string: "https://ut-babel-s9-20.t.ts.net:8722")!, wsBase: URL(string: "wss://x")!)
        XCTAssertEqual(LabAggregator.storeKey(hostOnly, reported: nil), "shared:babel", "the host name also identifies the cluster")
        XCTAssertEqual(LabAggregator.storeKey(broker("alpha"), reported: "  "), "machine:ut-alpha.example.ts.net")
        XCTAssertEqual(LabAggregator.storeKey(broker("alpha"), reported: "abc"), "store:abc")
        XCTAssertEqual(LabAggregator.storeKey(broker("babelfish"), reported: nil), "machine:ut-babelfish.example.ts.net")
    }

    func testBabelPrefixDeduplicatesWithoutStoreIdentityAndFullerReplicaWins() {
        var fuller = brief("s-shared", "babel-n5-24")
        fuller.runs.append(LabRunSummary(id: "R3", status: "done", started: "2026-07-11T18:00:00Z"))
        let r = LabAggregator.aggregate([
            LabBrokerSnapshot(broker: broker("babel-n5-24"), reportedStoreID: nil, briefs: [brief("s-shared", "babel-n5-24")], keys: [], proposals: [], notes: nil),
            LabBrokerSnapshot(broker: broker("babel-u5-24"), reportedStoreID: nil, briefs: [fuller], keys: [], proposals: [], notes: nil),
        ])
        XCTAssertEqual(r.sets.count, 1)
        XCTAssertEqual(r.sets[0].storeID, "shared:babel")
        XCTAssertEqual(r.sets[0].brief.runs.count, 2, "a lagging NFS replica never hides runs")
        XCTAssertTrue(r.notes.isEmpty, "an unreachable notes endpoint is not an empty answer")
    }

    func testActiveKeyOutranksPendingReplica() {
        let pending = LabKeyInfo(key: "k1", project: "p", machine: "alpha", cwd: "/", status: "pending", created: "2026-07-11T10:00:00Z")
        var active = pending
        active.status = "active"; active.set = "s-1"
        let r = LabAggregator.aggregate([
            LabBrokerSnapshot(broker: broker("alpha"), reportedStoreID: "s", briefs: [brief("s-1", "alpha")], keys: [pending], proposals: [], notes: []),
            LabBrokerSnapshot(broker: broker("beta"), reportedStoreID: "s", briefs: [], keys: [active], proposals: [], notes: []),
        ])
        XCTAssertTrue(r.pendingKeys.isEmpty, "a replica that already saw the decision wins")
        XCTAssertTrue(r.attention.isEmpty)
        XCTAssertEqual(r.activeKeyBySet.values.first, "k1")
    }

    func testNewestResultActivityOrdersSets() {
        var stale = brief("s-stale", "alpha")
        stale.set.created = "2026-07-12T12:00:00Z"
        stale.runs = [LabRunSummary(id: "R1", status: "done", started: "2026-07-12T12:10:00Z", latest: "old", latestAt: "2026-07-12T12:20:00Z")]
        var updated = brief("s-updated", "alpha")
        updated.set.created = "2026-07-11T12:00:00Z"
        updated.runs = [LabRunSummary(id: "R1", status: "done", started: "2026-07-11T12:10:00Z", latest: "fresh", latestAt: "2026-07-12T13:00:00Z")]
        let r = LabAggregator.aggregate([
            LabBrokerSnapshot(broker: broker("alpha"), reportedStoreID: "alpha-store", briefs: [stale, updated], keys: [], proposals: [], notes: []),
        ])
        XCTAssertEqual(r.sets.map(\.brief.set.id), ["s-updated", "s-stale"])
    }

    func testNewestOfflineMirrorWinsAndOnlineOwnerSuppressesIt() {
        let mac = Machine(id: "hub:mac", name: "this mac", os: "darwin",
                          httpBase: URL(string: "http://100.64.0.1:8722")!, wsBase: URL(string: "ws://100.64.0.1:8722")!, isHub: true)
        let old = LabMirrored(machine: "alpha", set: "s-one", updated: "2026-07-10T00:00:00Z", brief: brief("s-one", "alpha"))
        var fresh = old
        fresh.updated = "2026-07-11T00:00:00Z"
        var otherDir = old   // the same NFS set mirrored under another peer's directory
        otherDir.machine = "ut-alpha.example.ts.net"

        let offline = LabAggregator.aggregate([], mirrored: [old, fresh, otherDir], mirrorBroker: mac)
        XCTAssertEqual(offline.sets.count, 1)
        XCTAssertTrue(offline.sets[0].offline)
        XCTAssertEqual(offline.sets[0].mirroredAt, fresh.updated)
        XCTAssertEqual(offline.sets[0].storeID, "mirror/alpha")
        XCTAssertEqual(offline.sets[0].broker.labBrokerID, "100.64.0.1")

        XCTAssertTrue(LabAggregator.aggregate([], mirrored: [fresh], mirrorBroker: nil).sets.isEmpty, "no Mac, no mirror cards")

        let online = LabAggregator.aggregate(
            [LabBrokerSnapshot(broker: broker("alpha"), reportedStoreID: "alpha-store", briefs: [brief("s-one", "alpha")], keys: [], proposals: [], notes: [])],
            mirrored: [fresh], mirrorBroker: mac)
        XCTAssertEqual(online.sets.count, 1)
        XCTAssertFalse(online.sets[0].offline)
    }

    // MARK: Guidance

    func testEverywhereBroadcastIsShownOnceAcrossStores() {
        let a = LabNotesGroup(storeID: "store:a", broker: broker("alpha"), machineName: "alpha", notes: [
            LabHubNote(scope: "global", id: "g1", time: "2026-07-11T10:00:00Z", author: "human", text: "use  the\nshared split"),
            LabHubNote(scope: "machine", id: "m1", time: "2026-07-11T09:00:00Z", author: "human", text: "alpha only"),
        ])
        let b = LabNotesGroup(storeID: "store:b", broker: broker("beta"), machineName: "beta", notes: [
            LabHubNote(scope: "global", id: "g7", time: "2026-07-11T10:01:00Z", author: "human", text: "use the shared split", hidden: true),
            LabHubNote(scope: "global", id: "g8", time: "2026-07-11T12:00:00Z", author: "human", text: "use the shared split"),
        ])
        let scopes = LabGuidance.scopes(notes: [a, b], sets: [])
        let all = LabGuidance.notes([a, b], scope: scopes[0])
        XCTAssertEqual(all.count, 2, "two minutes apart merges; two hours apart is a new instruction")
        let merged = all.first { $0.replicas.count == 2 }!
        XCTAssertEqual(merged.note.time, "2026-07-11T10:01:00Z")
        XCTAssertFalse(merged.note.hidden, "hidden only when every replica is hidden")

        let machine = scopes.first { $0.key == "machine:\(a.id)" }!
        let alphaNotes = LabGuidance.notes([a, b], scope: machine)
        XCTAssertEqual(Set(alphaNotes.map(\.note.id)), ["g1", "m1"])
    }

    // MARK: Parameter delta, Markdown, encoding

    func testParameterDeltaIsLiteral() {
        let d = LabParameterDelta("lr: 1e-4\nbatch: 32\n\nseed: 1", "lr: 3e-4\nbatch: 32\nseed: 1")
        XCTAssertEqual(d.onlyA, ["lr: 1e-4"])
        XCTAssertEqual(d.onlyB, ["lr: 3e-4"])
        XCTAssertTrue(LabParameterDelta("a\n\nb", "b\na").identical)
    }

    func testMarkdownBlocksAndPlainText() {
        let md = """
        # Result
        Routed **acc@100** improved `11.6pp`.
        continues here

        - one
        2. two
        > quoted
        ```
        code | not table
        ```
        | a | b |
        |---|:---:|
        | 1 | 2 |
        ---
        """
        XCTAssertEqual(LabMarkdown.parse(md), [
            .heading(1, "Result"),
            .paragraph("Routed **acc@100** improved `11.6pp`. continues here"),
            .bullets(["one", "two"]),
            .quote("quoted"),
            .code("code | not table"),
            .table([["a", "b"], ["1", "2"]]),
            .rule,
        ])
        XCTAssertEqual(LabMarkdown.plainText("## Done\n**11.6pp** with [link](https://x.y)"), "Done 11.6pp with link")
    }

    func testMutationQueryEscapesPlusAndAmpersand() {
        let url = LabNet.url(broker("alpha"), "lab/note", [("scope", "run"), ("text", "lr 1e-4 + warmup & decay=0")])
        XCTAssertEqual(url.absoluteString,
                       "https://ut-alpha.example.ts.net:8722/lab/note?scope=run&text=lr%201e-4%20%2B%20warmup%20%26%20decay%3D0")
    }

    // MARK: Fixtures

    private func broker(_ name: String) -> Machine {
        Machine(id: "ut-\(name).example.ts.net", name: name, os: "linux",
                httpBase: URL(string: "https://ut-\(name).example.ts.net:8722")!,
                wsBase: URL(string: "wss://ut-\(name).example.ts.net:8722")!)
    }

    private func brief(_ set: String, _ machine: String) -> LabBrief {
        LabBrief(set: LabSetMeta(id: set, project: "vlm_gating", machine: machine, cwd: "/shared/vlm_gating", created: "2026-07-11T15:00:00Z"),
                 runs: [LabRunSummary(id: "R2", group: "ablation", tier: "full", status: "running",
                                      started: "2026-07-11T16:00:00Z", latest: "healthy")])
    }
}
