import Foundation
import Combine

/// Wire records intentionally retain unknown fields in `data`. Native screens
/// cannot erase another client's fields merely by decoding an older model.
public struct SharedWorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    public var collection: String
    public var id: String
    public var revision: UInt64
    public var data: ArgusJSON?
    public var deleted: Bool?
    public var updatedAt: Int64?
    public var key: String { collection + "\0" + id }
    public init(collection: String, id: String, revision: UInt64 = 0, data: ArgusJSON? = nil, deleted: Bool = false) {
        self.collection = collection; self.id = id; self.revision = revision; self.data = data; self.deleted = deleted
    }
}

public struct SharedWorkspaceMutation: Codable, Equatable, Identifiable, Sendable {
    public var mutationID: String
    public var collection: String
    public var id: String
    public var baseRevision: UInt64
    public var data: ArgusJSON?
    public var delete: Bool
    public var baseData: ArgusJSON?
    public var conflict: String?
    public var lease: ArgusJSON?
    public var key: String { collection + "\0" + id }
    public var wire: ArgusJSON {
        var fields = (try? ArgusJSON.encode(self).object) ?? [:]
        fields["baseData"] = nil; fields["conflict"] = nil
        return .object(fields)
    }
}

public struct SharedWorkspaceHTTPError: Error, LocalizedError, Sendable {
    public let status: Int
    public let document: ArgusJSON
    public var errorDescription: String? { document["message"].string ?? document["error"].string ?? "Workspace request failed (HTTP \(status))" }
    public init(status: Int, document: ArgusJSON) { self.status = status; self.document = document }
}

public extension ArgusJSON {
    var uint64: UInt64? {
        guard case .number(let number) = self, number.isFinite, number >= 0, number < 9_007_199_254_740_992, number.rounded() == number else { return nil }
        return UInt64(number)
    }
}

/// Durable native replica. A mutation receipt updates the record, never the
/// change-stream cursor: intervening commits by another client must be replayed.
@MainActor
public final class SharedWorkspaceReplica: ObservableObject {
    public typealias Transport = (String, String, ArgusJSON?) async throws -> ArgusJSON
    private struct State: Codable {
        var workspaceID: String
        var cursor: UInt64 = 0
        var loaded = false
        var records: [SharedWorkspaceRecord] = []
        var pending: [SharedWorkspaceMutation] = []
    }
    @Published public private(set) var workspaceID = ""
    @Published public private(set) var records: [SharedWorkspaceRecord] = []
    @Published public private(set) var pending: [SharedWorkspaceMutation] = []
    @Published public private(set) var issue: String?
    @Published public private(set) var syncing = false
    @Published public private(set) var loaded = false
    @Published public private(set) var lastSyncedAt: Date?
    private let directory: URL?
    private let transport: Transport
    private var state = State(workspaceID: "")
    private var storageFailure = false
    private var retryAt = Date.distantPast
    public var onChange: (() -> Void)?

    public init(directory: URL?, transport: @escaping Transport) {
        self.directory = directory; self.transport = transport
    }

