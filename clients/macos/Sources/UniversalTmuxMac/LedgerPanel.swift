import AppKit
import SwiftUI
import WebKit

/// The in-app Activity Ledger: a bundled no-build webview page (Resources/ledger)
/// that reads the activity-journal JSONL files DIRECTLY from disk — no server,
/// mirroring the Git panel's pattern. One instance is kept alive for the app's
/// lifetime (the ledger is fleet-wide, not per-session), so opening it is instant
/// and scroll/day state survive toggling away and back.
@MainActor
final class LedgerPanel: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    var onOpenArtifact: ((UUID) -> Void)?
    private var ready = false

    override init() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "ut")
        let dir = Bundle.main.resourceURL!.appendingPathComponent("ledger")
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        webView.setValue(false, forKey: "drawsBackground")
    }

    // MARK: JS → Swift

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            sendDays()
        case "day":
            if let d = body["d"] as? String { sendDay(d) }
        case "refresh":
            sendDays()               // re-list; JS re-requests the current day if unchanged
            if let d = currentDay { sendDay(d) }
        case "openFolder":
            NSWorkspace.shared.open(ActivityJournal.dirURL)
        case "openArtifact":
            if let raw = body["id"] as? String, let id = UUID(uuidString: raw) {
                onOpenArtifact?(id)
            }
        default: break
        }
    }

    /// Re-list days + push the current one (used when the panel is shown).
    func refresh() {
        guard ready else { return }
        sendDays()
        if let d = currentDay { sendDay(d) }
    }

    private var currentDay: String?

    // MARK: reading the journal files

    /// [{day, count}] newest-first, from ~/Library/Application Support/Argus/journal/*.jsonl.
    private func sendDays() {
        let dir = ActivityJournal.dirURL
        var out: [[String: Any]] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jsonl" {
            let day = url.deletingPathExtension().lastPathComponent
            guard day.count == 10 else { continue }
            let count = (try? String(contentsOf: url, encoding: .utf8))
                .map { $0.split(separator: "\n", omittingEmptySubsequences: true).count } ?? 0
            out.append(["day": day, "count": count])
        }
        out.sort { ($0["day"] as? String ?? "") > ($1["day"] as? String ?? "") }
        let payload: [String: Any] = ["dir": dir.path, "days": out]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            eval("window.UTLedger.setDays(\(json))")
        }
    }

    /// Push one day's raw JSONL text; the page splits + parses per line.
    private func sendDay(_ day: String) {
        guard day.count == 10, day.allSatisfy({ $0.isNumber || $0 == "-" }) else { return }
        currentDay = day
        let url = ActivityJournal.dirURL.appendingPathComponent(day + ".jsonl")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let payload: [String: Any] = ["day": day, "jsonl": text]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            eval("window.UTLedger.setDay(\(json))")
        }
    }

    // MARK: Swift → JS

    private func eval(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
    // No applyTheme: the ledger keeps its own designed amber-on-near-black
    // palette (unlike the git panel, it does not adopt the app theme).
}

/// Keeps the single LedgerPanel (and its webview) alive across SwiftUI churn.
@MainActor
final class LedgerPanelHost: ObservableObject {
    let panel = LedgerPanel()
}

/// Hosts the panel's webview; never reloads on SwiftUI updates.
struct LedgerView: NSViewRepresentable {
    let panel: LedgerPanel
    func makeNSView(context: Context) -> WKWebView { panel.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
