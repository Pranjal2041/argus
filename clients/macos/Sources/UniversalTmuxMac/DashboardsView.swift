import AppKit
import SwiftUI
import WebKit

// MARK: - WKWebView host (one per tab; NO native bridge — sandboxed web content)

struct WebTabView: NSViewRepresentable {
    @ObservedObject var tab: DashboardTab

    func makeCoordinator() -> Coordinator { Coordinator(tab: tab) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent cookies for token/login dashboards
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        tab.webView = wv
        if let u = tab.url {
            context.coordinator.lastLoaded = u
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // (Re)load only when the tab's target URL actually changes (address bar edit
        // or a resolved port-forward) — never on an unrelated SwiftUI invalidation.
        if let u = tab.url, u != context.coordinator.lastLoaded {
            context.coordinator.lastLoaded = u
            wv.load(URLRequest(url: u))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let tab: DashboardTab
        var lastLoaded: URL?
        init(tab: DashboardTab) { self.tab = tab }

        private func sync(_ wv: WKWebView) {
            tab.canGoBack = wv.canGoBack
            tab.canGoForward = wv.canGoForward
            tab.isLoading = wv.isLoading
            if let u = wv.url { tab.address = u.absoluteString }
            if let t = wv.title, !t.isEmpty { tab.title = t }
        }
        func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
            tab.isLoading = true; tab.status = nil; sync(wv)
        }
        func webView(_ wv: WKWebView, didCommit n: WKNavigation!) { sync(wv) }
        func webView(_ wv: WKWebView, didFinish n: WKNavigation!) { tab.isLoading = false; sync(wv) }
        func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            tab.isLoading = false; tab.status = e.localizedDescription; sync(wv)
        }
        func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            tab.isLoading = false
            if (e as NSError).code != NSURLErrorCancelled { tab.status = e.localizedDescription }
            sync(wv)
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
            if let tab = model.active { chrome(tab) ; Divider().overlay(Theme.border) }
            content
        }
        .background(Theme.appBackground)
        .frame(minWidth: 640, minHeight: 420)
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
            Button { model.refreshForwards(); showAdd.toggle() } label: {
                Image(systemName: "plus").font(.system(size: s(12), weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: s(26), height: s(22))
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
                Image(systemName: "xmark").font(.system(size: s(8), weight: .bold)).foregroundStyle(Theme.textTertiary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(activeTab ? Theme.accent.opacity(0.18) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(activeTab ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        .frame(maxWidth: s(220))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRename(tab) }     // double-click to rename
        .onTapGesture { model.activeID = tab.id }
        .contextMenu {
            Button("Rename…") { startRename(tab) }
            Button("Close") { model.close(tab.id) }
        }
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
            VStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: s(30), weight: .light)).foregroundStyle(.tertiary)
                Text("No dashboards open").font(.system(size: s(13))).foregroundStyle(.secondary)
                Text("⌘-click a localhost URL in a session, open an active forward with +, or type a URL.")
                    .font(.system(size: s(11))).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: s(320))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
