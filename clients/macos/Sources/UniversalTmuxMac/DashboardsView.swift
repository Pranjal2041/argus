import AppKit
import SwiftUI
import WebKit

enum DashboardNavigationFailureDisposition: Equatable {
    case superseded
    case contentHandled
    case retryable
    case report
}

/// WKWebView reports both real navigation failures and control-flow events through
/// the same delegate callback. Keep that distinction explicit so a successfully
/// opened native document is never mistaken for an unavailable dashboard.
enum DashboardNavigationFailurePolicy {
    static func disposition(for error: Error) -> DashboardNavigationFailureDisposition {
        let error = error as NSError

        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            return .superseded
        }

        // A top-level audio/video resource is handed to WebKit's native media viewer.
        // WebKit still calls didFail with its legacy "plug-in will handle load" value
        // (WebKitErrorDomain/204), even though playback has successfully started.
        if error.domain == "WebKitErrorDomain", error.code == 204 {
            return .contentHandled
        }

        guard error.domain == NSURLErrorDomain else { return .report }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorNotConnectedToInternet:
            return .retryable
        default:
            return .report
        }
    }
}

// MARK: - WKWebView host (one per tab; NO native bridge — sandboxed web content)

struct WebTabView: NSViewRepresentable {
    @ObservedObject var tab: DashboardTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> WKWebView {
        // Reuse a persisted webview (notebooks) AS-IS so a pane switch + return does NOT
        // reload it. Do NOT compare tab.url to wv.url here: JupyterLab rewrites its own URL
        // (strips ?token=, changes path as you open notebooks), so any such comparison would
        // see a "change" on every return and reload — wiping unsaved work. Loads for persist
        // tabs are driven solely by DashboardTab.load() (initial open + explicit Reload).
        if tab.persist, let wv = tab.heldWebView {
            wv.navigationDelegate = context.coordinator
            wv.uiDelegate = context.coordinator
            tab.webView = wv
            return wv
        }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent cookies for token/login dashboards
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        tab.webView = wv
        if tab.persist {
            tab.heldWebView = wv
            if let u = tab.url { context.coordinator.lastLoaded = u; wv.load(URLRequest(url: u)) }
        } else if let u = tab.url {
            context.coordinator.lastLoaded = u
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        if wv.pageZoom != tab.zoom { wv.pageZoom = tab.zoom }   // keep page zoom in sync (⌘+/−/0)
        // Persist tabs (notebooks) are driven ONLY by DashboardTab.load() — never reload here
        // (an unrelated SwiftUI invalidation, or a URL the page rewrote itself, must not wipe
        // a live notebook). Non-persist (dashboards) keep address-bar/forward reload-on-change.
        if tab.persist { return }
        if let u = tab.url, u != context.coordinator.lastLoaded {
            context.coordinator.lastLoaded = u
            wv.load(URLRequest(url: u))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let tab: DashboardTab
        var lastLoaded: URL?
        var retries = 0
        private let maxRetries = 3
        private var pendingRetry: DispatchWorkItem?
        init(tab: DashboardTab) { self.tab = tab }

        @discardableResult
        private func cancelPendingRetry() -> Bool {
            let hadPendingRetry = pendingRetry != nil
            pendingRetry?.cancel()
            pendingRetry = nil
            return hadPendingRetry
        }

        private func sync(_ wv: WKWebView) {
            tab.canGoBack = wv.canGoBack
            tab.canGoForward = wv.canGoForward
            tab.isLoading = wv.isLoading
            if let u = wv.url { tab.address = u.absoluteString }
            if let t = wv.title, !t.isEmpty { tab.title = t }
        }
        func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
            // If the user navigated while a retry was waiting, the old URL must not
            // unexpectedly replace the new page when that delayed block fires.
            if cancelPendingRetry() { retries = 0 }
            tab.isLoading = true; tab.status = nil
            if tab.readinessJS != nil { tab.contentReady = false }
            sync(wv)
        }
        func webView(_ wv: WKWebView, didCommit n: WKNavigation!) { sync(wv) }
        func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
            cancelPendingRetry()
            tab.isLoading = false; retries = 0; sync(wv)
            // The page loaded, but its SPA may still be painting. If a readiness check is
            // set (notebooks), poll it so the pane keeps a spinner until real content appears
            // rather than flashing a blank webview on cold/slow hosts.
            guard let js = tab.readinessJS else { tab.contentReady = true; return }
            pollReady(wv, js, attempt: 0)
        }
        private func pollReady(_ wv: WKWebView, _ js: String, attempt: Int) {
            wv.evaluateJavaScript(js) { [weak self] r, _ in
                guard let self else { return }
                if (r as? Bool) == true { self.tab.contentReady = true; return }
                if attempt < 75 {   // ~75s budget for a very cold notebook to paint
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollReady(wv, js, attempt: attempt + 1) }
                } else {
                    self.tab.contentReady = true   // stop spinning; show whatever rendered
                }
            }
        }
        func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) { handleFailure(wv, e) }
        func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { handleFailure(wv, e) }

        // A freshly-resolved endpoint (a port-forward whose tunnel just came up) can be
        // momentarily unreachable on the very first request; WKWebView does NOT auto-retry,
        // so without this a transient failure leaves a permanent blank. Retry a few times
        // before surfacing the error.
        private func handleFailure(_ wv: WKWebView, _ e: Error) {
            tab.isLoading = false
            switch DashboardNavigationFailurePolicy.disposition(for: e) {
            case .superseded:
                sync(wv)
                return
            case .contentHandled:
                // Native media/document playback is already live in this WKWebView.
                // Treat the handoff like didFinish instead of reloading it from zero.
                cancelPendingRetry()
                retries = 0
                tab.status = nil
                tab.contentReady = true
                sync(wv)
                tab.isLoading = false
                return
            case .retryable where retries < maxRetries:
                guard let u = lastLoaded ?? tab.url else {
                    tab.status = e.localizedDescription
                    sync(wv)
                    return
                }
                cancelPendingRetry()
                retries += 1
                tab.status = nil
                let retry = DispatchWorkItem { [weak self, weak wv] in
                    self?.pendingRetry = nil
                    wv?.load(URLRequest(url: u))
                }
                pendingRetry = retry
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
            case .retryable, .report:
                cancelPendingRetry()
                tab.status = e.localizedDescription
            }
            sync(wv)
        }
        // Web content process jettisoned (memory pressure / crash) — the surface goes
        // blank. WKWebView does NOT auto-recover; reload to repaint.
        func webViewWebContentProcessDidTerminate(_ wv: WKWebView) {
            if let u = wv.url ?? tab.url { wv.load(URLRequest(url: u)) }
        }
        // target=_blank / window.open → load in the same view instead of dropping it.
        func webView(_ wv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = action.request.url { wv.load(URLRequest(url: u)) }
            return nil
        }
    }
}

