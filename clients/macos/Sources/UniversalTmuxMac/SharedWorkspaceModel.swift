import Foundation
import SwiftUI
import ArgusProtocol
import UsageKit

func sharedWorkspaceRequest(_ base: String, _ path: String, _ body: ArgusJSON? = nil) async throws -> ArgusJSON {
    guard let url = URL(string: base + path) else { throw ArgusFailure("invalid_endpoint", "Invalid workspace endpoint.") }
    var request = URLRequest(url: url); request.timeoutInterval = path == "/workspace/service/usage" ? 50 : 20
    if let body {
        request.httpMethod = "POST"; request.httpBody = try ArgusWire.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await brokerSession.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ArgusFailure("invalid_response", "Invalid workspace response.") }
    let value = (try? JSONDecoder().decode(ArgusJSON.self, from: data)) ?? .null
    guard (200..<300).contains(response.statusCode) else { throw SharedWorkspaceHTTPError(status: response.statusCode, document: value) }
    guard value.object != nil else { throw ArgusFailure("invalid_response", "Invalid workspace JSON.") }
    return value
}

@MainActor
final class SharedWorkspaceCoordinator: ObservableObject {
    let replica: SharedWorkspaceReplica
    @Published private(set) var host: Machine?
    @Published private(set) var issue: String?
    private var refreshing = false
    private let enabled: Bool
    private var usageBound = false
    private var applyingUsage = false
    private var usageApplied: [String: ArgusJSON] = [:]
    private var usageWorkspaceID = ""
    private var usageMigration: [(String, Data)] = []
    @Published private(set) var catalogs: SharedCatalogs?
    private(set) var artifacts: SharedArtifacts?
    private weak var ledger: LedgerPanel?
    private weak var wrapped: WrappedPanel?
    weak var app: AppState?

