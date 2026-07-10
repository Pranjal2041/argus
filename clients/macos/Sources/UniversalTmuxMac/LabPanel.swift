import AppKit
import SwiftUI
import WebKit

// The Lab pane (⇧⌘L) hosts Resources/lab/index.html in the Git panel's mold:
// the page owns all presentation (it has its own designed palette and does
// NOT take the app theme — pushing the theme over it kept collapsing every
// design into the same slate), Swift owns data and actions. The page's base
// font size follows the app's interface-scale setting via UTLab.setFontSize.

@MainActor
final class LabWebPanel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = LabWebPanel()
    let webView: WKWebView
    private weak var lab: LabModel?
    private weak var state: AppState?
    private weak var files: FilesModel?
    private var loaded = false

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.underPageBackgroundColor = NSColor(red: 0.086, green: 0.094, blue: 0.114, alpha: 1) // page bg #16181d
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        cfg.userContentController.add(self, name: "ut")
        webView.navigationDelegate = self
        let dir = Bundle.main.resourceURL!.appendingPathComponent("lab")
        var page = dir.appendingPathComponent("index.html")
        // dev hook (like UT_OPEN_LAB): land on a specific view at launch. The
        // view rides the page URL so there is no eval-timing dependence.
        if let v = ProcessInfo.processInfo.environment["UT_LAB_VIEW"], v == "notes" || v == "home",
           var c = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            c.query = "view=" + v
            page = c.url ?? page
        }
        webView.loadFileURL(page, allowingReadAccessTo: dir)
    }

    func attach(lab: LabModel, state: AppState, files: FilesModel) {
        self.lab = lab
        self.state = state
        self.files = files
        applyScale()
        pushData()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded = true
            self.applyScale()
            self.pushData()
            // dev hook (like UT_OPEN_LAB): land on a specific view at launch
            if let v = ProcessInfo.processInfo.environment["UT_LAB_VIEW"], v == "notes" || v == "home" {
                self.eval("window.UTLab.openView(\(self.jsString(v)))")
            }
        }
    }

    private func eval(_ js: String) { webView.evaluateJavaScript(js, completionHandler: nil) }

    private func jsString(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        let arr = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// Carries the app's interface-scale to the page as 24 * uiScale; the page
    /// derives uiScale = pushed/24 and multiplies its per-region sizes with it
    /// (RAIL_ZOOM / PAGE_ZOOM in the page — the user's preferred proportions).
    func applyScale() {
        guard loaded else { return }
        let scale = UserDefaults.standard.object(forKey: "ut.uiScale") as? Double ?? 1.0
        eval("window.UTLab.setFontSize(\((24.0 * scale * 10).rounded() / 10))")
    }

    // MARK: data → page

    func pushData() {
        guard loaded, let lab else { return }
        func notes(_ ns: [LabEventInfo]?) -> [[String: Any]] {
            (ns ?? []).map { ["id": $0.id, "author": $0.author, "text": $0.text ?? ""] }
        }
        let sets: [[String: Any]] = lab.sets.map { c in
            var d: [String: Any] = [
                "id": c.id, "setID": c.brief.set.id, "machineID": c.machineID,
                "machineName": c.machineName, "project": c.brief.set.project,
                "cwd": c.brief.set.cwd, "policy": c.brief.policy ?? "full-only",
                "offline": c.offline,
                "archived": c.brief.archived ?? false,
                "keyActive": lab.activeKeyBySet[c.brief.set.id] != nil,
                "notes": notes(c.brief.notes),
                "setNotes": notes(c.brief.setEvents?.filter { $0.kind == "note" || $0.kind == "hnote" }),
            ]
            d["runs"] = (c.brief.runs ?? []).map { r -> [String: Any] in
                var rd: [String: Any] = ["id": r.id, "status": r.status,
                                         "archived": r.archived ?? false]
                if let v = r.tier { rd["tier"] = v }
                if let v = r.group { rd["group"] = v }
                if let v = r.latest { rd["latest"] = v }
                if let v = r.started { rd["started"] = v }
                return rd
            }
            return d
        }
        let keys: [[String: Any]] = lab.pendingKeys.map { k in
            var d: [String: Any] = ["id": k.id, "machineID": k.machineID, "machineName": k.machineName,
                                    "project": k.key.project, "cwd": k.key.cwd, "created": k.key.created]
            if let s = k.key.session, !s.isEmpty { d["session"] = s }
            return d
        }
        let pruns: [[String: Any]] = lab.pendingRuns.map { r in
            ["id": r.id, "set": r.proposal.set, "machineID": r.machineID, "run": r.proposal.run,
             "project": r.proposal.project, "intent": r.proposal.intent, "created": r.proposal.created]
        }
        let hub: [[String: Any]] = lab.hubNotes.map { g in
            ["machineID": g.machineID, "machineName": g.machineName,
             "notes": g.notes.map { n -> [String: Any] in
                 var d: [String: Any] = ["scope": n.scope, "id": n.id, "time": n.time,
                                         "author": n.author, "text": n.text, "hidden": n.hidden]
                 if let p = n.project, !p.isEmpty { d["project"] = p }
                 return d
             }]
        }
        let model: [String: Any] = ["sets": sets, "pendingKeys": keys, "pendingRuns": pruns, "hubNotes": hub]
        if let d = try? JSONSerialization.data(withJSONObject: model), let s = String(data: d, encoding: .utf8) {
            eval("window.UTLab.setData(\(s))")
        }
    }

    private func sendRunDetail(cardID: String, run: String) {
        guard let lab, let card = lab.sets.first(where: { $0.id == cardID }) else { return }
        Task { @MainActor in
            let events = await lab.runEvents(card, run: run)
            let env = events.first(where: { $0.kind == "run-start" })?.data
                ?? events.first(where: { $0.kind == "proposal" })?.data
            var files: [String: Any] = [:]
            var params: [[String: String]] = []
            for ref in env?.params ?? [] {
                let name = "files/" + (ref.path as NSString).lastPathComponent
                if let t = await lab.runFileText(card, run: run, name: name) {
                    params.append(["path": ref.path, "text": String(t.prefix(6000))])
                }
            }
            if !params.isEmpty { files["params"] = params }
            if (env?.snapshot?.patchBytes ?? 0) > 0,
               let d = await lab.runFileText(card, run: run, name: "snapshot/diff.patch") {
                files["diff"] = String(d.prefix(30000))
            }
            if let l = await lab.runFileText(card, run: run, name: "log.txt", tailBytes: 16000) {
                files["log"] = l
            }
            if let e = await lab.runFileText(card, run: run, name: "files/env.txt") {
                files["env"] = String(e.prefix(8000))
            }
            var evArr: [[String: Any]] = []
            let enc = JSONEncoder()
            for e in events {
                if let d = try? enc.encode(e),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    evArr.append(o)
                }
            }
            let payload: [String: Any] = ["events": evArr, "files": files]
            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) {
                self.eval("window.UTLab.setRunDetail(\(self.jsString(cardID)), \(self.jsString(run)), \(s))")
            }
        }
    }

    // MARK: page → actions

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        Task { @MainActor in self.handle(type, dict) }
    }

    private func handle(_ type: String, _ d: [String: Any]) {
        guard let lab, let state else { return }
        func str(_ k: String) -> String { d[k] as? String ?? "" }
        func card() -> LabModel.SetCard? { lab.sets.first(where: { $0.id == str("card") }) }
        switch type {
        case "refresh":
            lab.refresh(state)
        case "decideKey":
            if let k = lab.pendingKeys.first(where: { $0.id == str("id") }) {
                lab.decideKey(k, approve: d["approve"] as? Bool ?? false, project: str("project"), state: state)
            }
        case "decideRun":
            if let c = card() {
                lab.decideRun(c, run: str("run"), approve: d["approve"] as? Bool ?? false, note: str("note"), state: state)
                let run = str("run")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.sendRunDetail(cardID: c.id, run: run)
                }
            }
        case "hide":
            if let c = card() {
                let run = str("run"), target = str("target")
                Task { @MainActor in
                    _ = await lab.hide(c, target: target)
                    lab.refresh(state)
                    if !run.isEmpty { self.sendRunDetail(cardID: c.id, run: run) }
                }
            }
        case "note":
            if let c = card() { lab.postNote(c, scope: str("scope"), text: str("text"), state: state) }
        case "hubNote":
            lab.postHubNote(machineID: str("machineID"), scope: str("scope"),
                            project: str("project"), text: str("text"), state: state)
        case "hubNoteAll":
            lab.postHubNoteAll(text: str("text"), state: state)
        case "hubHide":
            lab.hideHubNote(machineID: str("machineID"), scope: str("scope"),
                            project: str("project"), target: str("target"), state: state)
        case "policy":
            if let c = card() { lab.setPolicy(c, policy: str("policy"), state: state) }
        case "archive":
            if let c = card() { lab.setArchived(c, run: str("run"), on: d["on"] as? Bool ?? true, state: state) }
        case "revoke":
            if let c = card() { lab.revokeKey(c, state: state) }
        case "openTerminal":
            state.selection = SessionRef(machineID: str("machineID"), session: str("session"))
            state.showLab = false
        case "openFiles":
            if let c = card(), let m = state.machines.first(where: { $0.id == c.machineID }), let files {
                files.addTab(m, startPath: str("cwd"))
                state.openWindowRequest = "files"
            }
        case "openWandb":
            if let u = URL(string: "https://wandb.ai/" + str("run")) { NSWorkspace.shared.open(u) }
        case "needRunDetail":
            sendRunDetail(cardID: str("card"), run: str("run"))
        default:
            break
        }
    }
}

// MARK: - the SwiftUI face of the pane

struct LabCenterView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lab: LabModel
    @EnvironmentObject var files: FilesModel
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    var body: some View {
        LabWebHost()
            .onAppear {
                lab.bind(state)
                lab.setPaneVisible(true)
                LabWebPanel.shared.attach(lab: lab, state: state, files: files)
            }
            .onDisappear { lab.setPaneVisible(false) }
            .onChange(of: uiScale) { _ in LabWebPanel.shared.applyScale() }
            // push AFTER the published values settle (onReceive fires on willSet)
            .onReceive(lab.$sets) { _ in DispatchQueue.main.async { LabWebPanel.shared.pushData() } }
            .onReceive(lab.$pendingKeys) { _ in DispatchQueue.main.async { LabWebPanel.shared.pushData() } }
            .onReceive(lab.$pendingRuns) { _ in DispatchQueue.main.async { LabWebPanel.shared.pushData() } }
            .onReceive(lab.$hubNotes) { _ in DispatchQueue.main.async { LabWebPanel.shared.pushData() } }
    }
}

private struct LabWebHost: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { LabWebPanel.shared.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
