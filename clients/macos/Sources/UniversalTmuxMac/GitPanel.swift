import AppKit
import SwiftUI
import WebKit

/// The read-only Git panel: a bundled webview page (Resources/gitview — diff2html +
/// highlight.js, no build step) fed by this host from the machine's broker `/git/*`
/// endpoints. Swift does ALL the fetching (URLSession already reaches every broker,
/// tsnet https included) and injects results via `window.UTGit.*`; user intents come
/// back through the `ut` message handler. One GitPanel (and its WKWebView) lives per
/// session ref and is KEPT ALIVE across pane switches — no reload, no re-render.
@MainActor
final class GitPanel: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    let httpBase: String
    let dir: String
    var onLazygit: (() -> Void)?
    var onOpenFile: ((String) -> Void)?

    private var ready = false

    init(httpBase: String, dir: String) {
        self.httpBase = httpBase
        self.dir = dir
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(self, name: "ut")
        let gvDir = Bundle.main.resourceURL!.appendingPathComponent("gitview")
        webView.loadFileURL(gvDir.appendingPathComponent("index.html"), allowingReadAccessTo: gvDir)
        webView.setValue(false, forKey: "drawsBackground") // app background shows through
    }

    // MARK: JS → Swift

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            applyTheme()
            refresh()
        case "refresh":
            refresh()
        case "diff":
            fetchDiff(scope: body["scope"] as? String ?? "worktree",
                      hash: body["hash"] as? String, path: body["path"] as? String)
        case "commit":
            if let h = body["hash"] as? String { fetchDiff(scope: "commit", hash: h, path: nil) }
        case "moreLog":
            fetchLog(skip: body["skip"] as? Int ?? 0, all: body["all"] as? Bool ?? false)
        case "blame":
            if let p = body["path"] as? String { fetchBlame(path: p) }
        case "lazygit":
            onLazygit?()
        case "openFile":
            if let p = body["path"] as? String { onOpenFile?(p) }
        default: break
        }
    }

    // MARK: Swift → JS

    private func js(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast()) // the JSON-escaped string literal
    }

    private func eval(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func applyTheme() {
        func hex(_ c: NSColor) -> String {
            let s = c.usingColorSpace(.sRGB) ?? c
            return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
        }
        let spec = "{bg:'\(hex(Theme.nsAppBackground))',fg:'\(hex(Theme.nsForeground))',accent:'\(hex(Theme.nsCursor))'}"
        eval("window.UTGit.setTheme(\(spec))")
    }

    /// Reload the Changes view: summary + the full working-tree diff (instant "what
    /// changed" without a click).
    func refresh() {
        eval("window.UTGit.setLoading('loading git status…')")
        fetch("/git/summary?dir=\(enc(dir))") { [weak self] json in
            guard let self else { return }
            self.eval("window.UTGit.setSummary(\(json))")
            self.fetchDiff(scope: "head", hash: nil, path: nil)
        }
    }

    private func fetchLog(skip: Int, all: Bool = false) {
        fetch("/git/log?dir=\(enc(dir))&n=100&skip=\(skip)&all=\(all ? 1 : 0)") { [weak self] json in
            self?.eval("window.UTGit.setLog(\(json), \(skip > 0))")
        }
    }

    private func fetchBlame(path: String) {
        eval("window.UTGit.setLoading('blaming \(jsSafe(path))…')")
        fetch("/git/blame?dir=\(enc(dir))&path=\(enc(path))") { [weak self] json in
            guard let self else { return }
            self.eval("window.UTGit.setBlame(\(json), \(self.js(path)))")
        }
    }

    private func fetchDiff(scope: String, hash: String?, path: String?) {
        var url = "/git/diff?dir=\(enc(dir))&scope=\(scope)"
        if let hash { url += "&hash=\(enc(hash))" }
        if let path { url += "&path=\(enc(path))" }
        fetchText(url) { [weak self] text in
            guard let self else { return }
            var meta = "{scope:\(self.js(scope))"
            if let hash { meta += ",hash:\(self.js(hash))" }
            if let path { meta += ",title:\(self.js(path))" } else if scope != "commit" { meta += ",title:'working tree'" }
            meta += "}"
            self.eval("window.UTGit.setDiff(\(self.js(text)), \(meta))")
        }
    }

    // MARK: broker fetch plumbing

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26").replacingOccurrences(of: "+", with: "%2B") ?? s
    }
    private func jsSafe(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "\\'") }

    /// GET a JSON endpoint; on success hand the raw JSON text (valid JS literal) to
    /// the callback; on failure surface the error in the page.
    private func fetch(_ pathAndQuery: String, done: @escaping (String) -> Void) {
        request(pathAndQuery) { result in
            switch result {
            case .success(let data): done(String(data: data, encoding: .utf8) ?? "null")
            case .failure(let e): self.eval("window.UTGit.setError(\(self.js(e.msg)))")
            }
        }
    }

    private func fetchText(_ pathAndQuery: String, done: @escaping (String) -> Void) {
        request(pathAndQuery) { result in
            switch result {
            case .success(let data): done(String(data: data, encoding: .utf8) ?? "")
            case .failure(let e): self.eval("window.UTGit.setError(\(self.js(e.msg)))")
            }
        }
    }

    private func request(_ pathAndQuery: String, done: @escaping (Result<Data, StringError>) -> Void) {
        guard let url = URL(string: httpBase + pathAndQuery) else {
            done(.failure(StringError("bad url"))); return
        }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err { done(.failure(StringError(err.localizedDescription))); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data else { done(.failure(StringError("empty response"))); return }
                if code == 404 {
                    done(.failure(StringError("this machine's broker predates the git panel — redeploy it")))
                    return
                }
                if code != 200 {
                    // broker errors ride {"error": "..."} — surface git's own message
                    if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let e = o["error"] as? String {
                        done(.failure(StringError(e)))
                    } else {
                        done(.failure(StringError("HTTP \(code)")))
                    }
                    return
                }
                done(.success(data))
            }
        }.resume()
    }

    struct StringError: Error { let msg: String; init(_ m: String) { msg = m } }
}

extension GitPanel.StringError: CustomStringConvertible { var description: String { msg } }

/// Owns one GitPanel per session ref (webviews stay alive across pane switches).
@MainActor
final class GitPanels: ObservableObject {
    private var panels: [String: GitPanel] = [:]

    func panel(for ref: SessionRef, httpBase: String, dir: String,
               onLazygit: @escaping () -> Void, onOpenFile: @escaping (String) -> Void) -> GitPanel {
        if let p = panels[ref.id], p.dir == dir { // same folder → reuse (state + scroll kept)
            p.onLazygit = onLazygit
            p.onOpenFile = onOpenFile
            return p
        }
        let p = GitPanel(httpBase: httpBase, dir: dir)
        p.onLazygit = onLazygit
        p.onOpenFile = onOpenFile
        panels[ref.id] = p
        return p
    }

    func drop(_ refID: String) { panels.removeValue(forKey: refID) }
    func refreshVisible(_ refID: String) { panels[refID]?.refresh() }
}

/// Hosts the panel's webview; NEVER reloads on SwiftUI churn (the panel object owns
/// the webview; this just re-attaches it — the notebooks lesson).
struct GitPaneView: NSViewRepresentable {
    let panel: GitPanel
    func makeNSView(context: Context) -> WKWebView { panel.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
