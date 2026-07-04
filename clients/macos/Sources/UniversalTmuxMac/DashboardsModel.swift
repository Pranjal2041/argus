import AppKit
import Foundation
import WebKit

// MARK: - one dashboard tab (a host + a web view)

/// A single embedded dashboard. Holds the target URL + live navigation state; the
/// WKWebView is owned by the view layer and handed back here (weak) so the chrome
/// buttons can drive back/forward/reload.
@MainActor
final class DashboardTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL?            // target to load — set this to navigate
    @Published var title: String       // auto title (page <title> or the url host)
    @Published var customTitle: String? // user-renamed; overrides the auto title
    @Published var host: String        // host label (e.g. a node/host name)
    @Published var address: String     // address-bar text (editable)
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var status: String?     // "forwarding…", an error, etc.
    // A page can finish loading (didFinish) long before its SPA actually paints — a cold
    // JupyterLab over a slow forward shows a blank webview for 20–45s after load. When
    // `readinessJS` is set, WebTabView polls it after load and keeps `contentReady` false
    // (so the pane shows a spinner, not a blank) until the page reports real content.
    @Published var contentReady = true
    var readinessJS: String?
    // When `persist` is set (notebooks/JupyterLab), the WKWebView is kept ALIVE across
    // SwiftUI re-creation via a strong `heldWebView`, and WebTabView re-attaches it instead
    // of building a fresh one — so switching panes and coming back does NOT reload/re-render
    // (mirrors how the terminal controller owns its NSView). Default false: dashboards/W&B
    // get a fresh webview as before.
    var persist = false
    var heldWebView: WKWebView?
    var forwardKey: String?            // "brokerHost:remotePort" if backed by a forward
    weak var webView: WKWebView?       // set by WebTabView; drives the chrome buttons

    /// What the tab chip shows: the user's name if set, else the live page title.
    var displayTitle: String { customTitle?.isEmpty == false ? customTitle! : title }

    init(title: String, host: String, url: URL?, status: String? = nil) {
        self.title = title
        self.host = host
        self.url = url
        self.address = url?.absoluteString ?? ""
        self.status = status
    }

    /// Point this tab at a new URL string (from the address bar or a resolved forward).
    func load(_ s: String) {
        var str = s.trimmingCharacters(in: .whitespaces)
        if !str.isEmpty, !str.contains("://") { str = "http://" + str }   // bare host → http
        guard let u = URL(string: str) else { return }
        address = str
        status = nil
        url = u
        // Persist tabs aren't reloaded by updateNSView (so a pane switch can't wipe them), so
        // drive the live webview directly — this is the ONLY load path for them (initial open
        // + explicit Reload).
        if persist { heldWebView?.load(URLRequest(url: u)) }
    }

    func reload()   { webView?.reload() }
    func goBack()   { webView?.goBack() }
    func goForward(){ webView?.goForward() }
    func openInSystemBrowser() { if let u = webView?.url ?? url { NSWorkspace.shared.open(u) } }

    // ---- per-tab auto-refresh (watch a training dashboard hands-free) ----
    @Published var refreshEvery = 0 {   // seconds; 0 = off
        didSet { restartAutoRefresh() }
    }
    private var refreshTimer: Timer?
    private func restartAutoRefresh() {
        refreshTimer?.invalidate(); refreshTimer = nil
        guard refreshEvery > 0 else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(refreshEvery), repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    // ---- page zoom (⌘+/−/0) — owed by the standing zoom rule ----
    @Published var zoom: CGFloat = 1.0
    func zoomIn()  { zoom = min(3.0, zoom + 0.1); webView?.pageZoom = zoom }
    func zoomOut() { zoom = max(0.4, zoom - 0.1); webView?.pageZoom = zoom }
    func zoomReset() { zoom = 1.0; webView?.pageZoom = 1.0 }
    func applyZoom() { webView?.pageZoom = zoom }   // re-apply after a webview (re)binds

    // ---- find in page (⌘F) ----
    @Published var showFind = false
    @Published var findQuery = ""
    func find(_ q: String, forward: Bool = true) {
        guard let wv = webView, !q.isEmpty else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = !forward
        cfg.caseSensitive = false
        cfg.wraps = true
        wv.find(q, configuration: cfg) { _ in }
    }
    func clearFind() { webView?.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil) }
}

