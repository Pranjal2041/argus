import Foundation
import ArgusProtocol

@MainActor
final class SharedArtifacts {
    private struct Baseline: Codable {
        var local: ArgusJSON?
        var remote: SharedWorkspaceRecord?
    }
    private weak var app: AppState?
    private weak var coordinator: SharedWorkspaceCoordinator?
    private let library: ArtifactStore
    private var baselines: [String: Baseline] = [:]
    private var boundID = ""
    private var nextAttempt = Date.distantPast
    private(set) var busy = false
    private(set) var issue: String?
    var canSwitch: Bool { !busy && !library.isLoading && library.activeOperations == 0 }

    init(app: AppState, coordinator: SharedWorkspaceCoordinator, library: ArtifactStore) {
        self.app = app; self.coordinator = coordinator; self.library = library
        library.recordsChanged = { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard !busy, !library.isLoading, let coordinator, !coordinator.replica.workspaceID.isEmpty,
              boundID != coordinator.replica.workspaceID || Date() >= nextAttempt else { return }
        busy = true
        let workspace = coordinator.replica.workspaceID
        Task {
            defer { busy = false; app?.objectWillChange.send() }
            do {
                try await library.bindWorkspace(workspace)
                if boundID != workspace {
                    let file = library.rootURL.appendingPathComponent("shared-baselines.json")
                    baselines = FileManager.default.fileExists(atPath: file.path)
                        ? try JSONDecoder().decode([String: Baseline].self, from: Data(contentsOf: file)) : [:]
                    boundID = workspace
                }
                guard coordinator.replica.loaded, let host = coordinator.host, host.workspaceID == workspace else {
                    issue = "Showing this workspace's cached artifacts while its host reconnects."
                    return
                }
                try await reconcile(base: host.httpBase, workspace: workspace)
                issue = nil; nextAttempt = .distantPast
            } catch { issue = error.localizedDescription; nextAttempt = Date().addingTimeInterval(15) }
        }
    }

    private func saveBaselines() throws {
        try JSONEncoder().encode(baselines).write(to: library.rootURL.appendingPathComponent("shared-baselines.json"), options: .atomic)
    }

    private func reconcile(base: String, workspace: String) async throws {
        guard let coordinator else { return }
        let replica = coordinator.replica
        let local = Dictionary(uniqueKeysWithValues: library.records.map { ($0.id.uuidString.lowercased(), $0) })
        let ids = Set(local.keys).union(replica.collection("artifacts").map(\.id)).union(baselines.keys)
        for id in ids.sorted() {
            guard replica.workspaceID == workspace, library.workspaceID == workspace else { return }
            let prior = baselines[id]
            let remote = replica.record("artifacts", id)
            let pending = replica.pending.contains { $0.collection == "artifacts" && $0.id == id }
            if let record = local[id] {
                let native = try ArgusJSON.encode(record)
                if native != prior?.local {
                    // Capture the common ancestor before uploading. Reading a
                    // newer remote revision afterward must not bless an overwrite.
                    let ancestor = prior?.remote
                    let ancestorData = pending ? replica.data("artifacts", id) : ancestor?.data
                    let data = try await export(record, base: base, original: ancestor?.data)
                    guard replica.workspaceID == workspace else { return }
                    try replica.enqueue("artifacts", id: id, data: data, baseRevision: ancestor?.revision ?? 0, baseData: ancestorData ?? .null)
                    baselines[id] = Baseline(local: native, remote: ancestor); try saveBaselines()
                } else if !pending, let remote, remote != prior?.remote {
                    if remote.deleted == true {
                        guard library.activeOperations == 0, library.records.first(where: { $0.id == record.id }) == record else {
                            throw ArgusFailure("local_artifact_changed", "A local artifact changed before deletion; syncing again preserves that edit.")
                        }
                        try await library.delete(record)
                        baselines[id] = Baseline(local: nil, remote: remote)
                    } else {
                        let imported = try await importRecord(remote, base: base, expectedLocal: record)
                        baselines[id] = Baseline(local: try .encode(imported), remote: remote)
                    }
                    try saveBaselines()
                }
            } else if prior?.local != nil {
                try replica.enqueue("artifacts", id: id, data: nil, delete: true,
                    baseRevision: prior?.remote?.revision ?? 0, baseData: (pending ? replica.data("artifacts", id) : prior?.remote?.data) ?? .null)
                baselines[id] = Baseline(local: nil, remote: prior?.remote); try saveBaselines()
            } else if !pending, let remote, remote.deleted != true {
                let imported = try await importRecord(remote, base: base, expectedLocal: nil)
                baselines[id] = Baseline(local: try .encode(imported), remote: remote); try saveBaselines()
            } else if !pending, remote?.deleted == true {
                baselines[id] = Baseline(local: nil, remote: remote); try saveBaselines()
            }
        }
    }

    private func export(_ record: ArtifactRecord, base: String, original: ArgusJSON?) async throws -> ArgusJSON {
        let url = library.fileURL(for: record)
        let bytes = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
        var data = original?.object ?? [:]
        data["hash"] = .string(try await WorkspaceBlobs.upload(bytes, base: base))
        data["record"] = try .encode(record)
        if let path = record.renderSourcePath {
            let sourceURL = library.rootURL.appendingPathComponent(path)
            let source = try await Task.detached(priority: .utility) { try Data(contentsOf: sourceURL) }.value
            data["sourceHash"] = .string(try await WorkspaceBlobs.upload(source, base: base))
        }
        if let machine = app?.machines.first(where: { $0.id == record.panel.machineID }), !machine.brokerID.isEmpty { data["brokerID"] = .string(machine.brokerID) }
        return .object(data)
    }

    private func importRecord(_ row: SharedWorkspaceRecord, base: String, expectedLocal: ArtifactRecord?) async throws -> ArtifactRecord {
        guard let data = row.data, let hash = data["hash"].string else { throw ArgusFailure("invalid_artifact", "A shared artifact is missing its content hash.") }
        var recordJSON = data["record"].object ?? [:]
        if let machine = app?.machines.first(where: { $0.brokerID == data["brokerID"].string }),
           var panel = recordJSON["panel"]?.object {
            panel["machineID"] = .string(machine.id); panel["machineName"] = .string(machine.name); panel["machineHost"] = .string(machine.host)
            recordJSON["panel"] = .object(panel)
        }
        let record = try ArgusJSON.object(recordJSON).decode(ArtifactRecord.self)
        guard record.id.uuidString.lowercased() == row.id else { throw ArgusFailure("invalid_artifact", "Artifact identity mismatch.") }
        let content: Data
        if let local = library.records.first(where: { $0.id == record.id }), let bytes = try? Data(contentsOf: library.fileURL(for: local)), WorkspaceBlobs.hash(bytes) == hash { content = bytes }
        else { content = try await WorkspaceBlobs.download(hash, base: base) }
        let source: Data?
        if let hash = data["sourceHash"].string { source = try await WorkspaceBlobs.download(hash, base: base) } else { source = nil }
        guard library.activeOperations == 0, library.records.first(where: { $0.id == record.id }) == expectedLocal else {
            throw ArgusFailure("local_artifact_changed", "A local artifact changed during download; syncing again preserves that edit.")
        }
        return try await library.importShared(record, content: content, source: source)
    }
}