    init(app: AppState, enabled: Bool) {
        self.app = app; self.enabled = enabled
        let root = enabled ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Argus/replicas") : nil
        replica = SharedWorkspaceReplica(directory: root, transport: sharedWorkspaceRequest)
        if enabled, let id = UserDefaults.standard.string(forKey: "ut.workspace.id") { try? replica.bind(id) }
        replica.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.app?.applySharedSessionMarks()
            self?.applyUsage()
            self?.catalogs?.reconcile()
            self?.artifacts?.refresh()
            self?.ledger?.refresh()
            self?.wrapped?.refresh()
        }
    }

    func refresh() {
        guard enabled, !refreshing, let app else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                if replica.workspaceID.isEmpty {
                    // This is the existing local sync host, not a guessed remote
                    // Mac. Enrollment is explicit and accepted only on loopback.
                    guard let local = app.machines.first(where: \.isLocal) else { return }
                    let info = try await sharedWorkspaceRequest(local.httpBase, "/workspace/enable", .object([:]))
                    guard let id = info["workspaceID"].string else { throw ArgusFailure("missing_identity", "Workspace host did not return an identity.") }
                    var enrolled = local
                    enrolled.workspaceID = id; enrolled.workspaceEnabled = true
                    enrolled.brokerID = info["brokerID"].string ?? ""
                    if let index = app.machines.firstIndex(where: { $0.id == local.id }) { app.machines[index] = enrolled }
                    try app.bindSharedWorkspace(enrolled)
                }
                host = app.machines.first { $0.workspaceID == replica.workspaceID && $0.workspaceEnabled }
                if host == nil, let local = app.machines.first(where: \.isLocal) {
                    let info = try await sharedWorkspaceRequest(local.httpBase, "/workspace/info")
                    if info["workspaceID"].string == replica.workspaceID, info["enabled"].bool == true {
                        var resolved = local; resolved.workspaceID = replica.workspaceID; resolved.workspaceEnabled = true
                        resolved.brokerID = info["brokerID"].string ?? ""
                        host = resolved
                        if let index = app.machines.firstIndex(where: { $0.id == local.id }) { app.machines[index] = resolved }
                    }
                }
                guard let host else { issue = "Workspace host is offline; cached data and pending changes are retained."; return }
                issue = nil
                await replica.synchronize(base: host.httpBase)
                if replica.loaded { app.migrateSharedSessionMarks(); app.applySharedSessionMarks(); applyUsage(); catalogs?.reconcile(); artifacts?.refresh() }
            } catch { issue = error.localizedDescription }
            app.objectWillChange.send()
        }
    }

    func select(_ machine: Machine) {
        guard !refreshing else { issue = "Wait for the current workspace sync to finish."; return }
        guard artifacts?.canSwitch != false else { issue = "Wait for the artifact transfer to finish before switching workspaces."; return }
        do { try app?.bindSharedWorkspace(machine); host = machine; issue = nil; refresh() }
        catch { issue = error.localizedDescription }
    }

    func change(_ collection: String, id: String, data: ArgusJSON?, delete: Bool = false) {
        do { try replica.enqueue(collection, id: id, data: data, delete: delete); issue = nil; refresh() }
        catch { issue = error.localizedDescription; app?.objectWillChange.send() }
    }

    func connectUsage() {
        guard !usageBound else { return }; usageBound = true
        if #available(macOS 14.0, *) {
            let usage = ArgusUsage.shared
            usage.stop()
            usageMigration = [("usage-settings", try? usage.sharedSettings()), ("usage-dismissals", try? usage.sharedDismissals())].compactMap { key, value in value.map { (key, $0) } }
            usage.remoteAccountRequest = { [weak self] data in
                guard let self, let host = self.host, host.workspaceID == self.replica.workspaceID else {
                    throw ArgusFailure("collector_offline", "The workspace collector is offline.")
                }
                let id = self.replica.workspaceID
                let reply = try await sharedWorkspaceRequest(host.httpBase, "/workspace/service/usage", JSONDecoder().decode(ArgusJSON.self, from: data))
                guard id == self.replica.workspaceID else { throw ArgusFailure("workspace_changed", "The selected workspace changed.") }
                return try ArgusWire.encoder().encode(reply)
            }
            usage.remoteRefresh = { [weak self] sourceID in
                var command: [String: ArgusJSON] = ["kind": .string("usage-refresh")]
                if let sourceID { command["sourceID"] = .string(sourceID) }
                self?.change("commands", id: UUID().uuidString, data: .object(command))
            }
            usage.sharedSettingsChanged = { [weak self, weak usage] in
                guard let self, !self.applyingUsage, let usage,
                      let data = try? JSONDecoder().decode(ArgusJSON.self, from: usage.sharedSettings()) else { return }
                self.change("usage-settings", id: "default", data: data)
            }
            usage.sharedDismissalsChanged = { [weak self, weak usage] in
                guard let self, !self.applyingUsage, let usage,
                      let data = try? JSONDecoder().decode(ArgusJSON.self, from: usage.sharedDismissals()) else { return }
                self.change("usage-dismissals", id: "default", data: data)
            }
        }
        applyUsage()
    }

    func connectCatalogs(dashboards: DashboardsModel, notebooks: NotebooksModel) {
        guard catalogs == nil, let app else { return }
        catalogs = SharedCatalogs(app: app, coordinator: self, dashboards: dashboards, notebooks: notebooks)
        catalogs?.reconcile()
    }

    func connectArtifacts(_ library: ArtifactStore) {
        guard artifacts == nil, let app else { return }
        artifacts = SharedArtifacts(app: app, coordinator: self, library: library)
        artifacts?.refresh()
    }

    func connectJournal(ledger: LedgerPanel, wrapped: WrappedPanel) {
        self.ledger = ledger; self.wrapped = wrapped
        ledger.workspace = self; wrapped.workspace = self
        ledger.refresh(); wrapped.refresh()
    }

    private func applyUsage() {
        guard usageBound, !applyingUsage else { return }
        applyingUsage = true; defer { applyingUsage = false }
        if #available(macOS 14.0, *) {
            let usage = ArgusUsage.shared
            if usageWorkspaceID != replica.workspaceID {
                // Resolve the authority before adopting the host's pre-service
                // cache. A different workspace must never inherit that cache.
                guard let authority = host.flatMap({ $0.workspaceID == replica.workspaceID ? $0 : nil })
                    ?? app?.machines.first(where: { $0.workspaceID == replica.workspaceID && $0.workspaceEnabled }) else {
                    if !usageWorkspaceID.isEmpty { usage.clearSharedPresentation() }
                    return
                }
                usageWorkspaceID = replica.workspaceID; usageApplied = [:]
                usage.bindSharedWorkspace(replica.workspaceID, isLocal: authority.isLocal)
            }
            guard replica.loaded else { return }
            do {
                // Existing host-owned preferences migrate once, without exporting
                // connection configuration or account credentials.
                if host?.isLocal == true, !UserDefaults.standard.bool(forKey: "ut.usage.workspace-migrated") {
                    for (collection, encoded) in usageMigration {
                        if replica.record(collection, "default") == nil && replica.data(collection, "default") == nil {
                            try replica.enqueue(collection, id: "default", data: JSONDecoder().decode(ArgusJSON.self, from: encoded))
                        }
                    }
                    UserDefaults.standard.set(true, forKey: "ut.usage.workspace-migrated")
                }
                for collection in ["usage-settings", "usage-dismissals", "usage"] {
                    let id = collection == "usage" ? "current" : "default"
                    guard let value = replica.data(collection, id), usageApplied[collection] != value else { continue }
                    let data = try ArgusWire.encoder().encode(value)
                    switch collection {
                    case "usage-settings": try usage.applySharedSettings(data)
                    case "usage-dismissals": try usage.applySharedDismissals(data)
                    default: try usage.applySharedSnapshot(data)
                    }
                    usageApplied[collection] = value
                }
            } catch { issue = "Usage sync: \(error.localizedDescription)" }
        }
    }
}

struct SharedWorkspaceSettingsView: View {
    @ObservedObject var app: AppState
    @ObservedObject var coordinator: SharedWorkspaceCoordinator
    @ObservedObject var replica: SharedWorkspaceReplica

    init(app: AppState) {
        self.app = app; coordinator = app.sharedWorkspace; replica = app.sharedWorkspace.replica
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared workspace").font(.headline)
            Picker("Host", selection: Binding(get: { replica.workspaceID }, set: { id in
                if let machine = app.machines.first(where: { $0.workspaceID == id && $0.workspaceEnabled }) { coordinator.select(machine) }
            })) {
                if replica.workspaceID.isEmpty { Text("Connecting…").tag("") }
                ForEach(app.machines.filter { $0.workspaceEnabled && !$0.workspaceID.isEmpty }) { machine in
                    Text(machine.name).tag(machine.workspaceID)
                }
            }
            Text(replica.syncing ? "Synchronizing…" : "\(replica.pending.count) pending changes")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = coordinator.issue ?? replica.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let issue = coordinator.artifacts?.issue { Text("Artifacts: " + issue).font(.caption).foregroundStyle(.orange) }
            ForEach(replica.pending.filter { $0.conflict != nil }, id: \.mutationID) { mutation in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(mutation.collection): concurrent edits need review").font(.caption)
                    HStack {
                        Button("Keep this edit") { try? replica.resolve(mutation.mutationID, keepLocal: true); coordinator.refresh() }
                        Button("Use shared version") { try? replica.resolve(mutation.mutationID, keepLocal: false) }
                    }
                }
            }
            Button("Sync now") { coordinator.refresh() }
        }
    }
}
