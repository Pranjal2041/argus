import XCTest
import ArgusProtocol

@MainActor
final class SharedWorkspaceReplicaTests: XCTestCase {
    private final class Server {
        var revision: UInt64 = 0
        var records: [String: SharedWorkspaceRecord] = [:]
        var receipts: [String: ArgusJSON] = [:]
        var offline = false
        var loseAcknowledgment = false
        var mutationCount = 0
        func call(_ base: String, _ path: String, _ body: ArgusJSON?) async throws -> ArgusJSON {
            if offline { throw URLError(.notConnectedToInternet) }
            if path == "/workspace/info" { return .object(["protocol": .number(1), "workspaceID": .string("test-workspace"), "enabled": .bool(true)]) }
            if path == "/workspace/snapshot" { return try snapshot() }
            if path.hasPrefix("/workspace/changes") {
                return .object(["cursor": .number(Double(revision)), "records": try .encode(Array(records.values)), "more": .bool(false)])
            }
            let mutation = try XCTUnwrap(body)
            let id = try XCTUnwrap(mutation["mutationID"].string)
            if let receipt = receipts[id] { return receipt }
            let collection = try XCTUnwrap(mutation["collection"].string), recordID = try XCTUnwrap(mutation["id"].string)
            let key = collection + "\0" + recordID
            let current = records[key] ?? SharedWorkspaceRecord(collection: collection, id: recordID)
            if current.revision != mutation["baseRevision"].uint64 {
                throw SharedWorkspaceHTTPError(status: 409, document: .object(["current": try .encode(current)]))
            }
            revision += 1; mutationCount += 1
            let record = SharedWorkspaceRecord(collection: collection, id: recordID, revision: revision,
                                               data: mutation["data"], deleted: mutation["delete"].bool ?? false)
            records[key] = record
            let receipt: ArgusJSON = .object(["mutationID": .string(id), "record": try .encode(record), "cursor": .number(Double(revision))])
            receipts[id] = receipt
            if loseAcknowledgment { loseAcknowledgment = false; throw URLError(.networkConnectionLost) }
            return receipt
        }
        func snapshot() throws -> ArgusJSON { .object(["workspaceID": .string("test-workspace"), "cursor": .number(Double(revision)), "records": try .encode(Array(records.values))]) }
    }

    func testLostAcknowledgmentSurvivesRelaunchWithoutDuplicateCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Server()
        var replica = SharedWorkspaceReplica(directory: root, transport: server.call)
        try replica.bind("test-workspace"); await replica.synchronize(base: "test")
        try replica.enqueue("session-backlog", id: "broker/lifetime", data: .object(["value": .bool(true)]))
        server.loseAcknowledgment = true
        await replica.synchronize(base: "test", force: true)
        XCTAssertEqual(replica.pending.count, 1)
        replica = SharedWorkspaceReplica(directory: root, transport: server.call)
        try replica.bind("test-workspace"); await replica.synchronize(base: "test", force: true)
        XCTAssertTrue(replica.pending.isEmpty)
        XCTAssertEqual(server.mutationCount, 1)
        XCTAssertEqual(replica.data("session-backlog", "broker/lifetime")?["value"].bool, true)
    }

    func testOfflineAndConflictingEditsPreserveBothCopies() async throws {
        let server = Server(), replica = SharedWorkspaceReplica(directory: nil, transport: { _, _, _ in .null })
        try replica.bind("test-workspace"); try replica.acceptSnapshot(server.snapshot())
        try replica.enqueue("notebooks", id: "n", data: .object(["name": .string("phone")]))
        server.revision = 1
        server.records["notebooks\0n"] = SharedWorkspaceRecord(collection: "notebooks", id: "n", revision: 1, data: .object(["name": .string("mac")]))
        try replica.acceptSnapshot(server.snapshot())
        XCTAssertEqual(replica.data("notebooks", "n")?["name"].string, "phone")
        XCTAssertEqual(replica.record("notebooks", "n")?.data?["name"].string, "mac")
        // A receipt for a newer write is not authority to skip earlier events.
        try replica.acceptChanges(.object(["cursor": .number(2), "records": .array([])]))
        XCTAssertThrowsError(try replica.acceptChanges(.object(["cursor": .number(1), "records": .array([])])))
    }

    func testResolvingEarlierConflictPreservesLaterQueuedEditOrder() async throws {
        let server = Server()
        server.revision = 1
        server.records["dashboards\0d"] = SharedWorkspaceRecord(collection: "dashboards", id: "d", revision: 1, data: .object(["name": .string("remote edit")]))
        // Drive a real 409 through synchronization rather than faking UI flags.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connected = SharedWorkspaceReplica(directory: root, transport: server.call)
        try connected.bind("test-workspace")
        try connected.acceptSnapshot(.object(["workspaceID": .string("test-workspace"), "cursor": .number(0), "records": .array([])]))
        try connected.enqueue("dashboards", id: "d", data: .object(["name": .string("first edit")]))
        try connected.enqueue("dashboards", id: "d", data: .object(["name": .string("later edit")]))
        await connected.synchronize(base: "test", force: true)
        let conflict = try XCTUnwrap(connected.pending.first { $0.conflict != nil })
        try connected.resolve(conflict.mutationID, keepLocal: true)
        XCTAssertEqual(connected.pending.last?.data?["name"].string, "later edit")
        await connected.synchronize(base: "test", force: true)
        await connected.synchronize(base: "test", force: true) // Rebased successor commits on the next sync.
        XCTAssertEqual(connected.data("dashboards", "d")?["name"].string, "later edit")
        XCTAssertTrue(connected.pending.isEmpty)
    }

    func testWorkspaceSwitchNotifiesAndSeparatesCachedPendingChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = SharedWorkspaceReplica(directory: root, transport: { _, _, _ in .null })
        try replica.bind("test-workspace")
        try replica.acceptSnapshot(Server().snapshot())
        try replica.enqueue("dashboards", id: "d", data: .object(["name": .string("A only")]))
        var changes = 0; replica.onChange = { changes += 1 }
        try replica.bind("other-workspace")
        XCTAssertEqual(changes, 1); XCTAssertNil(replica.data("dashboards", "d")); XCTAssertTrue(replica.pending.isEmpty)
        try replica.bind("test-workspace")
        XCTAssertEqual(replica.pending.count, 1); XCTAssertEqual(replica.data("dashboards", "d")?["name"].string, "A only")
    }
}
