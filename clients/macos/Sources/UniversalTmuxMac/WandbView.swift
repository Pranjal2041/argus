import AppKit
import SwiftUI
import WebKit

/// Owns the single WKWebView used for in-place W&B run views. The data store is
/// `.default()` — PERSISTENT and shared — so you log into W&B once and every run
/// (and every relaunch) stays logged in. Reused across panels/runs (just
/// navigated), so toggling back to a run you were already viewing is instant.
final class WandbController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var isLoading = false
    private var loaded: URL?

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()       // persistent, shared → login survives
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func navigate(to url: URL) {
        guard loaded != url else { return }     // don't reload an already-shown run
        loaded = url
        webView.load(URLRequest(url: url))
    }
    func reload() { webView.reload() }

    func webView(_ wv: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { isLoading = true }
    func webView(_ wv: WKWebView, didFinish n: WKNavigation!) { isLoading = false }
    func webView(_ wv: WKWebView, didFail n: WKNavigation!, withError e: Error) { isLoading = false }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { isLoading = false }
    // Web content process jettisoned → reload so the surface isn't left blank.
    func webViewWebContentProcessDidTerminate(_ wv: WKWebView) { if let u = loaded { wv.load(URLRequest(url: u)) } }
    // target=_blank / window.open → keep it in this view.
    func webView(_ wv: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { wv.load(URLRequest(url: u)) }
        return nil
    }
}

/// Hosts the controller's single WKWebView, moving it into the current container.
private struct WandbHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let c = NSView()
        mount(in: c)
        return c
    }
    func updateNSView(_ c: NSView, context: Context) {
        if webView.superview !== c { mount(in: c) }
    }
    private func mount(in c: NSView) {
        webView.removeFromSuperview()
        webView.frame = c.bounds
        webView.autoresizingMask = [.width, .height]
        c.addSubview(webView)
    }
}

/// The W&B view shown IN PLACE of the terminal: a thin header (back to terminal,
/// run picker, reload, open-in-browser) over the embedded webview.
struct WandbPaneView: View {
    @ObservedObject var controller: WandbController
    @ObservedObject var terminals: TerminalController
    let ref: SessionRef

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s, weight: w) }

    var body: some View {
        let runs = terminals.wandbRuns(for: ref)
        let current = terminals.currentRun(for: ref)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { terminals.hideWandb(ref) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Terminal") }
                        .font(cf(12, .medium)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Back to terminal (⌃⌘W)")

                Divider().frame(height: 14)

                Menu {
                    ForEach(runs.reversed()) { r in
                        Button {
                            terminals.setCurrentRun(r, for: ref)
                            controller.navigate(to: r.url)
                        } label: {
                            if r.runId == current?.runId { Label(r.label, systemImage: "checkmark") }
                            else { Text(r.label) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chart.line.uptrend.xyaxis").font(cf(11))
                        Text(current?.label ?? "W&B").font(cf(12, .medium)).lineLimit(1)
                        if runs.count > 1 { Image(systemName: "chevron.down").font(cf(9)) }
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(runs.count <= 1)

                if controller.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 8)

                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Reload")
                if let u = current?.url {
                    Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Open in browser")
                }
            }
            .font(cf(12))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.sidebarBackground.opacity(0.97))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }

            WandbHost(webView: controller.webView)
        }
        .onAppear { if let u = current?.url { controller.navigate(to: u) } }
        .onChange(of: terminals.currentRun(for: ref)?.url) { u in if let u { controller.navigate(to: u) } }
        .onChange(of: ref) { _ in if let u = terminals.currentRun(for: ref)?.url { controller.navigate(to: u) } }
    }
}
