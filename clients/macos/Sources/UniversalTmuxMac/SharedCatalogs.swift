import Foundation
import SwiftUI
import ArgusProtocol

@MainActor
final class SharedCatalogs: ObservableObject {
    private weak var app: AppState?
    private weak var coordinator: SharedWorkspaceCoordinator?
    private weak var dashboards: DashboardsModel?
    private weak var notebooks: NotebooksModel?
    @Published private(set) var dashboardsList: [SharedWorkspaceRecord] = []
    @Published var issue: String?
    private var applying = false
    private var installedWorkspace = ""
    private var knownNotebooks: Set<String> = []
    private var legacyNotebooks: [NotebookSession]
    private var legacyDashboardTabs: [DashboardTab]
    private let defaults: UserDefaults

    init(app: AppState, coordinator: SharedWorkspaceCoordinator, dashboards: DashboardsModel, notebooks: NotebooksModel, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.app = app; self.coordinator = coordinator; self.dashboards = dashboards; self.notebooks = notebooks
        legacyNotebooks = notebooks.notebooks; legacyDashboardTabs = dashboards.tabs
        for key in ["ut.openNotebooks.v1", "ut.dash.tabs.v1"] where defaults.data(forKey: key + ".before-shared") == nil {
            if let data = defaults.data(forKey: key) { defaults.set(data, forKey: key + ".before-shared") }
        }
        notebooks.catalogChanged = { [weak self] in self?.saveNotebooks() }
    }

    func reconcile() {
        guard !applying, let coordinator, let app, let notebooks else { return }
        applying = true; defer { applying = false }
        let replica = coordinator.replica
        if installedWorkspace != replica.workspaceID {
            knownNotebooks = []; installedWorkspace = replica.workspaceID
            dashboardsList = []; notebooks.installCatalog([])
        }
        guard replica.loaded else { return }
        do {
            if defaults.string(forKey: "ut.catalogs.migrationWorkspace") == nil {
                defaults.set(replica.workspaceID, forKey: "ut.catalogs.migrationWorkspace")
            }
            if !defaults.bool(forKey: "ut.catalogs.migrated"),
               defaults.string(forKey: "ut.catalogs.migrationWorkspace") == replica.workspaceID {
                var unresolved = false
                for notebook in legacyNotebooks {
                    guard let host = app.machines.first(where: { $0.id == notebook.machineID }), !host.brokerID.isEmpty else { unresolved = true; continue }
                    let id = notebook.id.uuidString.lowercased()
                    if replica.record("notebooks", id) == nil && replica.data("notebooks", id) == nil {
                        try replica.enqueue("notebooks", id: id, data: .object(["brokerID": .string(host.brokerID), "name": .string(notebook.name), "path": .string(notebook.path)]))
                    }
                }
                for tab in legacyDashboardTabs {
                    let id = tab.id.uuidString.lowercased()
                    if replica.record("dashboards", id) == nil && replica.data("dashboards", id) == nil,
                       let locator = try? locator(for: tab) {
                        var value = locator.object ?? [:]; value["name"] = .string(tab.displayTitle)
                        try replica.enqueue("dashboards", id: id, data: .object(value))
                    }
                }
                if !unresolved { defaults.set(true, forKey: "ut.catalogs.migrated") }
            }
            dashboardsList = replica.collection("dashboards").sorted { ($0.data?["name"].string ?? "") < ($1.data?["name"].string ?? "") }
            let entries = replica.collection("notebooks")
            var installed: [(UUID, String, String, String)] = []
            for row in entries {
                guard let id = UUID(uuidString: row.id), let value = row.data, let brokerID = value["brokerID"].string,
                      let path = value["path"].string, let name = value["name"].string else {
                    throw ArgusFailure("invalid_notebook", "A shared notebook has an unsupported format; existing tabs are retained.")
                }
                let machine = app.machines.first { $0.brokerID == brokerID }
                installed.append((id, machine?.id ?? "broker:" + brokerID, name, path))
            }
            knownNotebooks = Set(entries.map(\.id))
            if !defaults.bool(forKey: "ut.catalogs.migrated"),
               defaults.string(forKey: "ut.catalogs.migrationWorkspace") == replica.workspaceID {
                // An offline legacy host must not make an unmigrated notebook
                // disappear. Keep it visible until its stable identity resolves.
                for notebook in legacyNotebooks where !knownNotebooks.contains(notebook.id.uuidString.lowercased()) {
                    guard replica.record("notebooks", notebook.id.uuidString.lowercased()) == nil else { continue }
                    installed.append((notebook.id, notebook.machineID, notebook.name, notebook.path))
                }
            }
            notebooks.installCatalog(installed)
        } catch { issue = error.localizedDescription }
    }

