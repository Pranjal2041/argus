import Foundation
import ArgusProtocol

struct WorkspaceSyncConflict: Codable, Identifiable {
    var id: String { key }
    var key: String
    var base: ArgusJSON
    var local: ArgusJSON
    var remote: ArgusJSON
    var paths: ArgusJSON
    var syncBase: ArgusJSON? = nil
}

@MainActor
final class WorkspaceSync: ObservableObject {
    struct State: Codable {
        var bases: [String: ArgusJSON] = [:]
        var conflicts: [String: WorkspaceSyncConflict] = [:]
        var pending: [String: Pending]? = nil
    }
    struct Pending: Codable {
        var before: ArgusJSON
        var merged: ArgusJSON
    }
    @Published private(set) var issues: [String: String] = [:]
    private(set) var state: State
    private let url: URL?
    private var inflight: Set<String> = []
    private var failedUntil: [String: Date] = [:]
    private var lastSynced: [String: Date] = [:]
    var onChange: (() -> Void)?
    init(url: URL?) {
        self.url = url
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                state = try JSONDecoder().decode(State.self, from: ArgusWire.readFile(url, limit: 40 * 1024 * 1024))
            } else { state = State() }
        } catch { state = State(); issues["store"] = "Sync baseline could not be read; sync is stopped: \(error.localizedDescription)" }
        for key in state.conflicts.keys { issues[key] = "Concurrent edits require review; both copies have been preserved." }
    }
    func summary(current: [String: ArgusJSON]) -> ArgusJSON {
        .object(Dictionary(uniqueKeysWithValues: current.map { key, value in
            (key, .object(["state": .string(state.conflicts[key] != nil ? "conflict" : (issues[key] != nil || issues["store"] != nil ? "error" : (state.bases[key] == value ? "synced" : "pending"))),
                "issue": (issues[key] ?? issues["store"]).map(ArgusJSON.string) ?? .null,
                "last_confirmed": lastSynced[key].map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null]))
        }))
    }
    func sync(key: String, host: String, read: @escaping () -> ArgusJSON, apply: @escaping (ArgusJSON) throws -> Void) {
        do {
            if let pending = state.pending?[key] {
                do {
                    let merged = try WorkspaceMerge.merge(base: pending.before, local: read(), remote: pending.merged)
                    try apply(merged)
                    var next = state; next.pending?[key] = nil; try save(next)
                } catch let error as ArgusFailure where error.code == "conflict" {
                    var next = state
                    next.conflicts[key] = WorkspaceSyncConflict(key: key, base: pending.before, local: read(), remote: pending.merged, paths: error.details)
                    next.conflicts[key]?.syncBase = state.bases[key]
                    next.pending?[key] = nil
                    try save(next)
                    issues[key] = "Interrupted sync conflicts with newer edits; review both preserved copies."
                    onChange?(); return
                }
            }
            if var conflict = state.conflicts[key], conflict.local != read() {
                conflict.local = read(); var next = state; next.conflicts[key] = conflict
                try save(next); onChange?()
            }
        } catch { issues[key] = "Interrupted sync needs review: \(error.localizedDescription)"; return }
        guard issues["store"] == nil, state.conflicts[key] == nil, !inflight.contains(key),
              failedUntil[key, default: .distantPast] <= Date(), let url = URL(string: host + "/userdata/merge?key=" + key) else { return }
        let base = state.bases[key] ?? .array([]), sent = read()
        inflight.insert(key)
        Task {
            defer { inflight.remove(key); onChange?() }
            do {
                var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 8
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try ArgusWire.encoder().encode(ArgusJSON.object(["base": base, "data": sent]))
                let (data, response) = try await brokerSession.data(for: request)
                let value = try JSONDecoder().decode(ArgusJSON.self, from: data)
                guard let response = response as? HTTPURLResponse else { throw ArgusFailure("sync_failed", "Invalid sync response.") }
                if response.statusCode == 409, value["current"].array != nil {
                    try conflict(key: key, base: base, local: read(), remote: value["current"], paths: value["conflicts"])
                    return
                }
                guard response.statusCode == 200, value["data"].array != nil else {
                    throw ArgusFailure("sync_failed", "Sync host returned HTTP \(response.statusCode). It must support /userdata/merge; local edits are retained.")
                }
                let remote = value["data"]
                do {
                    let merged = try WorkspaceMerge.merge(base: sent, local: read(), remote: remote)
                    // Persist the new baseline before adopting it in memory. A failed
                    // baseline write never silently becomes a successful sync.
                    var next = state; next.bases[key] = remote
                    if next.pending == nil { next.pending = [:] }
                    next.pending?[key] = Pending(before: read(), merged: merged)
                    if state.bases[key] != remote || read() != merged { try save(next) }
                    try apply(merged)
                    if state.pending?[key] != nil { var finished = state; finished.pending?[key] = nil; try save(finished) }
                    issues[key] = nil; failedUntil[key] = nil; lastSynced[key] = Date()
                } catch let error as ArgusFailure where error.code == "conflict" {
                    try conflict(key: key, base: sent, local: read(), remote: remote, paths: error.details)
                }
            } catch {
                issues[key] = error.localizedDescription; failedUntil[key] = Date().addingTimeInterval(30)
            }
        }
    }
    private func conflict(key: String, base: ArgusJSON, local: ArgusJSON, remote: ArgusJSON, paths: ArgusJSON) throws {
        var next = state; next.conflicts[key] = WorkspaceSyncConflict(key: key, base: base, local: local, remote: remote, paths: paths)
        try save(next); issues[key] = "Concurrent edits require review; both copies have been preserved."
    }
    /// A deliberate reconciliation becomes a normal three-way merge against the
    /// remote revision shown in the review, never an unconditional overwrite.
    func resolve(key: String, expectedRevision: String, current: ArgusJSON, merged: ArgusJSON,
                 validate: (ArgusJSON) throws -> Void, apply: (ArgusJSON) throws -> Void) throws {
        guard let conflict = state.conflicts[key],
              try ArgusJSON.encode(conflict).revision == expectedRevision, current == conflict.local else {
            throw ArgusFailure("conflict", "The conflict or local data changed. Read the conflict again before resolving it.")
        }
        guard merged.array != nil else { throw ArgusFailure("invalid_arguments", "Resolution must be a record array.") }
        try validate(merged)
        // Validate through the model before clearing the review entry.
        var next = state; next.bases[key] = conflict.syncBase ?? conflict.remote; next.conflicts[key] = nil
        if next.pending == nil { next.pending = [:] }
        next.pending?[key] = Pending(before: current, merged: merged)
        try save(next)
        try apply(merged)
        next.pending?[key] = nil; try save(next)
        issues[key] = nil; failedUntil[key] = nil; onChange?()
    }
    private func save(_ next: State) throws {
        let bytes = try ArgusWire.encoder().encode(next)
        guard bytes.count <= 40 * 1024 * 1024 else { throw ArgusFailure("sync_store_full", "Sync state exceeds its bounded storage size. Existing copies are preserved.") }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        state = next
    }
}
