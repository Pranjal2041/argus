import Foundation
import SwiftUI

// MARK: - one open notebook

/// An open notebook: a `.ipynb` on a machine, shown in the MAIN detail pane as the
/// host's Notebook 7 single-document view (`/notebooks/<path>`), reached over the same
/// port-forward the Dashboards use. The kernel runs on that host (GPU node, right env),
/// zero SSH — the terminal's value, for notebooks.
struct NotebookSession: Identifiable {
    let id: UUID
    let machineID: String
    var name: String
    let path: String          // absolute path on the host
    let tab: DashboardTab     // holds the resolved webview URL + WKWebView + load state

    @MainActor init(machineID: String, name: String, path: String) {
        let t = DashboardTab(title: name, host: machineID, url: nil)
        self.id = t.id
        self.machineID = machineID
        self.name = name
        self.path = path
        self.tab = t
    }
}

private struct NBForwardsResp: Decodable { let forwards: [PortForward]? }
private struct NBJupyterResp: Decodable { let port: Int; let token: String }

@MainActor
final class NotebooksModel: ObservableObject {
    @Published var notebooks: [NotebookSession] = []
    @Published var activeID: UUID?

    /// The local Mac broker is the forward hub (same as Dashboards/Ports).
    private let agent = "http://127.0.0.1:8722"

    var active: NotebookSession? { notebooks.first { $0.id == activeID } }
    func forMachine(_ id: String) -> [NotebookSession] { notebooks.filter { $0.machineID == id } }

    // MARK: create / open / close

    /// Create `dir/name.ipynb` (empty) on the machine, then open it in the main pane.
    func newNotebook(on machine: Machine, dir: String, name: String) {
        let file = name.hasSuffix(".ipynb") ? name : name + ".ipynb"
        let base = dir.isEmpty ? "/" : (dir.hasSuffix("/") ? dir : dir + "/")
        let path = base + file
        if let ex = notebooks.first(where: { $0.machineID == machine.id && $0.path == path }) {
            activeID = ex.id; return
        }
        let nb = NotebookSession(machineID: machine.id, name: file, path: path)
        nb.tab.status = "creating \(file) on \(machine.name)…"
        notebooks.append(nb); activeID = nb.id
        let httpBase = machine.httpBase
        Task { @MainActor in
            if await writeEmptyNotebook(httpBase: httpBase, path: path) {
                await resolve(nb, on: machine)
            } else {
                nb.tab.status = "couldn't create \(file) in \(dir) on \(machine.name)"
            }
        }
    }

    /// Open (or focus) an existing notebook by path.
    func openExisting(on machine: Machine, path: String) {
        if let ex = notebooks.first(where: { $0.machineID == machine.id && $0.path == path }) {
            activeID = ex.id; return
        }
        let nb = NotebookSession(machineID: machine.id, name: (path as NSString).lastPathComponent, path: path)
        notebooks.append(nb); activeID = nb.id
        Task { @MainActor in await resolve(nb, on: machine) }
    }

    func select(_ id: UUID) { activeID = id }

    func close(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        if activeID == id { activeID = notebooks.last?.id }
    }

    // MARK: resolve the webview URL (ensure Jupyter + forward)

    private func resolve(_ nb: NotebookSession, on machine: Machine) async {
        nb.tab.status = "starting JupyterLab on \(machine.name)…"
        guard let u = URL(string: machine.httpBase + "/jupyter") else {
            nb.tab.status = "bad broker URL for \(machine.name)"; return
        }
        var req = URLRequest(url: u); req.timeoutInterval = 130   // cold start on a loaded SLURM node ~60–90s
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
        let rel = nb.path.hasPrefix("/") ? String(nb.path.dropFirst()) : nb.path
        let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
        let urlPath = "/notebooks/\(enc)?token=\(info.token)"
        if machine.isLocal {
            nb.tab.load("http://127.0.0.1:\(info.port)\(urlPath)")
            return
        }
        nb.tab.status = "forwarding JupyterLab from \(machine.name)…"
        if let local = await ensureForward(brokerHost: machine.fwHost, name: machine.name,
                                           scheme: machine.fwScheme, remotePort: info.port) {
            nb.tab.load("http://127.0.0.1:\(local)\(urlPath)")
        } else {
            nb.tab.status = "couldn't forward JupyterLab from \(machine.name)"
        }
    }

    /// Write an empty `.ipynb` at `path` (the broker creates parent dirs). Returns false
    /// if the broker rejects the write — so the caller surfaces an error instead of
    /// opening a notebook that would 404.
    private func writeEmptyNotebook(httpBase: String, path: String) async -> Bool {
        let nb = #"{"cells":[{"cell_type":"code","source":[],"metadata":{},"outputs":[],"execution_count":null}],"metadata":{},"nbformat":4,"nbformat_minor":5}"#
        guard var c = URLComponents(string: httpBase + "/fs/write") else { return false }
        c.queryItems = [.init(name: "path", value: path)]
        guard let url = c.url else { return false }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = nb.data(using: .utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 400 else { return false }
        return true
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
            if let st = tab.status {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(st).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.appBackground)
            }
        }
    }
}
