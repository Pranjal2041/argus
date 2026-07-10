import AppKit
import SwiftUI
import WebKit

// The Lab pane (⇧⌘L) hosts Resources/lab/index.html in the Git panel's mold:
// the page owns layout and presentation while Swift owns data and actions.
// The host pushes the selected app palette as semantic tokens, so Lab keeps
// its instrument-ledger hierarchy while matching every ThemePicker choice.
// The page's base font size also follows the app's interface-scale setting.

@MainActor
final class LabWebPanel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = LabWebPanel()
    let webView: WKWebView
    private weak var lab: LabModel?
    private weak var state: AppState?
    private weak var files: FilesModel?
    private weak var terminals: TerminalController?
    private weak var wandb: WandbController?
    private var loaded = false

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = WKUserContentController()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.underPageBackgroundColor = Theme.nsAppBackground
        webView.setValue(false, forKey: "drawsBackground")
        super.init()
        cfg.userContentController.add(self, name: "ut")
        webView.navigationDelegate = self
        let dir = Bundle.main.resourceURL!.appendingPathComponent("lab")
        var page = dir.appendingPathComponent("index.html")
        // Dev hooks (like UT_OPEN_LAB) ride the page URL so loading order never
        // affects a fixture or destination. UT_LAB_FIXTURE powers native visual QA.
        if var c = URLComponents(url: page, resolvingAgainstBaseURL: false) {
            var query: [URLQueryItem] = []
            let env = ProcessInfo.processInfo.environment
            if let fixture = env["UT_LAB_FIXTURE"], !fixture.isEmpty {
                query.append(URLQueryItem(name: "fixture", value: fixture))
            }
            if let view = env["UT_LAB_VIEW"], ["notes", "home", "guidance", "research"].contains(view) {
                query.append(URLQueryItem(name: "view", value: view))
            }
            if !query.isEmpty {
                c.queryItems = query
                page = c.url ?? page
            }
        }
        webView.loadFileURL(page, allowingReadAccessTo: dir)
    }

    func attach(lab: LabModel, state: AppState, files: FilesModel,
                terminals: TerminalController, wandb: WandbController) {
        self.lab = lab
        self.state = state
        self.files = files
        self.terminals = terminals
        self.wandb = wandb
        applyTheme()
        applyScale()
        pushData()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded = true
            self.applyTheme()
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

    private func hex(_ color: NSColor) -> String {
        let value = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x",
                      Int(value.redComponent * 255),
                      Int(value.greenComponent * 255),
                      Int(value.blueComponent * 255))
    }

    private func hex(_ color: SwiftUI.Color) -> String { hex(NSColor(color)) }

    /// Pushes both chrome colors and semantic status colors. The web page derives
    /// restrained Lab surfaces from these values while preserving the theme's
    /// green/success, blue/running, orange/waiting, and red/failure signals.
    func applyTheme() {
        let palette = Theme.current
        webView.underPageBackgroundColor = palette.nsAppBackground
        guard loaded else { return }
        let spec: [String: Any] = [
            "id": palette.id,
            "name": palette.name,
            "isLight": palette.isLight,
            "canvas": hex(palette.nsAppBackground),
            "sidebar": hex(palette.sidebarBackground),
            "surface": hex(palette.surface),
            "border": hex(palette.border),
            "accent": hex(palette.accent),
            "selection": hex(palette.selection),
            "text": hex(palette.textPrimary),
            "textSecondary": hex(palette.textSecondary),
            "textQuiet": hex(palette.textTertiary),
            "success": hex(palette.attached),
            "running": hex(palette.running),
            "waiting": hex(palette.waiting),
            "unseen": hex(palette.unseen),
            "danger": hex(palette.unreachable),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: spec),
           let json = String(data: data, encoding: .utf8) {
            eval("window.UTLab.setTheme(\(json))")
        }
    }

    /// Carries the app's interface scale as 24 * uiScale. The page combines that
    /// host preference with its viewport-adaptive scale and Lab-specific A−/A+ setting.
    func applyScale() {
        guard loaded else { return }
        let scale = UserDefaults.standard.object(forKey: "ut.uiScale") as? Double ?? 1.0
        eval("window.UTLab.setFontSize(\((24.0 * scale * 10).rounded() / 10))")
    }

    // MARK: data → page

    func pushData() {
        guard loaded, let lab else { return }
        func notes(_ ns: [LabEventInfo]?) -> [[String: Any]] {
            (ns ?? []).map {
                ["id": $0.id, "time": $0.time, "author": $0.author,
                 "kind": $0.kind, "text": $0.text ?? ""]
            }
        }
        let sets: [[String: Any]] = lab.sets.map { c in
            var d: [String: Any] = [
                "id": c.id, "setID": c.brief.set.id, "machineID": c.machineID,
                "machineName": c.machineName, "project": c.brief.set.project,
                "cwd": c.brief.set.cwd, "created": c.brief.set.created,
                "policy": c.brief.policy ?? "full-only",
                "offline": c.offline,
                "archived": c.brief.archived ?? false,
                "keyActive": lab.activeKeyBySet[c.id] != nil,
                "notes": notes(c.brief.notes),
                "setNotes": notes(c.brief.setEvents?.filter { $0.kind == "note" || $0.kind == "hnote" }),
            ]
            if !c.mirroredAt.isEmpty { d["mirroredAt"] = c.mirroredAt }
            d["runs"] = (c.brief.runs ?? []).map { r -> [String: Any] in
                var rd: [String: Any] = ["id": r.id, "status": r.status,
                                         "exitCode": r.exitCode,
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
            var d: [String: Any] = [
                "id": r.id, "set": r.proposal.set, "machineID": r.machineID,
                "machineName": r.machineName, "run": r.proposal.run,
                "project": r.proposal.project, "intent": r.proposal.intent,
                "created": r.proposal.created,
            ]
            if let v = r.proposal.tier { d["tier"] = v }
            if let v = r.proposal.group { d["group"] = v }
            if let v = r.proposal.argv { d["argv"] = v }
            if let v = r.proposal.cwd { d["cwd"] = v }
            return d
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
            async let eventRequest = lab.runEvents(card, run: run)
            async let manifestRequest = lab.runFiles(card, run: run)
            let (events, manifest) = await (eventRequest, manifestRequest)
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
            let manifestArr: [[String: Any]] = manifest.map { ["name": $0.name, "size": $0.size] }
            let payload: [String: Any] = ["events": evArr, "files": files, "manifest": manifestArr]
            if let d = try? JSONSerialization.data(withJSONObject: payload), let s = String(data: d, encoding: .utf8) {
                self.eval("window.UTLab.setRunDetail(\(self.jsString(cardID)), \(self.jsString(run)), \(s))")
            }
        }
    }

    // MARK: page → actions

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let self, let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }
            self.handle(type, dict)
        }
    }

    private func reportAction(_ id: String, ok: Bool, message: String) {
        guard !id.isEmpty else { return }
        eval("window.UTLab.actionResult(\(jsString(id)), \(ok ? "true" : "false"), \(jsString(message)))")
    }

    private func performAction(id: String, success: String,
                               detail: (card: String, run: String)? = nil,
                               _ operation: @escaping @MainActor () async -> Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await operation()
            if let lab = self.lab, let state = self.state {
                lab.refresh(state)
                if ok, let detail, !detail.run.isEmpty {
                    self.sendRunDetail(cardID: detail.card, run: detail.run)
                }
            }
            self.reportAction(id, ok: ok,
                              message: ok ? success : "The Lab broker did not accept this change.")
        }
    }

    private func openWandb(_ reference: String, card: LabModel.SetCard, session: String) {
        let rawURL = reference.hasPrefix("http://") || reference.hasPrefix("https://")
            ? reference : "https://wandb.ai/" + reference
        guard let url = URL(string: rawURL) else { return }
        guard !session.isEmpty, let terminals, let wandb, let state else {
            NSWorkspace.shared.open(url)
            return
        }
        let path = url.pathComponents
        let runID: String
        if let runs = path.firstIndex(of: "runs"), path.indices.contains(runs + 1) {
            runID = path[runs + 1]
        } else {
            runID = path.last ?? reference
        }
        let ref = SessionRef(machineID: card.machineID, session: session)
        let run = WandbRun(url: url, runId: runID, label: runID)
        terminals.mergeWandb([run], for: ref)
        terminals.showWandb(ref, run: run)
        wandb.navigate(to: url)
        state.selection = ref
        state.showLab = false
    }

    private func handle(_ type: String, _ d: [String: Any]) {
        guard let lab, let state else { return }
        func str(_ k: String) -> String { d[k] as? String ?? "" }
        func card() -> LabModel.SetCard? { lab.sets.first(where: { $0.id == str("card") }) }
        let actionID = str("actionID")
        switch type {
        case "refresh":
            lab.refresh(state)
        case "decideKey":
            if let k = lab.pendingKeys.first(where: { $0.id == str("id") }) {
                let approve = d["approve"] as? Bool ?? false
                performAction(id: actionID, success: approve ? "Access approved" : "Access denied") {
                    await lab.decideKeyNow(k, approve: approve, project: str("project"))
                }
            } else { reportAction(actionID, ok: false, message: "That access request is no longer pending.") }
        case "decideRun":
            if let c = card() {
                let run = str("run")
                let approve = d["approve"] as? Bool ?? false
                performAction(id: actionID, success: approve ? "Experiment approved" : "Experiment rejected",
                              detail: (c.id, run)) {
                    await lab.decideRunNow(c, run: run, approve: approve, note: str("note"))
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "hide":
            if let c = card() {
                let run = str("run"), target = str("target")
                performAction(id: actionID, success: "Agent claim hidden from briefs",
                              detail: (c.id, run)) {
                    await lab.hide(c, target: target)
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "note":
            if let c = card() {
                let run = str("run")
                performAction(id: actionID, success: "Human note added", detail: (c.id, run)) {
                    await lab.postNoteNow(c, scope: str("scope"), run: run, text: str("text"))
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "hubNote":
            performAction(id: actionID, success: "Guidance published") {
                await lab.postHubNoteNow(machineID: str("machineID"), scope: str("scope"),
                                         project: str("project"), text: str("text"))
            }
        case "hubNoteAll":
            performAction(id: actionID, success: "Guidance published everywhere") {
                await lab.postHubNoteAllNow(text: str("text"))
            }
        case "hubHide":
            performAction(id: actionID, success: "Guidance hidden from agent briefs") {
                await lab.hideHubNoteNow(machineID: str("machineID"), scope: str("scope"),
                                         project: str("project"), target: str("target"))
            }
        case "policy":
            if let c = card() {
                performAction(id: actionID, success: "Approval policy updated") {
                    await lab.setPolicyNow(c, policy: str("policy"))
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "archive":
            if let c = card() {
                let run = str("run"), on = d["on"] as? Bool ?? true
                performAction(id: actionID, success: on ? "Moved to archive" : "Restored from archive",
                              detail: (c.id, run)) {
                    await lab.setArchivedNow(c, run: run, on: on)
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "revoke":
            if let c = card() {
                performAction(id: actionID, success: "Agent access revoked") {
                    await lab.revokeKeyNow(c)
                }
            } else { reportAction(actionID, ok: false, message: "That experiment set is no longer available.") }
        case "openTerminal":
            state.selection = SessionRef(machineID: str("machineID"), session: str("session"))
            state.showLab = false
        case "openFiles":
            if let c = card(), let m = state.machines.first(where: { $0.id == c.machineID }), let files {
                files.addTab(m, startPath: str("cwd"))
                state.openWindowRequest = "files"
            }
        case "openWandb":
            if let c = card() { openWandb(str("run"), card: c, session: str("session")) }
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
    @EnvironmentObject var terminals: TerminalController
    @EnvironmentObject var wandb: WandbController
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    var body: some View {
        LabWebHost()
            .onAppear {
                lab.bind(state)
                lab.setPaneVisible(true)
                LabWebPanel.shared.attach(lab: lab, state: state, files: files,
                                          terminals: terminals, wandb: wandb)
            }
            .onDisappear { lab.setPaneVisible(false) }
            .onChange(of: uiScale) { _ in LabWebPanel.shared.applyScale() }
            .onReceive(NotificationCenter.default.publisher(for: .utThemeChanged)) { _ in
                LabWebPanel.shared.applyTheme()
            }
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