// MARK: - the window's model (a set of tabs)

private struct DashForwardsResp: Codable { let forwards: [PortForward]? }
private struct JupyterResp: Decodable { let port: Int; let token: String }

@MainActor
final class DashboardsModel: ObservableObject {
    @Published var tabs: [DashboardTab] = []
    @Published var activeID: UUID?
    @Published var forwards: [PortForward] = []   // active tunnels, for the "+" menu
    /// When on, every active port-forward automatically gets a tab (kept in sync).
    @Published var autoOpen: Bool = UserDefaults.standard.bool(forKey: "ut.dash.autoOpen") {
        didSet {
            UserDefaults.standard.set(autoOpen, forKey: "ut.dash.autoOpen")
            if autoOpen { openAllForwards() }
        }
    }

    /// The local Mac broker is the forward agent (same as the Ports hub).
    private let agent = "http://127.0.0.1:8722"
    private var timer: Timer?

    init() {
        // Poll the forward agent so the "+" list stays fresh and auto-open keeps up.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        refreshForwards()
        restoreTabs()
    }

    // ---- persist open tabs across launches (notebooks already do this) ----
    private struct SavedTab: Codable { let url: String; let host: String; let title: String? }
    private let tabsKey = "ut.dash.tabs.v1"
    func saveTabs() {
        let saved = tabs.compactMap { t -> SavedTab? in
            guard let u = t.url?.absoluteString, !u.isEmpty else { return nil }
            return SavedTab(url: u, host: t.host, title: t.customTitle)
        }
        if let d = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(d, forKey: tabsKey) }
    }
    private func restoreTabs() {
        guard let d = UserDefaults.standard.data(forKey: tabsKey),
              let saved = try? JSONDecoder().decode([SavedTab].self, from: d) else { return }
        for st in saved {
            let t = DashboardTab(title: st.title ?? (URL(string: st.url)?.host ?? st.url), host: st.host, url: URL(string: st.url))
            t.customTitle = st.title
            tabs.append(t)
        }
        activeID = tabs.first?.id
    }

    private func poll() async {
        forwards = await fetchForwards()
        if autoOpen { openAllForwards() }
    }

    var active: DashboardTab? { tabs.first { $0.id == activeID } }

    // MARK: opening tabs

    /// Add a tab for an arbitrary URL (the manual address field).
    @discardableResult
    func openURL(_ s: String, host: String = "manual") -> DashboardTab {
        var str = s.trimmingCharacters(in: .whitespaces)
        if !str.contains("://") { str = "http://" + str }
        let u = URL(string: str)
        let t = DashboardTab(title: u?.host ?? str, host: host, url: u)
        add(t)
        return t
    }

    /// Open an already-active forward (`127.0.0.1:localPort`) as a tab — or focus its
    /// tab if it's already open.
    func openForward(_ f: PortForward) {
        let key = "\(f.brokerHost):\(f.remotePort)"
        if let existing = tabs.first(where: { $0.forwardKey == key }) { activeID = existing.id; return }
        let t = DashboardTab(title: "\(f.brokerName):\(f.remotePort)", host: f.brokerName,
                             url: URL(string: "http://127.0.0.1:\(f.localPort)"))
        t.forwardKey = key
        add(t)
    }

    /// Ensure every active forward has a tab (the "Open all" button + auto-open).
    /// Appends without stealing focus from the current tab.
    func openAllForwards() {
        let prev = activeID
        for f in forwards {
            let key = "\(f.brokerHost):\(f.remotePort)"
            guard !tabs.contains(where: { $0.forwardKey == key }) else { continue }
            let t = DashboardTab(title: "\(f.brokerName):\(f.remotePort)", host: f.brokerName,
                                 url: URL(string: "http://127.0.0.1:\(f.localPort)"))
            t.forwardKey = key
            tabs.append(t)
        }
        if let prev, tabs.contains(where: { $0.id == prev }) { activeID = prev }
        else { activeID = activeID ?? tabs.first?.id }
    }

    /// The ⌘-click flow: open a `localhost:port` URL that was printed in a session,
    /// on the SESSION'S host. A local Mac session opens directly; a remote session
    /// first ensures a port-forward, then opens the local end.
    func openLocalhost(on machine: Machine, port: Int, path: String, scheme: String) {
        if machine.isLocal {
            let t = DashboardTab(title: ":\(port)", host: machine.name,
                                 url: URL(string: "\(scheme)://127.0.0.1:\(port)\(path)"))
            add(t)
            return
        }
        // remote: create the tab now (showing "forwarding…"), resolve the tunnel async.
        let t = DashboardTab(title: "\(machine.name):\(port)", host: machine.name, url: nil,
                             status: "forwarding \(machine.name):\(port)…")
        t.forwardKey = "\(machine.fwHost):\(port)"   // dedupe with auto-open / openForward
        add(t)
        let fwHost = machine.fwHost, name = machine.name, fwScheme = machine.fwScheme
        Task { @MainActor in
            if let local = await ensureForward(brokerHost: fwHost, name: name, scheme: fwScheme, remotePort: port) {
                t.load("http://127.0.0.1:\(local)\(path)")
            } else {
                t.status = "couldn't forward \(name):\(port)"
            }
        }
    }

    /// Start (or re-adopt) JupyterLab on a machine's host and open its `/lab` in a tab —
    /// directly for the local Mac, over a port-forward for a remote host. Same value as
    /// the terminal path: the kernel runs on that host (GPU node, right env), zero SSH.
    func openJupyter(on machine: Machine) {
        let t = DashboardTab(title: "\(machine.name) · Jupyter", host: machine.name, url: nil,
                             status: "starting JupyterLab on \(machine.name)…")
        add(t)
        let httpBase = machine.httpBase, isLocal = machine.isLocal
        let fwHost = machine.fwHost, name = machine.name, fwScheme = machine.fwScheme
        Task { @MainActor in
            guard let u = URL(string: httpBase + "/jupyter") else { t.status = "bad broker URL"; return }
            var req = URLRequest(url: u)
            req.timeoutInterval = 130   // cold start on a loaded SLURM node can be ~60–90s
            guard let (d, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let info = try? JSONDecoder().decode(JupyterResp.self, from: d) else {
                t.status = "couldn't start JupyterLab on \(name)"
                return
            }
            let path = "/lab?token=\(info.token)"
            if isLocal {
                t.load("http://127.0.0.1:\(info.port)\(path)")
                return
            }
            t.status = "forwarding JupyterLab from \(name)…"
            t.forwardKey = "\(fwHost):\(info.port)"
            if let local = await ensureForward(brokerHost: fwHost, name: name, scheme: fwScheme, remotePort: info.port) {
                t.load("http://127.0.0.1:\(local)\(path)")
            } else {
                t.status = "couldn't forward JupyterLab from \(name)"
            }
        }
    }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeID == id { activeID = tabs.last?.id }
        saveTabs()
    }

    private func add(_ t: DashboardTab) {
        tabs.append(t)
        activeID = t.id
        saveTabs()
    }

    // MARK: forwards (talk to the local broker's forward agent)

    /// Reuse an existing tunnel for (brokerHost, remotePort) or create one, then poll
    /// until the agent reports its assigned local port.
    private func ensureForward(brokerHost: String, name: String, scheme: String, remotePort: Int) async -> Int? {
        if let f = (await fetchForwards()).first(where: { $0.brokerHost == brokerHost && $0.remotePort == remotePort }) {
            return f.localPort
        }
        var c = URLComponents(string: agent + "/forwards")!
        c.queryItems = [
            .init(name: "brokerHost", value: brokerHost),
            .init(name: "brokerName", value: name),
            .init(name: "scheme", value: scheme),
            .init(name: "remotePort", value: String(remotePort)),
            .init(name: "localPort", value: String(remotePort)), // preferred; agent bumps if busy
            .init(name: "label", value: "dashboard"),
        ]
        guard let url = c.url else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        for _ in 0..<16 {   // up to ~4.8s for the tunnel to bind
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
              let r = try? JSONDecoder().decode(DashForwardsResp.self, from: d) else { return [] }
        return r.forwards ?? []
    }

    /// Refresh the active-forwards list (drives the "+" menu's quick-open list).
    func refreshForwards() {
        Task { @MainActor in self.forwards = await fetchForwards() }
    }
}
