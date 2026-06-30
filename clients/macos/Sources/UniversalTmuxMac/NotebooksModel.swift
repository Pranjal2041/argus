import Foundation
import SwiftUI

// MARK: - one open notebook

/// An open JupyterLab: rooted at a FOLDER on a machine, shown in the MAIN detail pane as
/// the host's full JupyterLab (`/lab/tree/<folder>`), reached over the same port-forward
/// the Dashboards use. You create/open notebooks from the Lab launcher; the kernel runs on
/// that host (GPU node, right env), zero SSH — the terminal's value, for notebooks.
struct NotebookSession: Identifiable {
    let id: UUID
    let machineID: String
    var name: String
    let path: String          // absolute FOLDER path on the host that Lab is rooted at
    let tab: DashboardTab     // holds the resolved webview URL + WKWebView + load state

    @MainActor init(id: UUID = UUID(), machineID: String, name: String, path: String) {
        let t = DashboardTab(title: name, host: machineID, url: nil)
        t.persist = true       // keep the WKWebView alive across pane switches — no re-render
        self.id = id
        self.machineID = machineID
        self.name = name
        self.path = path
        self.tab = t
    }
}

/// The persistable shape of an open notebook — just the host + path (the live
/// `DashboardTab`/WKWebView is recreated on load). Mirrors how Todo boards persist a
/// plain Codable record separate from their live view state.
private struct NotebookRecord: Codable {
    let id: UUID
    let machineID: String
    let name: String
    let path: String
}

private struct NBForwardsResp: Decodable { let forwards: [PortForward]? }
private struct NBJupyterResp: Decodable { let port: Int; let token: String }

@MainActor
final class NotebooksModel: ObservableObject {
    @Published var notebooks: [NotebookSession] = []
    @Published var activeID: UUID?

    /// The local Mac broker is the forward hub (same as Dashboards/Ports).
    private let agent = "http://127.0.0.1:8722"
    private let storeKey = "ut.openNotebooks.v1"
    private let activeKey = "ut.openNotebooks.active.v1"
    /// Notebooks currently being resolved, so a re-select / re-appear doesn't kick a
    /// second concurrent resolve for the same notebook.
    private var resolving: Set<UUID> = []

    /// Restore the open-notebook list saved last run. The `.ipynb` + JupyterLab server
    /// persist on the host (the broker re-adopts the server), so we only restore the
    /// {machine, name, path} tabs here (url == nil) and resolve each lazily when it's
    /// shown — see `resolveIfNeeded`.
    init() {
        guard let d = UserDefaults.standard.data(forKey: storeKey),
              let recs = try? JSONDecoder().decode([NotebookRecord].self, from: d) else { return }
        notebooks = recs.map { NotebookSession(id: $0.id, machineID: $0.machineID, name: $0.name, path: $0.path) }
        if let a = UserDefaults.standard.string(forKey: activeKey) { activeID = UUID(uuidString: a) }
    }

    /// Persist the current list + active id. Called on every mutation (mirrors how W&B
    /// runs persist on each change).
    private func save() {
        let recs = notebooks.map { NotebookRecord(id: $0.id, machineID: $0.machineID, name: $0.name, path: $0.path) }
        if let d = try? JSONEncoder().encode(recs) { UserDefaults.standard.set(d, forKey: storeKey) }
        if let a = activeID?.uuidString { UserDefaults.standard.set(a, forKey: activeKey) }
        else { UserDefaults.standard.removeObject(forKey: activeKey) }
    }

    var active: NotebookSession? { notebooks.first { $0.id == activeID } }
    func forMachine(_ id: String) -> [NotebookSession] { notebooks.filter { $0.machineID == id } }

    // MARK: create / open / close

    /// Open (or focus) JupyterLab rooted at `dir` on `machine`. No file is created here —
    /// you make or open notebooks from the Lab launcher, which opens in that folder.
    func openLab(on machine: Machine, dir: String) {
        let folder = dir.isEmpty ? "/" : dir
        if let ex = notebooks.first(where: { $0.machineID == machine.id && $0.path == folder }) {
            activeID = ex.id; save(); return
        }
        let label = (folder as NSString).lastPathComponent
        let nb = NotebookSession(machineID: machine.id, name: label.isEmpty ? "JupyterLab" : label, path: folder)
        notebooks.append(nb); activeID = nb.id; save()
        resolving.insert(nb.id)  // claim it so the pane's resolveIfNeeded doesn't double-resolve
        Task { @MainActor in await resolve(nb, on: machine); resolving.remove(nb.id) }
    }

    func select(_ id: UUID) { activeID = id; save() }

    func close(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        if activeID == id { activeID = notebooks.last?.id }
        save()
    }

    /// Resolve a notebook (ensure JupyterLab + forward + endpoint serving, then load) only
    /// if it isn't already resolved or in flight. This is what makes a RESTORED notebook —
    /// or one whose machine just came online — load when it's shown, without re-resolving
    /// an already-open one. Caller supplies the live `Machine` (the model has no machine list).
    func resolveIfNeeded(_ nb: NotebookSession, on machine: Machine) {
        guard nb.tab.url == nil, !resolving.contains(nb.id) else { return }
        resolving.insert(nb.id)
        Task { @MainActor in await resolve(nb, on: machine); resolving.remove(nb.id) }
    }