    private func saveNotebooks() {
        guard !applying, let coordinator, let app, let notebooks, coordinator.replica.loaded else { return }
        applying = true; defer { applying = false }
        do {
            let replica = coordinator.replica
            var current = Set<String>()
            for notebook in notebooks.notebooks {
                let id = notebook.id.uuidString.lowercased(); current.insert(id)
                guard let machine = app.machines.first(where: { $0.id == notebook.machineID }), !machine.brokerID.isEmpty else { continue }
                var data = replica.data("notebooks", id)?.object ?? [:]
                data["brokerID"] = .string(machine.brokerID); data["name"] = .string(notebook.name); data["path"] = .string(notebook.path)
                if replica.data("notebooks", id) != .object(data) { try replica.enqueue("notebooks", id: id, data: .object(data)) }
            }
            for id in knownNotebooks.subtracting(current) { try replica.enqueue("notebooks", id: id, data: nil, delete: true) }
            legacyNotebooks.removeAll { !current.contains($0.id.uuidString.lowercased()) }
            knownNotebooks = current; coordinator.refresh()
        } catch { issue = error.localizedDescription }
    }

    private func locator(for tab: DashboardTab) throws -> ArgusJSON {
        guard let app, let url = tab.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ArgusFailure("missing_url", "This dashboard has no resolved address yet.")
        }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host ?? "") {
            let port = components.port ?? (components.scheme == "https" ? 443 : 80)
            let forward = dashboards?.forwards.first { $0.localPort == port }
            let local = app.machines.first(where: \.isLocal)
            let explicitlyLocal = tab.forwardKey == nil && ["manual", local?.name, local?.id].compactMap { $0 }.contains(tab.host)
            let machine = forward.flatMap { f in app.machines.first { $0.fwHost == f.brokerHost } } ?? (explicitlyLocal ? local : nil)
            guard let machine else { throw ArgusFailure("host_unavailable", "The service host is unavailable.") }
            let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            return try WorkspaceLocator.service(brokerID: machine.brokerID, port: forward?.remotePort ?? port,
                                                path: path.isEmpty ? "/" : path, scheme: components.scheme ?? "http")
        }
        return try WorkspaceLocator.website(url.absoluteString)
    }

    func saveCurrent() {
        guard let tab = dashboards?.active else { return }
        do {
            var fields = try locator(for: tab).object ?? [:]; fields["name"] = .string(tab.displayTitle)
            coordinator?.change("dashboards", id: tab.id.uuidString.lowercased(), data: .object(fields)); issue = nil
        } catch { issue = error.localizedDescription }
    }
    func remove(_ row: SharedWorkspaceRecord) { coordinator?.change("dashboards", id: row.id, data: nil, delete: true) }
    func rename(_ row: SharedWorkspaceRecord, to name: String) {
        var data = row.data?.object ?? [:]; data["name"] = .string(name)
        coordinator?.change("dashboards", id: row.id, data: .object(data))
    }
    func open(_ row: SharedWorkspaceRecord) {
        guard let data = row.data else { return }
        if data["kind"].string == "website", let url = data["url"].string {
            guard (try? WorkspaceLocator.website(url)) != nil else { issue = "This dashboard URL is not portable."; return }
            dashboards?.openURL(url, host: "workspace"); return
        }
        guard let machine = app?.machines.first(where: { $0.brokerID == data["brokerID"].string }),
              let port = data["port"].uint64, port > 0, port <= 65535 else { issue = "The service host is offline."; return }
        dashboards?.openLocalhost(on: machine, port: Int(port), path: data["path"].string ?? "/", scheme: data["scheme"].string ?? "http")
    }
}

struct SharedDashboardCatalogView: View {
    @ObservedObject var catalog: SharedCatalogs
    @State private var renaming: SharedWorkspaceRecord?
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace dashboards").font(.headline)
            Button("Save current dashboard") { catalog.saveCurrent() }
            if let issue = catalog.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            List(catalog.dashboardsList) { row in
                HStack {
                    Button(row.data?["name"].string ?? "Dashboard") { catalog.open(row) }.buttonStyle(.plain)
                    Spacer()
                    Button { name = row.data?["name"].string ?? ""; renaming = row } label: { Image(systemName: "pencil") }
                    Button(role: .destructive) { catalog.remove(row) } label: { Image(systemName: "trash") }
                }
            }.frame(height: 260)
        }.padding(16).frame(width: 440)
            .alert("Rename dashboard", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Save") { if let row = renaming { catalog.rename(row, to: name) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
    }
}
