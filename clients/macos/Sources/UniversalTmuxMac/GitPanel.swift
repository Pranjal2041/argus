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
    let ref: SessionRef?
    var onLazygit: (() -> Void)?
    var onOpenFile: ((String) -> Void)?

    private var ready = false

    init(httpBase: String, dir: String, ref: SessionRef? = nil) {
        self.httpBase = httpBase
        self.dir = dir
        self.ref = ref
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
            eval("window.UTGit.setRepo && window.UTGit.setRepo(\(js((dir as NSString).lastPathComponent)))")
            refresh()
        case "refresh":
            refresh()
        case "diff":
            fetchDiff(scope: body["scope"] as? String ?? "worktree",
                      hash: body["hash"] as? String, path: body["path"] as? String)
        case "commit":
            if let h = body["hash"] as? String { fetchDiff(scope: "commit", hash: h, path: nil) }
        case "compare":
            if let a = body["a"] as? String, let b = body["b"] as? String {
                fetchDiff(scope: "range", hash: a, hash2: b, path: nil)
            }
        case "insight":
            guard let level = body["level"] as? String, let key = body["key"] as? String else { return }
            let question = body["question"] as? String
            if let prNum = body["prNum"] as? Int {
                runPRInsight(num: prNum, level: level, question: question, key: key)
            } else if let hashes = body["hashes"] as? [String], !hashes.isEmpty,
                      let newest = body["newest"] as? String {
                runInsight(level: level, hashes: hashes, newest: newest,
                           base: body["base"] as? String,
                           metaLines: body["metaLines"] as? String ?? "",
                           question: question, key: key)
            }
        case "moreLog":
            fetchLog(skip: body["skip"] as? Int ?? 0, all: body["all"] as? Bool ?? false)
        case "blame":
            if let p = body["path"] as? String { fetchBlame(path: p) }
        case "lazygit":
            onLazygit?()
        case "openFile":
            if let p = body["path"] as? String { onOpenFile?(p) }
        case "prs":
            fetchPRs(state: body["state"] as? String ?? "open")
        case "pr":
            if let n = body["num"] as? Int { fetchPRDetail(n) }
        case "openURL":
            if let u = body["url"] as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case "prReview":
            if let n = body["num"] as? Int {
                prAction("/git/pr/review?dir=\(enc(dir))&num=\(n)&event=\(enc((body["event"] as? String) ?? ""))&body=\(enc((body["body"] as? String) ?? ""))")
            }
        case "prMerge":
            if let n = body["num"] as? Int {
                prAction("/git/pr/merge?dir=\(enc(dir))&num=\(n)&method=\(enc((body["method"] as? String) ?? "squash"))")
            }
        case "prComment":
            if let n = body["num"] as? Int {
                prAction("/git/pr/comment?dir=\(enc(dir))&num=\(n)&body=\(enc((body["body"] as? String) ?? ""))")
            }
        default: break
        }
    }

    private var insightInflight = Set<String>()

    private func runInsight(level: String, hashes: [String], newest: String,
                            base: String?, metaLines: String, question: String? = nil, key: String) {
        let inflightKey = key + "|" + level + "|" + (question ?? "")
        guard !insightInflight.contains(inflightKey) else { return }
        insightInflight.insert(inflightKey)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await GitInsights.shared.generate(
                httpBase: self.httpBase, dir: self.dir, level: level,
                hashes: hashes, newest: newest, base: base, metaLines: metaLines,
                question: question)
            self.insightInflight.remove(inflightKey)
            self.deliverInsight(outcome, level: level, key: key, question: question, commits: hashes.count)
        }
    }

    /// Insights for a whole PR: same levels/ask, fed the PR's combined diff.
    private func runPRInsight(num: Int, level: String, question: String?, key: String) {
        let inflightKey = key + "|" + level + "|" + (question ?? "")
        guard !insightInflight.contains(inflightKey) else { return }
        insightInflight.insert(inflightKey)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await GitInsights.shared.generatePR(
                httpBase: self.httpBase, dir: self.dir, num: num, level: level, question: question)
            self.insightInflight.remove(inflightKey)
            self.deliverInsight(outcome, level: level, key: key, question: question, commits: 0, prNum: num)
        }
    }

    private func deliverInsight(_ outcome: GitInsights.Outcome, level: String, key: String,
                                question: String?, commits: Int, prNum: Int? = nil) {
        var payload: [String: Any] = ["level": level, "key": key]
        switch outcome {
        case .ok(let text, let cost, let cached):
            payload["text"] = text; payload["cost"] = cost; payload["cached"] = cached
            var f: [String: Any] = ["level": level, "cached": cached, "folder": dir]
            if let p = prNum { f["pr"] = p } else { f["commits"] = commits }
            if let q = question { f["question"] = q }
            if let r = ref { f["machineID"] = r.machineID; f["session"] = r.session }
            ActivityJournal.shared.log("gitInsight", f)
        case .fail(let msg):
            payload["error"] = msg
        }
        if let d = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: d, encoding: .utf8) {
            eval("window.UTGit.setInsight && window.UTGit.setInsight(\(json))")
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

    private func fetchDiff(scope: String, hash: String?, hash2: String? = nil, path: String?) {
        var url = "/git/diff?dir=\(enc(dir))&scope=\(scope)"
        if let hash { url += "&hash=\(enc(hash))" }
        if let hash2 { url += "&hash2=\(enc(hash2))" }
        if let path { url += "&path=\(enc(path))" }
        fetchText(url) { [weak self] text in
            guard let self else { return }
            // Never eval a huge blob into the webview — a 100MB range diff
            // wedges the page permanently (stuck overlay until app restart).
            // New brokers cap server-side; this guards against old ones.
            var text = text
            if text.utf8.count > 3_000_000 {
                let mb = Double(text.utf8.count) / 1024 / 1024
                text = String(text.prefix(2_000_000))
                if let nl = text.lastIndex(of: "\n") { text = String(text[..<nl]) }
                text += "\n[diff truncated: \(String(format: "%.1f", mb)) MB total — too large to render fully]\n"
            }
            var meta = "{scope:\(self.js(scope))"
            if let hash { meta += ",hash:\(self.js(hash))" }
            if let hash2 { meta += ",hash2:\(self.js(hash2))" }
            if let path { meta += ",title:\(self.js(path))" } else if scope != "commit" && scope != "range" { meta += ",title:'working tree'" }
            meta += "}"
            self.eval("window.UTGit.setDiff(\(self.js(text)), \(meta))")
        }
    }

    // MARK: pull requests (via broker → gh)

    private func fetchPRs(state: String = "open") {
        eval("window.UTGit.setLoading('loading pull requests…')")
        fetch("/git/prs?dir=\(enc(dir))&state=\(enc(state))") { [weak self] json in
            // gh pr list returns a bare array; a classified error is an object.
            let payload = json.hasPrefix("[") ? "{prs:\(json)}" : json
            self?.eval("window.UTGit.setPRs(\(payload))")
        }
    }

    private func fetchPRDetail(_ num: Int) {
        // fetch detail + diff, then hand both to the page together.
        fetch("/git/pr?dir=\(enc(dir))&num=\(num)") { [weak self] prJson in
            guard let self else { return }
            if prJson.contains("\"error\"") { self.eval("window.UTGit.setPRs(\(prJson))"); return }
            self.fetchText("/git/pr/diff?dir=\(self.enc(self.dir))&num=\(num)") { diff in
                var diff = diff
                if diff.hasPrefix("{") && diff.contains("\"error\"") { diff = "" } // error object, not a diff
                if diff.utf8.count > 3_000_000 { diff = String(diff.prefix(2_000_000)) + "\n[diff truncated]\n" }
                self.eval("window.UTGit.setPRDetail(\(prJson), \(self.js(diff)))")
            }
        }
    }

    private func prAction(_ pathAndQuery: String) {
        request(pathAndQuery, method: "POST") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                let json = String(data: data, encoding: .utf8) ?? "{}"
                self.eval("window.UTGit.prActionResult(\(json))")
            case .failure(let e):
                self.eval("window.UTGit.prActionResult({error:\(self.js(e.msg))})")
            }
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

    private func request(_ pathAndQuery: String, method: String = "GET", done: @escaping (Result<Data, StringError>) -> Void) {
        guard let url = URL(string: httpBase + pathAndQuery) else {
            done(.failure(StringError("bad url"))); return
        }
        var req = URLRequest(url: url); req.timeoutInterval = 30; req.httpMethod = method
        brokerSession.dataTask(with: req) { data, resp, err in
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
        let p = GitPanel(httpBase: httpBase, dir: dir, ref: ref)
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