    /// User-driven reload (the notebook header's Reload button): re-run the full resolve so
    /// a dead forward / restarted server is re-established, not just a webView.reload().
    func reload(_ nb: NotebookSession, on machine: Machine) {
        guard !resolving.contains(nb.id) else { return }
        resolving.insert(nb.id)
        Task { @MainActor in await resolve(nb, on: machine); resolving.remove(nb.id) }
    }

    // MARK: resolve the webview URL (ensure Jupyter + forward)

    private func resolve(_ nb: NotebookSession, on machine: Machine) async {
        nb.tab.url = nil   // a reload restarts from scratch (and lets resolveIfNeeded retry on failure)
        nb.tab.status = "starting JupyterLab on \(machine.name)…"
        guard let u = URL(string: machine.httpBase + "/jupyter") else {
            nb.tab.status = "bad broker URL for \(machine.name)"; return
        }
        var req = URLRequest(url: u); req.timeoutInterval = 200   // must outlast the broker's 180s readiness wait so its result wins
        let info: NBJupyterResp
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let body = String(data: d, encoding: .utf8) ?? ""
                nb.tab.status = "JupyterLab on \(machine.name) failed (HTTP \(code)): \(body.prefix(140))"; return
            }
            info = try JSONDecoder().decode(NBJupyterResp.self, from: d)
        } catch {
            nb.tab.status = "couldn't reach \(machine.name): \(error.localizedDescription)"; return
        }

        // Resolve the LOCAL port the webview will hit: the broker's own port for the local
        // Mac, else a tailnet port-forward to the host's loopback JupyterLab.
        let port: Int
        if machine.isLocal {
            port = info.port
        } else {
            nb.tab.status = "forwarding JupyterLab from \(machine.name)…"
            guard let local = await ensureForward(brokerHost: machine.fwHost, name: machine.name,
                                                  scheme: machine.fwScheme, remotePort: info.port) else {
                nb.tab.status = "couldn't forward JupyterLab from \(machine.name)"; return
            }
            port = local
        }

        // CRITICAL: a registered forward is NOT yet a serving one — the tunnel still has to
        // establish and JupyterLab still has to answer. Loading the webview before the
        // endpoint serves leaves WKWebView permanently blank (it never retries a failed
        // load). Poll the forwarded endpoint end-to-end until it actually responds, THEN
        // load — this is the fix for the "blank notebook" (verified: loading early = blank).
        let base = "http://127.0.0.1:\(port)"
        nb.tab.status = "connecting to JupyterLab on \(machine.name)…"
        guard await waitServing(base: base, token: info.token, timeout: 45) else {
            nb.tab.status = "JupyterLab on \(machine.name) isn't responding — tap reload to retry"
            return
        }

        let rel = nb.path.hasPrefix("/") ? String(nb.path.dropFirst()) : nb.path
        let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
        let labPath = enc.isEmpty ? "/lab" : "/lab/tree/\(enc)"   // full JupyterLab, rooted at the folder
        // Keep the pane's spinner up until the JupyterLab SHELL actually paints (not just
        // until the page loads): on a cold host it can be blank for 20–45s after load.
        // (.jp-LabShell is the Lab app shell; .jp-Notebook never appears on the launcher.)
        nb.tab.readinessJS = "(document.querySelector('.jp-LabShell')!=null)"
        nb.tab.contentReady = false
        nb.tab.status = nil
        nb.tab.load("\(base)\(labPath)?token=\(info.token)")
    }

    /// Poll a forwarded JupyterLab's /api/status until it answers 200 — server up AND tunnel
    /// passing traffic end-to-end — so the webview only ever loads a serving endpoint.
    private func waitServing(base: String, token: String, timeout: Int) async -> Bool {
        guard let url = URL(string: base + "/api/status") else { return false }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            var req = URLRequest(url: url); req.timeoutInterval = 5
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        return false
    }

    // MARK: forward agent (mirrors DashboardsModel)

    private func ensureForward(brokerHost: String, name: String, scheme: String, remotePort: Int) async -> Int? {
        if let f = (await fetchForwards()).first(where: { $0.brokerHost == brokerHost && $0.remotePort == remotePort }) {
            return f.localPort
        }
        guard var c = URLComponents(string: agent + "/forwards") else { return nil }
        c.queryItems = [
            .init(name: "brokerHost", value: brokerHost),
            .init(name: "brokerName", value: name),
            .init(name: "scheme", value: scheme),
            .init(name: "remotePort", value: String(remotePort)),
            .init(name: "localPort", value: String(remotePort)),
            .init(name: "label", value: "notebook"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let f = (await fetchForwards()).first(where: { $0.brokerHost == brokerHost && $0.remotePort == remotePort }) {
                return f.localPort
            }
        }
        return nil
    }

    private func fetchForwards() async -> [PortForward] {
        guard let url = URL(string: agent + "/forwards"),
              let (d, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(NBForwardsResp.self, from: d) else { return [] }
        return r.forwards ?? []
    }
}

// MARK: - the notebook pane (main detail area)

struct NotebookPaneView: View {
    @ObservedObject var tab: DashboardTab

    var body: some View {
        ZStack {
            WebTabView(tab: tab)
            // Cover the webview with a spinner while resolving (status) OR while the page
            // has loaded but the notebook hasn't painted yet (!contentReady) — so the user
            // never sees a bare blank webview.
            if tab.status != nil || !tab.contentReady {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tab.status ?? "rendering notebook…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.appBackground)
            }
        }
    }
}