// MARK: - the Dashboards window

struct DashboardsView: View {
    @EnvironmentObject var model: DashboardsModel
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var showAdd = false
    @State private var newURL = ""
    @State private var renaming: DashboardTab?
    @State private var renameText = ""
    private func s(_ v: CGFloat) -> CGFloat { v * uiScale }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider().overlay(Theme.border)
            if let tab = model.active {
                chrome(tab)
                if tab.showFind { findBar(tab) }
                Divider().overlay(Theme.border)
            }
            content
        }
        .background(Theme.appBackground)
        .frame(minWidth: 640, minHeight: 420)
        .background(zoomFindShortcuts)
        .alert("Rename tab", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let n = renameText.trimmingCharacters(in: .whitespaces)
                renaming?.customTitle = n.isEmpty ? nil : n
                renaming = nil
            }
            Button("Reset", role: .destructive) { renaming?.customTitle = nil; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func startRename(_ tab: DashboardTab) {
        renameText = tab.displayTitle
        renaming = tab
    }

    // ⌘F find bar over the active tab's web content.
    @ViewBuilder private func findBar(_ tab: DashboardTab) -> some View {
        FindBar(tab: tab)
    }

    // Zoom (⌘+/−/0) + find (⌘F) shortcuts, scoped to this window.
    private var zoomFindShortcuts: some View {
        Group {
            Button("") { if let t = model.active { t.showFind = true } }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { model.active?.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("") { model.active?.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("") { model.active?.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("") { model.active?.zoomReset() }.keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: tab strip

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in tabChip(tab) }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            if !model.tabs.isEmpty {
                Menu {
                    if let active = model.active {
                        tabManagementCommands(for: active)
                    } else {
                        Button("Close All Tabs", role: .destructive) { model.closeAllTabs() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: s(13), weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: s(28), height: s(26))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Manage dashboard tabs")
            }
            Button { model.refreshForwards(); showAdd.toggle() } label: {
                Image(systemName: "plus").font(.system(size: s(12), weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: s(28), height: s(26))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a dashboard")
            .popover(isPresented: $showAdd, arrowEdge: .bottom) { addPopover }
            .padding(.trailing, 8)
        }
        .frame(height: s(34))
    }

    private func tabChip(_ tab: DashboardTab) -> some View {
        let activeTab = tab.id == model.activeID
        return HStack(spacing: 5) {
            if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: s(10), height: s(10))
            } else {
                Image(systemName: "globe").font(.system(size: s(9))).foregroundStyle(Theme.textTertiary)
            }
            Text(tab.displayTitle).font(.system(size: s(11.5))).lineLimit(1).foregroundStyle(activeTab ? Theme.textPrimary : Theme.textSecondary)
            Button { model.close(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: s(10), weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: s(24), height: s(24))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.leading, 9).padding(.trailing, 3).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(activeTab ? Theme.accent.opacity(0.18) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(activeTab ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        .frame(maxWidth: s(220))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(tab) }     // double-click to rename
        .onTapGesture { model.select(tab.id) }
        .contextMenu {
            Button("Rename…") { startRename(tab) }
            Divider()
            tabManagementCommands(for: tab)
        }
    }

    @ViewBuilder
    private func tabManagementCommands(for tab: DashboardTab) -> some View {
        let index = model.tabs.firstIndex(where: { $0.id == tab.id })
        let inactiveCount = model.inactiveTabCount()

        Button("Close Tab") { model.close(tab.id) }
        Button("Close Tabs to the Left") { model.closeTabs(toLeftOf: tab.id) }
            .disabled(index == nil || index == 0)
        Button("Close Tabs to the Right") { model.closeTabs(toRightOf: tab.id) }
            .disabled(index == nil || index == model.tabs.count - 1)
        Button("Close Other Tabs") { model.closeOtherTabs(keeping: tab.id) }
            .disabled(model.tabs.count < 2)
        Divider()
        Button("Close Tabs Inactive for 24 Hours (\(inactiveCount))") {
            model.closeInactiveTabs()
        }
        .disabled(inactiveCount == 0)
        Button("Close All Tabs", role: .destructive) { model.closeAllTabs() }
    }

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open URL").font(.system(size: s(11), weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                TextField("localhost:8080 or https://…", text: $newURL)
                    .textFieldStyle(.roundedBorder).frame(width: s(240))
                    .onSubmit(openManual)
                Button("Open", action: openManual).disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            Toggle(isOn: $model.autoOpen) {
                Text("Auto-open every forward as a tab").font(.system(size: s(11)))
            }
            .toggleStyle(.switch).controlSize(.small)
            if !model.forwards.isEmpty {
                HStack {
                    Text("Active forwards").font(.system(size: s(10.5), weight: .medium)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Open all") { model.openAllForwards(); showAdd = false }
                        .font(.system(size: s(10.5)))
                }
                ForEach(model.forwards) { f in
                    Button {
                        model.openForward(f); showAdd = false
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app").font(.system(size: s(10)))
                            Text("\(f.brokerName):\(f.remotePort)").font(.system(size: s(11)))
                            Text("→ :\(f.localPort)").font(.system(size: s(10))).foregroundStyle(Theme.textTertiary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: s(300))
    }

    private func openManual() {
        let u = newURL.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        model.openURL(u)
        newURL = ""
        showAdd = false
    }

    // MARK: chrome (back / fwd / reload / address / open-in-Safari)

    private func chrome(_ tab: DashboardTab) -> some View {
        HStack(spacing: 8) {
            navBtn("chevron.left", enabled: tab.canGoBack) { tab.goBack() }
            navBtn("chevron.right", enabled: tab.canGoForward) { tab.goForward() }
            navBtn(tab.isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                tab.isLoading ? tab.webView?.stopLoading() : tab.reload()
            }
            addressField(tab)
            Menu {
                Button("Off") { tab.refreshEvery = 0 }
                Button("Every 5s") { tab.refreshEvery = 5 }
                Button("Every 15s") { tab.refreshEvery = 15 }
                Button("Every 30s") { tab.refreshEvery = 30 }
                Button("Every 60s") { tab.refreshEvery = 60 }
            } label: {
                Image(systemName: tab.refreshEvery > 0 ? "timer.circle.fill" : "timer")
                    .foregroundStyle(tab.refreshEvery > 0 ? Theme.accent : Flat.dim)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(tab.refreshEvery > 0 ? "Auto-refresh every \(tab.refreshEvery)s" : "Auto-refresh off")
            navBtn("safari", enabled: true) { tab.openInSystemBrowser() }.help("Open in default browser")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func addressField(_ tab: DashboardTab) -> some View {
        HStack(spacing: 6) {
            Text(tab.host).font(.system(size: s(10), weight: .medium)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.15)))
            TextField("address", text: Binding(get: { tab.address }, set: { tab.address = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: s(12), design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .onSubmit { tab.load(tab.address) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func navBtn(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: s(12), weight: .medium))
                .foregroundStyle(enabled ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))
                .frame(width: s(26), height: s(24))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    // MARK: web content

    @ViewBuilder private var content: some View {
        if model.tabs.isEmpty {
            ServiceCatalogView().environmentObject(model).environmentObject(state)
        } else {
            ZStack {
                ForEach(model.tabs) { tab in
                    ZStack {
                        WebTabView(tab: tab)
                        if let st = tab.status {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(st).font(.system(size: s(12))).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.appBackground)
                        }
                    }
                    .opacity(tab.id == model.activeID ? 1 : 0)
                    .allowsHitTesting(tab.id == model.activeID)
                }
            }
        }
    }
}

/// The ⌘F find bar: a focused field that searches the active tab's web content,
/// Enter = next, Esc = close.
private struct FindBar: View {
    @ObservedObject var tab: DashboardTab
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField("Find in page…", text: $tab.findQuery)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($focused)
                .frame(width: 240)
                .onSubmit { tab.find(tab.findQuery, forward: true) }
            Button { tab.find(tab.findQuery, forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).help("Previous")
            Button { tab.find(tab.findQuery, forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).help("Next")
            Spacer()
            Button { tab.showFind = false; tab.clearFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Close (Esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.sidebarBackground)
        .onAppear { focused = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
        .onExitCommand { tab.showFind = false; tab.clearFind() }
    }
}

/// The Dashboards start page: for each known machine, its listening web services
/// as clickable cards (from the broker's /ports). Turns the browser from a URL
/// box into fleet discovery. Clicking a card opens it (auto-forwarding remotes).
private struct ServiceCatalogView: View {
    @EnvironmentObject var model: DashboardsModel
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var portsByHost: [String: [PortInfo]] = [:]
    @State private var loading: Set<String> = []
    @State private var showAll = false
    private func s(_ v: CGFloat) -> CGFloat { v * uiScale }

    // Desktop-app / OS services that answer HTTP but aren't dashboards you'd browse.
    // Hidden by default; Show all reveals them (so a wrongly-hidden service is one
    // click away — the escape hatch keeps this heuristic safe).
    private func isDesktopNoise(_ p: PortInfo) -> Bool {
        if p.port == 8722 { return true } // our own broker
        let proc = p.process.lowercased()
        for n in ["controlce", "rapportd", "logi", "raycast", "sharingd", "spotify",
                  "google", "dropbox", "figma", "ipnext", "adprivacy", "identityservice",
                  "trustd", "cloudd", "nsurlsession", "corespeech", "airplay"] {
            if proc.contains(n) { return true }
        }
        return false
    }
    // The default view: services that actually speak HTTP and aren't desktop noise.
    private func isEssential(_ p: PortInfo) -> Bool { p.web && !isDesktopNoise(p) }
    private func label(_ p: PortInfo) -> String {
        switch p.port {
        case 6006: return "TensorBoard"
        case 8888, 8889: return "Jupyter"
        case 3000: return "Dev server"
        case 8080, 8000, 5000, 5173, 4200: return "Web app"
        default: return p.process.isEmpty ? "Service" : p.process
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Services on your machines").font(.system(size: s(16), weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Toggle("Show all ports", isOn: $showAll).toggleStyle(.switch).controlSize(.small)
                        .foregroundStyle(Theme.textSecondary)
                }.padding(.bottom, 2)
                ForEach(state.machines) { m in
                    let all = portsByHost[m.id] ?? []
                    let ports = showAll ? all.filter { $0.port != 8722 } : all.filter { isEssential($0) }
                    let hiddenCount = all.count - ports.count
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Circle().fill(m.isLocal ? Color.green : Color.blue).frame(width: 7, height: 7)
                            Text(m.name).font(.system(size: s(13), weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            if loading.contains(m.id) { ProgressView().controlSize(.small) }
                            Spacer()
                            Button { m.isLocal ? model.openJupyter(on: m) : model.openJupyter(on: m) } label: {
                                Label("JupyterLab", systemImage: "book").font(.system(size: s(11)))
                            }.buttonStyle(.borderless).foregroundStyle(Theme.accent)
                        }
                        if ports.isEmpty {
                            Text(loading.contains(m.id) ? "Scanning…"
                                 : hiddenCount > 0 ? "No dashboards — \(hiddenCount) other port\(hiddenCount == 1 ? "" : "s") (Show all)"
                                 : "No web services listening")
                                .font(.system(size: s(11))).foregroundStyle(Theme.textTertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: s(180)), spacing: 10)], alignment: .leading, spacing: 10) {
                                ForEach(ports) { p in
                                    Button { model.openLocalhost(on: m, port: p.port, path: "", scheme: "http") } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "globe").font(.system(size: s(11))).foregroundStyle(Theme.accent)
                                                Text(label(p)).font(.system(size: s(12.5), weight: .medium)).foregroundStyle(Theme.textPrimary)
                                            }
                                            Text(":\(p.port)" + (p.process.isEmpty ? "" : " · \(p.process)"))
                                                .font(.system(size: s(10.5), design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground))
                                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.appBackground.opacity(0.4)))
                }
                Text("⌘-click a localhost URL in a session, or type a URL in the + panel, to open anything else.")
                    .font(.system(size: s(11))).foregroundStyle(Theme.textTertiary).padding(.top, 4)
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { scanAll() }
    }

    private func scanAll() {
        for m in state.machines {
            loading.insert(m.id)
            guard let url = URL(string: m.httpBase + "/ports?probe=1") else { loading.remove(m.id); continue }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                struct R: Codable { let ports: [PortInfo]? }
                let ports = (data.flatMap { try? JSONDecoder().decode(R.self, from: $0) }?.ports ?? [])
                    .sorted { $0.port < $1.port }
                DispatchQueue.main.async { portsByHost[m.id] = ports; loading.remove(m.id) }
            }.resume()
        }
    }
}
