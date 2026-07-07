import AppKit
import SwiftUI
import WebKit

/// Argus Wrapped: a bundled no-build webview page (Resources/wrapped) that shows a
/// Spotify-Wrapped-style deck + dashboard of your agent-command activity. Same
/// pattern as the Git/Ledger panels — Swift feeds it one computed blob. The stats
/// are a PURE function of the activity journal (see WrappedStats), computed off the
/// main thread so a large journal never stutters the UI, then injected once.
@MainActor
final class WrappedPanel: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private var ready = false
    /// Window in days; 0 = all time. Exposed so a future period picker can change it.
    var windowDays = 0

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "ut")
        let dir = Bundle.main.resourceURL!.appendingPathComponent("wrapped")
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        // Wrapped is a STANDALONE window (unlike the in-place Git/Ledger panes), so the
        // webview must paint its own solid background — a transparent webview here shows
        // whatever window sits behind it (the bleed-through the user saw). Keep drawsBackground
        // on (the default) and match the page's near-black so there is no white first-paint flash.
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)
        }
    }

    // MARK: JS → Swift

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            compute()
        case "period":
            if let d = body["days"] as? Int { windowDays = d; compute() }
        case "openFolder":
            NSWorkspace.shared.open(ActivityJournal.dirURL)
        default: break
        }
    }

    /// Recompute + re-inject (used when the window is shown again).
    func refresh() { if ready { compute() } }

    // MARK: compute (off-main) → inject (main)

    private func compute() {
        let days = windowDays
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = WrappedStats.compute(days: days)
            guard let data = try? JSONSerialization.data(withJSONObject: stats),
                  let json = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("window.UTWrapped.setData(\(json))", completionHandler: nil)
                self?.loadPersona(stats: stats, days: days)
            }
        }
    }

    // MARK: Claude-generated persona (the finale). Cached so it doesn't re-spend on
    // every open; regenerated only when the picture has meaningfully changed.

    private func loadPersona(stats: [String: Any], days: Int) {
        let utter = (stats["totals"] as? [String: Any])?["utterances"] as? Int ?? 0
        if let cached = Self.cachedPersona(days: days, utterances: utter) { inject(cached); return }
        Task.detached(priority: .userInitiated) {
            guard let p = await WrappedPersona.generate(stats: stats) else { return }
            Self.cache(p, days: days, utterances: utter)
            await MainActor.run { self.inject(p) }
        }
    }

    private func inject(_ p: WrappedPersona.Persona) {
        guard let data = try? JSONEncoder().encode(p), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.UTWrapped.setPersona(\(json))", completionHandler: nil)
    }

    private struct Cached: Codable { let persona: WrappedPersona.Persona; let days: Int; let utterances: Int }
    nonisolated private static let cacheKey = "ut.wrapped.persona.v1"

    /// Reuse the cached persona when it was made for the same window and the message
    /// count is within 20% (so a couple new messages don't trigger a fresh model call).
    nonisolated private static func cachedPersona(days: Int, utterances: Int) -> WrappedPersona.Persona? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey),
              let c = try? JSONDecoder().decode(Cached.self, from: d), c.days == days else { return nil }
        let lo = Double(c.utterances) * 0.8, hi = Double(c.utterances) * 1.2 + 20
        return (Double(utterances) >= lo && Double(utterances) <= hi) ? c.persona : nil
    }

    nonisolated private static func cache(_ p: WrappedPersona.Persona, days: Int, utterances: Int) {
        if let d = try? JSONEncoder().encode(Cached(persona: p, days: days, utterances: utterances)) {
            UserDefaults.standard.set(d, forKey: cacheKey)
        }
    }
}

/// Keeps the single WrappedPanel (and its webview) alive across SwiftUI churn.
@MainActor
final class WrappedPanelHost: ObservableObject {
    let panel = WrappedPanel()
}

/// Hosts the panel's webview; never reloads on SwiftUI updates.
struct WrappedView: NSViewRepresentable {
    let panel: WrappedPanel
    func makeNSView(context: Context) -> WKWebView { panel.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The "Argus Wrapped" window body. Recomputes on each open so it stays current.
struct WrappedWindowView: View {
    @ObservedObject var host: WrappedPanelHost
    var body: some View {
        WrappedView(panel: host.panel)
            .ignoresSafeArea()
            .onAppear { host.panel.refresh() }
    }
}