    public func bind(_ id: String) throws {
        guard id != workspaceID else { return }
        guard !syncing, !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else {
            throw ArgusFailure("invalid_workspace", "Invalid workspace identity or synchronization in progress.")
        }
        workspaceID = id; storageFailure = false; issue = nil; retryAt = .distantPast
        defer { onChange?() }
        install(State(workspaceID: id))
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode(State.self, from: ArgusWire.readFile(url, limit: 64 * 1024 * 1024))
            guard saved.workspaceID == id else { throw ArgusFailure("identity_mismatch", "Workspace cache identity mismatch.") }
            install(saved)
        } catch {
            storageFailure = true
            issue = "Workspace cache could not be read. The saved copy has been retained."
            throw error
        }
    }

    private var fileURL: URL? { directory?.appendingPathComponent(workspaceID + ".json") }
    public func record(_ collection: String, _ id: String) -> SharedWorkspaceRecord? {
        records.first { $0.collection == collection && $0.id == id }
    }
    public func data(_ collection: String, _ id: String) -> ArgusJSON? {
        if let mutation = pending.last(where: { $0.collection == collection && $0.id == id }) {
            return mutation.delete ? nil : mutation.data
        }
        guard let record = record(collection, id), record.deleted != true else { return nil }
        return record.data
    }
    public func collection(_ name: String) -> [SharedWorkspaceRecord] {
        var result = Dictionary(uniqueKeysWithValues: records.filter { $0.collection == name }.map { ($0.id, $0) })
        for operation in pending where operation.collection == name {
            result[operation.id] = SharedWorkspaceRecord(collection: name, id: operation.id, revision: operation.baseRevision,
                                                        data: operation.data, deleted: operation.delete)
        }
        return result.values.filter { $0.deleted != true }.sorted { $0.id < $1.id }
    }

    @discardableResult
    public func enqueue(_ collection: String, id: String, data value: ArgusJSON?, delete: Bool = false, lease: ArgusJSON? = nil,
                        baseRevision: UInt64? = nil, baseData: ArgusJSON? = nil) throws -> String {
        guard loaded, !workspaceID.isEmpty, !storageFailure else {
            throw ArgusFailure("workspace_unavailable", "Connect this workspace before editing shared state.")
        }
        let operation = SharedWorkspaceMutation(mutationID: UUID().uuidString, collection: collection, id: id,
                                                baseRevision: baseRevision ?? record(collection, id)?.revision ?? 0, data: value,
                                                delete: delete, baseData: baseData ?? data(collection, id), lease: lease)
        var next = state; next.pending.append(operation); try commit(next)
        return operation.mutationID
    }

    public func resolve(_ mutationID: String, keepLocal: Bool) throws {
        guard let operation = pending.first(where: { $0.mutationID == mutationID }), operation.conflict != nil else {
            throw ArgusFailure("conflict_changed", "The operation has no conflict to resolve.")
        }
        let current = record(operation.collection, operation.id)
        var next = state
        guard let index = next.pending.firstIndex(where: { $0.mutationID == mutationID }) else { return }
        if keepLocal {
            var replacement = operation; replacement.mutationID = UUID().uuidString; replacement.conflict = nil
            replacement.baseRevision = current?.revision ?? 0; replacement.baseData = current?.data
            next.pending[index] = replacement
        } else { next.pending.remove(at: index) }
        try commit(next)
    }

    public func synchronize(base: String, force: Bool = false) async {
        guard !syncing, !workspaceID.isEmpty, !storageFailure, force || Date() >= retryAt else { return }
        syncing = true
        defer { syncing = false; onChange?() }
        do {
            let info = try await transport(base, "/workspace/info", nil)
            guard info["protocol"].uint64 == 1, info["workspaceID"].string == workspaceID, info["enabled"].bool == true else {
                throw ArgusFailure("identity_mismatch", "The selected host is not this workspace. Choose its original host.")
            }
            if !loaded {
                try acceptSnapshot(await transport(base, "/workspace/snapshot", nil))
            } else {
                do {
                    for _ in 0..<10 {
                        let page = try await transport(base, "/workspace/changes?after=\(state.cursor)&limit=500", nil)
                        try acceptChanges(page)
                        if page["more"].bool != true { break }
                    }
                } catch let error as SharedWorkspaceHTTPError where error.status == 410 {
                    try acceptSnapshot(await transport(base, "/workspace/snapshot", nil))
                }
            }
            var blocked: Set<String> = []
            for operation in pending {
                if operation.conflict != nil || blocked.contains(operation.key) { blocked.insert(operation.key); continue }
                do {
                    let receipt = try await transport(base, "/workspace/mutate", operation.wire)
                    guard receipt["mutationID"].string == operation.mutationID else {
                        throw ArgusFailure("invalid_receipt", "Mismatched mutation receipt.")
                    }
                    let record = try receipt["record"].decode(SharedWorkspaceRecord.self)
                    guard record.key == operation.key, record.revision > operation.baseRevision else {
                        throw ArgusFailure("invalid_receipt", "The mutation receipt does not identify the committed record.")
                    }
                    var next = state
                    Self.merge(&next, record)
                    next.pending.removeAll { $0.mutationID == operation.mutationID }
                    try commit(next)
                } catch let error as SharedWorkspaceHTTPError where error.status == 409 && error.document["current"].object != nil {
                    try reconcile(operation, current: error.document["current"].decode(SharedWorkspaceRecord.self))
                    blocked.insert(operation.key)
                }
            }
            lastSyncedAt = Date(); issue = nil; retryAt = .distantPast
        } catch {
            issue = error.localizedDescription; retryAt = Date().addingTimeInterval(15)
        }
    }

    public func acceptSnapshot(_ snapshot: ArgusJSON) throws {
        guard snapshot["workspaceID"].string == workspaceID, let cursor = snapshot["cursor"].uint64,
              cursor >= state.cursor else { throw ArgusFailure("invalid_snapshot", "Workspace identity or revision changed; existing data is retained.") }
        var next = state
        next.records = try snapshot["records"].decode([SharedWorkspaceRecord].self)
        guard Set(next.records.map(\.key)).count == next.records.count,
              next.records.allSatisfy({ $0.revision > 0 && $0.revision <= cursor }) else {
            throw ArgusFailure("invalid_snapshot", "Workspace snapshot records are inconsistent.")
        }
        next.cursor = cursor; next.loaded = true
        for record in records where record.revision > cursor { Self.merge(&next, record) }
        try commit(next)
    }

    public func acceptChanges(_ page: ArgusJSON) throws {
        guard let cursor = page["cursor"].uint64, cursor >= state.cursor else {
            throw ArgusFailure("invalid_cursor", "Out-of-order workspace change page.")
        }
        var next = state
        for record in try page["records"].decode([SharedWorkspaceRecord].self) {
            guard record.revision > 0, record.revision <= cursor else { throw ArgusFailure("invalid_cursor", "Workspace change records are inconsistent.") }
            Self.merge(&next, record)
        }
        next.cursor = cursor; try commit(next)
    }

    private func reconcile(_ operation: SharedWorkspaceMutation, current: SharedWorkspaceRecord) throws {
        var next = state; Self.merge(&next, current)
        let remote = current.deleted == true ? ArgusJSON.null : (current.data ?? .null)
        let local = operation.delete ? ArgusJSON.null : (operation.data ?? .null)
        do {
            let merged: ArgusJSON
            if operation.collection == "session-read", let l = local["seenRevision"].uint64, let r = remote["seenRevision"].uint64 {
                merged = .object(["seenRevision": .number(Double(max(l, r)))])
            } else {
                merged = try WorkspaceMerge.merge(base: operation.baseData ?? .null, local: local, remote: remote)
            }
            next.pending.removeAll { $0.mutationID == operation.mutationID }
            if merged != remote {
                var replacement = operation
                replacement.mutationID = UUID().uuidString; replacement.baseRevision = current.revision
                replacement.baseData = remote; replacement.data = merged == .null ? nil : merged; replacement.delete = merged == .null
                next.pending.insert(replacement, at: 0)
            }
        } catch let error as ArgusFailure where error.code == "conflict" {
            if let index = next.pending.firstIndex(where: { $0.mutationID == operation.mutationID }) {
                next.pending[index].conflict = "Concurrent edits need review. Both copies are retained."
            }
        }
        try commit(next)
    }

    private static func merge(_ state: inout State, _ incoming: SharedWorkspaceRecord) {
        if let index = state.records.firstIndex(where: { $0.key == incoming.key }) {
            if incoming.revision >= state.records[index].revision { state.records[index] = incoming }
        } else { state.records.append(incoming) }
    }
    private func commit(_ next: State) throws {
        guard !storageFailure else { throw ArgusFailure("storage_failed", "Workspace storage requires repair; saved data has not been replaced.") }
        if let url = fileURL {
            let bytes = try ArgusWire.encoder().encode(next)
            guard bytes.count <= 64 * 1024 * 1024 else { throw ArgusFailure("store_full", "Workspace cache exceeds its storage limit.") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        install(next); onChange?()
    }
    private func install(_ next: State) {
        state = next; records = next.records; pending = next.pending; loaded = next.loaded
    }
}
