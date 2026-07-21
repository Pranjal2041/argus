import Foundation
import SwiftUI

/// A host running a broker (one entry in the sidebar).
struct Machine: Identifiable, Hashable {
    let id: String
    var name: String
    var host: String = ""  // broker's OS hostname from /whoami; equals /history's `node`, so a
                           // history row maps to this machine even when name (--name) differs
    var os: String = ""    // runtime.GOOS from /whoami; empty only for older brokers
    var isLocal: Bool
    var httpBase: String // e.g. http://127.0.0.1:8722
    var wsBase: String   // e.g. ws://127.0.0.1:8722
}

/// One tmux session as reported by a broker's /sessions endpoint.
struct SessionInfo: Identifiable, Hashable, Codable {
    var name: String
    var windows: Int
    var attached: Bool
    var activity: Int64
    var path: String?    // optional: older brokers don't send it
    var state: String = "idle"  // broker agent-state: "working" | "waiting" | "idle"
    var agent: Bool = false      // created by the mesh (ut spawn): hidden unless "Show agent sessions"
    var hidden: Bool = false     // user-hidden; broker-owned so the hide syncs across devices
    var tmuxID: String?          // broker's STABLE session handle ($N): unchanged across rename — we connect by it so a renamed pane never sticks on "reconnecting"
    var id: String { name }

    /// True when the broker reports the agent as blocked on the user.
    var isWaiting: Bool { state == "waiting" }

    enum CodingKeys: String, CodingKey {
        case name, windows, attached, activity, path, state, agent, hidden
        case tmuxID = "id"
    }

    init(
        name: String,
        windows: Int = 1,
        attached: Bool = false,
        activity: Int64 = 0,
        path: String? = nil,
        state: String = "idle",
        agent: Bool = false,
        hidden: Bool = false,
        tmuxID: String? = nil
    ) {
        self.name = name
        self.windows = windows
        self.attached = attached
        self.activity = activity
        self.path = path
        self.state = state
        self.agent = agent
        self.hidden = hidden
        self.tmuxID = tmuxID
    }

    // Custom decoder: Swift's synthesized `Decodable` does NOT apply the
    // `= "idle"` default for a missing key, so an older broker that omits
    // `state` (or `path`) would make the whole `/sessions` decode throw.
    // Decode the optional fields with `decodeIfPresent` so they fall back
    // gracefully and old brokers keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        windows = try c.decode(Int.self, forKey: .windows)
        attached = try c.decode(Bool.self, forKey: .attached)
        activity = try c.decode(Int64.self, forKey: .activity)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        agent = try c.decodeIfPresent(Bool.self, forKey: .agent) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        // Normalize an EMPTY id to nil: the ConPTY (Windows) backend has no stable session
        // id and reports "id":"" — without this, `tmuxID ?? name` would pick the empty
        // string and the client would connect to /ws?session= (nothing), so every Windows
        // session stuck on "connecting" after a reconnect. Empty id → fall back to the name.
        tmuxID = (try c.decodeIfPresent(String.self, forKey: .tmuxID)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct SessionsResponse: Codable { let sessions: [SessionInfo] }

enum SessionRefreshScope: Equatable {
    case foreground
    case all
}

/// Merge a broker response into the local cache without letting the two-second
/// foreground path churn hidden/agent rows. A full response remains authoritative;
/// a foreground response replaces only ordinary visible sessions and retains the
/// last background snapshot until its 30-second refresh.
func mergeSessionSnapshot(
    current: [SessionInfo],
    fetched: [SessionInfo],
    scope: SessionRefreshScope,
    machineID: String,
    locallyHidden: Set<String>
) -> [SessionInfo] {
    var byName: [String: SessionInfo] = [:]
    if scope == .foreground {
        for info in current {
            let refID = machineID + "/" + info.name
            if info.agent || info.hidden || locallyHidden.contains(refID) {
                byName[info.name] = info
            }
        }
    }
    for info in fetched { byName[info.name] = info }

    let previous = Dictionary(uniqueKeysWithValues: current.map { ($0.name, $0) })
    return byName.values.map { fresh in
        guard let old = previous[fresh.name], sessionMetadataMatchesIgnoringActivity(old, fresh) else {
            return fresh
        }
        var coalesced = fresh
        // A newly-active pane after a quiet period updates immediately. Continuous
        // output advances the sidebar timestamp at most every 30 seconds instead of
        // rebuilding it for every two-second activity tick.
        if fresh.activity <= old.activity || fresh.activity - old.activity < 30 {
            coalesced.activity = old.activity
        }
        return coalesced
    }.sorted { $0.name < $1.name }
}

private func sessionMetadataMatchesIgnoringActivity(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
    lhs.name == rhs.name
        && lhs.windows == rhs.windows
        && lhs.attached == rhs.attached
        && lhs.path == rhs.path
        && lhs.state == rhs.state
        && lhs.agent == rhs.agent
        && lhs.hidden == rhs.hidden
        && lhs.tmuxID == rhs.tmuxID
}

/// Identifies the selected (machine, session) pair.
struct SessionRef: Identifiable, Hashable {
    let machineID: String
    let session: String
    var id: String { machineID + "/" + session }
}

/// A user-hidden session that still exists, for the ⇧⌘B restore picker.
struct HiddenPanel: Identifiable {
    let ref: SessionRef
    let machineName: String
    let info: SessionInfo
    var id: String { ref.id }
}

/// One stretch of time a session's folder (cwd) stayed put — broker /history.
struct FolderSpan: Codable, Hashable {
    let path: String
    let first: Int64
    let last: Int64
}

/// A recorded session in the broker's durable history (name, node, folders it ran
/// in, timestamps). Persists after the session is gone, for the History view.
struct SessionHistoryItem: Codable, Identifiable, Hashable {
    let name: String
    let node: String
    var agent: Bool = false
    var folders: [FolderSpan] = []
    let first: Int64
    let last: Int64
    var alive: Bool = false
    var id: String { node + "/" + name + "/" + String(first) }
}

struct SessionHistoryResponse: Codable { let sessions: [SessionHistoryItem] }

/// A saved "standard workflow": spin up a session in a known place and type a known
/// command sequence. Shown in the Workflows panel grouped by machine; click to run.
struct Workflow: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var machine: String        // wildcard pattern — "babel-*", "this mac", an exact name
    var folder: String         // working dir, e.g. "~/scratch" (~ expanded by the shell)
    var commands: String       // command sequence, one per line
    var notes: String = ""     // optional description
    var colorHex: String = ""  // optional accent ("" = default)
}

/// A pending run whose machine pattern matched more than one online host — the user
/// picks which one in a small dialog.
struct WorkflowPick: Identifiable {
    let id = UUID()
    let workflow: Workflow
    let machines: [Machine]
}

/// One checklist item. Keeps created/completed timestamps so the store doubles as a
/// record you can analyze later (how many you create, how long they take, etc.).
struct TodoItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String
    var done = false
    var createdAt = Date()
    var completedAt: Date?
}

/// A todo board ("Todo Map"), keyed by <machine, session name> — or the single Misc
/// board. Persists independently of the session: kill it, reopen the same machine + name
/// later, and the board is still here (matched by that key).
struct TodoBoard: Identifiable, Codable, Hashable {
    var id = UUID()
    var machine = ""        // "" together with isMisc for the Misc board
    var session = ""
    var isMisc = false
    var items: [TodoItem] = []
    var pending: Int { items.lazy.filter { !$0.done }.count }
}

/// Wire format for the /userdata sync store: a timestamped payload. `updatedAt` is unix
/// millis; last-write-wins by comparing it. Shared by the Mac app and the phone.
struct SyncEnvelope<T: Codable>: Codable {
    var updatedAt: Int64
    var data: T
    /// Required only when a user intentionally removes records. The broker rejects a
    /// shrinking snapshot without this bit, preventing initialization/decoding failures
    /// from silently replacing populated data.
    var allowDestructive: Bool? = nil

    init(updatedAt: Int64, data: T, allowDestructive: Bool = false) {
        self.updatedAt = updatedAt
        self.data = data
        self.allowDestructive = allowDestructive ? true : nil
    }
}

/// A free-form note in the Notes Hub — multiline text, optionally checkable, not tied to
/// any machine or session. Grouped/sorted by `editedAt` (last content edit) in the view.
struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var text: String = ""
    var done = false
    var createdAt = Date()
    var editedAt = Date()
    init() {}
    // Decode-tolerant: `editedAt` falls back to `createdAt` for notes written before the
    // field existed, so old/cross-version data never fails to load.
    enum CodingKeys: String, CodingKey { case id, text, done, createdAt, editedAt }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt) ?? createdAt
    }
}

/// Sessions on one machine grouped by their working directory.
struct FolderGroup: Identifiable {
    let folder: String
    let sessions: [SessionInfo]
    var id: String { folder }
}

@MainActor
final class AppState: ObservableObject {
    /// Tests import the production executable target, so UserDefaults.standard can point
    /// at the real app domain. Keep every persistence/network side effect disabled under
    /// XCTest even if a future test forgets to request isolation explicitly.
    private var persistenceEnabled = true
    private var pendingDestructiveSync: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ut.pendingDestructiveSync") ?? [])
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    @Published var machines: [Machine]
    @Published var sessionsByMachine: [String: [SessionInfo]] = [:]
    @Published var statusByMachine: [String: String] = [:]
    @Published var rttByMachine: [String: Int] = [:]  // round-trip ms per machine
    @Published var selection: SessionRef? {
        didSet {
            // Activity journal dwell: attention moved (nil selection closes it too).
            ActivityJournal.shared.selectionChanged(to: selection)
            guard let ref = selection else { return }
            // Visiting a panel clears its orange "done, unseen" flag → back to green.
            if unseen.contains(ref.id) { unseen.remove(ref.id) }
            // Viewing a waiting session acknowledges it → clears it from the inbox AND
            // the Dock badge immediately (and durably: a plain state-flip used to be
            // reverted by the very next poll, since the broker still reports "waiting").
            if isWaiting(ref) { acknowledge(ref) }
            // Re-poll that host shortly so we converge to the broker's truth fast.
            if let m = machines.first(where: { $0.id == ref.machineID }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh(m) }
            }
        }
    }

    // UI state shared with menu commands (so ⌘N / ⌃⌘S / ⌘L / ⌘F / ⌘K work app-wide).
    @Published var columns: NavigationSplitViewVisibility = .all
    @Published var showNew = false
    @Published var renameTarget: SessionRef?
    @Published var renameText = ""
    @Published var killTarget: SessionRef?
    @Published var showFind = false
    @Published var findText = ""
    @Published var findFocusToken = 0     // bumped to (re)focus the find field
    @Published var showPalette = false
    @Published var openWindowRequest: String?  // palette → ContentView bridge to SwiftUI openWindow
    @Published var showOverview = true          // command-center panel is the home view (⇧⌘A); set false when diving into a session
    @Published var renderDocument: RenderDocument? // non-nil → styled/static Render overlay is up
    @Published var renderArtifactContext: ArtifactPanelContext? // immutable panel identity captured with Render
    @Published var renderPDFCaptureInProgress = false // freezes semantic/visual changes during WebKit PDF capture
    @Published var searchFocusToken = 0   // bumped to request focusing the filter field
    @Published var isRefreshing = false
    private var lastRTTPublishedAt: [String: Date] = [:]
    private var sessionRefreshesInFlight: [String: Int] = [:]
    private var pendingFullSessionRefresh: [String: Machine] = [:]

    /// User-pinned working directory per session (`ref.id` → absolute path on the
    /// host). Used as the resolve base for a terminal cmd+click when the broker's
    /// reported cwd is stale — notably the Windows ConPTY backend, which can't yet
    /// track `cd`. Persisted across launches.
    @Published var pathOverrides: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "ut.pathOverrides") as? [String: String]) ?? [:]

    /// Whether agent-spawned (`ut spawn`) sessions appear in the sidebar. They are
    /// background work — hidden by default, revealed by the Settings toggle.
    /// Persisted across launches.
    @Published var showAgentSessions: Bool = UserDefaults.standard.bool(forKey: "ut.showAgentSessions") {
        didSet { UserDefaults.standard.set(showAgentSessions, forKey: "ut.showAgentSessions") }
    }

    /// "Keep this Mac awake & reachable while locked." When on, hold a power assertion that
    /// stops the system from idle-sleeping — so locking the screen (display off, lock UI)
    /// does NOT pause this Mac's tmux sessions, its broker, or the processes inside them,
    /// and the phone keeps reaching them. The display is still allowed to sleep. Honored on
    /// battery too (unlike `caffeinate -s`, which is AC-only). NOTE: a power assertion stops
    /// IDLE sleep, not LID-CLOSE sleep — a closed-lid MacBook on battery still sleeps.
    /// Persisted, and re-applied on launch.
    @Published var keepAwake: Bool = UserDefaults.standard.bool(forKey: "ut.keepAwake") {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "ut.keepAwake")
            applyKeepAwake()
        }
    }
    /// Activity journal on/off (default on). The journal itself also checks this
    /// on every event, so flipping it stops capture immediately.
    @Published var journalEnabled: Bool = ActivityJournal.isEnabled {
        didSet { ActivityJournal.setEnabled(journalEnabled) }
    }

    /// Held token for the active "prevent idle system sleep" assertion (nil when off).
    private var keepAwakeToken: NSObjectProtocol?

    /// Create or release the power assertion to match `keepAwake`.
    private func applyKeepAwake() {
        if keepAwake {
            guard keepAwakeToken == nil else { return }
            keepAwakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Keep this Mac reachable while the screen is locked")
        } else if let token = keepAwakeToken {
            ProcessInfo.processInfo.endActivity(token)
            keepAwakeToken = nil
        }
    }

    // MARK: Standard Workflows — saved recipes (machine + folder + command sequence).

    /// Drives the ⇧⌘W Workflows panel.
    @Published var showWorkflows = false
    /// Persisted workflow definitions (UserDefaults `ut.workflows.v1`).
    @Published var workflows: [Workflow] = AppState.loadWorkflows() {
        didSet {
            guard persistenceEnabled else { return }
            AppState.saveWorkflows(workflows)
            if !applyingRemoteWorkflows {       // a local edit → stamp + push to the sync host
                workflowsUpdatedAt = nowMs()
                pushUserData("workflows", workflows, workflowsUpdatedAt,
                             allowDestructive: pendingDestructiveSync.contains("workflows"))
            }
        }
    }
    /// Set when a run's machine pattern matched >1 online host — the view shows a picker.
    @Published var workflowPick: WorkflowPick?
    /// A transient error to surface (no online match, create failed).
    @Published var workflowError: String?

    private static func loadWorkflows() -> [Workflow] {
        guard let d = UserDefaults.standard.data(forKey: "ut.workflows.v1"),
              let w = try? JSONDecoder().decode([Workflow].self, from: d) else { return [] }
        return w
    }
    private static func saveWorkflows(_ w: [Workflow]) {
        if let d = try? JSONEncoder().encode(w) { UserDefaults.standard.set(d, forKey: "ut.workflows.v1") }
    }

    func upsertWorkflow(_ wf: Workflow) {
        if let i = workflows.firstIndex(where: { $0.id == wf.id }) { workflows[i] = wf }
        else { workflows.append(wf) }
    }
    func deleteWorkflow(_ wf: Workflow) {
        guard workflows.contains(where: { $0.id == wf.id }) else { return }
        markDestructiveSync("workflows")
        workflows.removeAll { $0.id == wf.id }
    }

    /// Online machines whose name matches a workflow's wildcard pattern (`*` → any run of
    /// chars, case-insensitive, full match). The local machine also matches its hostname
    /// and the friendly aliases "this mac" / "mac" / "local".
    func machinesMatching(_ pattern: String) -> [Machine] {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return [] }
        let rx = "^" + NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*") + "$"
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return [] }
        func hit(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        return machines.filter { m in
            if hit(m.name) { return true }
            if m.isLocal, hit(ProcessInfo.processInfo.hostName) || hit("this mac") || hit("mac") || hit("local") { return true }
            return false
        }
    }

    /// Run a workflow: resolve its machine pattern, then run on the single online match,
    /// or ask which one if several match (or surface an error if none are reachable).
    func runWorkflow(_ wf: Workflow) {
        let ms = machinesMatching(wf.machine)
        if ms.isEmpty { workflowError = "No reachable machine matches “\(wf.machine)”."; return }
        if ms.count == 1 { runWorkflow(wf, on: ms[0]) } else { workflowPick = WorkflowPick(workflow: wf, machines: ms) }
    }

    /// Run a workflow on a specific host. The session is named after the workflow: if one
    /// by that name already exists on this host it's just opened (no re-typing); otherwise
    /// it's created and the command sequence is typed in.
    func runWorkflow(_ wf: Workflow, on m: Machine) {
        // Activity journal: commissioning work is a first-class interaction.
        ActivityJournal.shared.log("workflowRun", [
            "workflow": wf.name, "machineID": m.id, "folder": wf.folder,
        ])
        workflowPick = nil
        showWorkflows = false
        showOverview = false
        showArtifacts = false
        let ref = SessionRef(machineID: m.id, session: wf.name)
        if (sessionsByMachine[m.id] ?? []).contains(where: { $0.name == wf.name }) {
            selection = ref                              // already running → just open it
            return
        }
        control(m.id, action: "create", session: wf.name) { ok in   // `then` runs on main
            guard ok else { self.workflowError = "Could not create session “\(wf.name)” on \(m.name)."; return }
            self.selection = ref
            self.refreshAll()
            self.sendWorkflowCommands(wf, to: ref)
        }
    }

    /// Type a freshly-created workflow session: `cd` into the folder, then each command
    /// line, paced so the shell keeps up. Goes over the broker's /send (tmux send-keys),
    /// so the session need not be attached.
    private func sendWorkflowCommands(_ wf: Workflow, to ref: SessionRef) {
        var lines: [String] = []
        let folder = wf.folder.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { lines.append(cdCommand(folder)) }
        lines += wf.commands.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var delay = 0.7   // let the shell come up before the first line, then pace
        for line in lines {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.sendToSession(ref, text: line) }
            delay += 0.25
        }
    }

    /// A `cd` line for the folder. Leaves a leading `~` unquoted so the shell expands it;
    /// quotes everything else so a path with spaces survives.
    private func cdCommand(_ folder: String) -> String {
        if folder == "~" || folder.hasPrefix("~/") { return "cd " + folder }
        return "cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Type text into a session via the broker (tmux send-keys); appends Enter by default.
    func sendToSession(_ ref: SessionRef, text: String, enter: Bool = true) {
        guard let m = machines.first(where: { $0.id == ref.machineID }),
              let enc = ref.session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(m.httpBase)/send?session=\(enc)&enter=\(enter ? "1" : "0")") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.httpBody = text.data(using: .utf8); req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req).resume()
    }

    // MARK: Todo Maps — per-session checklists that outlive the session.

    /// Drives the ⇧⌘D Todo Maps panel.
    @Published var showTodos = false
    /// Boards keyed by <machine, session> plus one Misc board. Persisted with full item
    /// history (created/completed timestamps), so nothing is lost for later analysis.
    @Published var todoBoards: [TodoBoard] = AppState.loadTodoBoards() {
        didSet {
            guard persistenceEnabled else { return }
            AppState.saveTodoBoards(todoBoards)
            if !applyingRemoteTodos {           // a local edit → stamp + push to the sync host
                todosUpdatedAt = nowMs()
                pushUserData("todos", todoBoards, todosUpdatedAt,
                             allowDestructive: pendingDestructiveSync.contains("todos"))
            }
        }
    }

    private static func loadTodoBoards() -> [TodoBoard] {
        guard let d = UserDefaults.standard.data(forKey: "ut.todoBoards.v1") else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([TodoBoard].self, from: d)) ?? []
    }
    private static func saveTodoBoards(_ b: [TodoBoard]) {
        // ISO-8601 dates so the stored JSON is directly readable for later analysis.
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(b) { UserDefaults.standard.set(d, forKey: "ut.todoBoards.v1") }
    }

    /// Create a board for a (machine, session) if one doesn't exist yet (the session need
    /// not be running — a board can be set up for a future session).
    func ensureBoard(machine: String, session: String) {
        let m = machine.trimmingCharacters(in: .whitespaces)
        let s = session.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !todoBoards.contains(where: { !$0.isMisc && $0.machine == m && $0.session == s }) {
            todoBoards.append(TodoBoard(machine: m, session: s))
        }
    }
    func addTodo(_ boardID: UUID, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = todoBoards.firstIndex(where: { $0.id == boardID }) else { return }
        todoBoards[i].items.append(TodoItem(text: t))
        ActivityJournal.shared.log("todo", todoFields(todoBoards[i], action: "add", text: t))
    }
    func toggleTodo(_ boardID: UUID, _ itemID: UUID) {
        guard let bi = todoBoards.firstIndex(where: { $0.id == boardID }),
              let ii = todoBoards[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        todoBoards[bi].items[ii].done.toggle()
        todoBoards[bi].items[ii].completedAt = todoBoards[bi].items[ii].done ? Date() : nil
        ActivityJournal.shared.log("todo", todoFields(
            todoBoards[bi],
            action: todoBoards[bi].items[ii].done ? "done" : "undone",
            text: todoBoards[bi].items[ii].text))
    }
    private func todoFields(_ board: TodoBoard, action: String, text: String) -> [String: Any] {
        var f: [String: Any] = ["action": action, "text": text]
        if board.isMisc { f["board"] = "misc" }
        else { f["machineID"] = board.machine; f["session"] = board.session }
        return f
    }
    func deleteTodo(_ boardID: UUID, _ itemID: UUID) {
        guard let bi = todoBoards.firstIndex(where: { $0.id == boardID }),
              todoBoards[bi].items.contains(where: { $0.id == itemID }) else { return }
        markDestructiveSync("todos")
        todoBoards[bi].items.removeAll { $0.id == itemID }
    }
    func deleteBoard(_ boardID: UUID) {
        guard todoBoards.contains(where: { $0.id == boardID && !$0.isMisc }) else { return }
        markDestructiveSync("todos")
        todoBoards.removeAll { $0.id == boardID && !$0.isMisc }   // Misc is permanent
    }

    /// The online machine + session a board points at, if it is running right now.
    func liveMachine(for b: TodoBoard) -> Machine? {
        guard !b.isMisc else { return nil }
        return machines.first { m in
            let nameOK = m.name == b.machine
                || (m.isLocal && (b.machine.caseInsensitiveCompare("this mac") == .orderedSame
                                  || b.machine.caseInsensitiveCompare(ProcessInfo.processInfo.hostName) == .orderedSame))
            return nameOK && (sessionsByMachine[m.id] ?? []).contains { $0.name == b.session }
        }
    }
    func isSessionLive(_ b: TodoBoard) -> Bool { liveMachine(for: b) != nil }

    /// Jump to a board's session in the terminal (if it's running).
    func openBoardSession(_ b: TodoBoard) {
        guard let m = liveMachine(for: b) else { return }
        selection = SessionRef(machineID: m.id, session: b.session)
        showTodos = false
        showOverview = false
    }

    // MARK: Notes Hub — free-form, time-grouped notes (synced like todos/workflows).

    @Published var showNotes = false
    @Published var showLedger = false   // in-app Activity Ledger (⇧⌘J), a fleet-wide top-level view
    @Published var showArtifacts = false // local library of panel renders and screenshots
    // Argus Lab (⇧⌘L). UT_OPEN_LAB=1 opens it on launch — the hook the
    // screenshot-verification harness uses to capture the real pane.
    @Published var showLab = ProcessInfo.processInfo.environment["UT_OPEN_LAB"] == "1"
    @Published var notes: [Note] = AppState.loadNotes() {
        // Save locally + stamp on a local edit; the periodic reconcile pushes it (no POST
        // per keystroke). Adopting a remote copy sets applyingRemoteNotes to skip the stamp.
        didSet {
            guard persistenceEnabled else { return }
            AppState.saveNotes(notes)
            if !applyingRemoteNotes { notesUpdatedAt = nowMs() }
        }
    }
    private var applyingRemoteNotes = false
    private var notesUpdatedAt: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "ut.notes.updatedAt")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "ut.notes.updatedAt") }
    }
    private static func loadNotes() -> [Note] {
        guard let d = UserDefaults.standard.data(forKey: "ut.notes.v1") else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Note].self, from: d)) ?? []
    }
    private static func saveNotes(_ n: [Note]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(n) { UserDefaults.standard.set(d, forKey: "ut.notes.v1") }
    }

    @discardableResult
    func addNote() -> UUID {
        let n = Note()
        notes.append(n)
        ActivityJournal.shared.log("note", ["action": "add", "noteID": n.id.uuidString])
        return n.id
    }
    func updateNoteText(_ id: UUID, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].text = text
        notes[i].editedAt = Date()       // last edit drives time grouping/sort
    }
    func toggleNote(_ id: UUID) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].done.toggle()
    }
    func deleteNote(_ id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        markDestructiveSync("notes")
        notes.removeAll { $0.id == id }
    }

    // MARK: User-data sync (Workflows + Todo Maps) — this Mac IS the sync host.

    private var applyingRemoteWorkflows = false
    private var applyingRemoteTodos = false
    private var workflowsUpdatedAt: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "ut.workflows.updatedAt")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "ut.workflows.updatedAt") }
    }
    private var todosUpdatedAt: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "ut.todoBoards.updatedAt")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "ut.todoBoards.updatedAt") }
    }
    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private func markDestructiveSync(_ key: String) {
        pendingDestructiveSync.insert(key)
        if persistenceEnabled {
            UserDefaults.standard.set(Array(pendingDestructiveSync), forKey: "ut.pendingDestructiveSync")
        }
    }
    private func clearDestructiveSync(_ key: String) {
        guard pendingDestructiveSync.remove(key) != nil, persistenceEnabled else { return }
        UserDefaults.standard.set(Array(pendingDestructiveSync), forKey: "ut.pendingDestructiveSync")
    }
    /// The sync host is this Mac's own broker (loopback).
    private var syncHostBase: String? { machines.first { $0.isLocal }?.httpBase }

    /// Drain phone-captured journal events from the local broker's inbox into
    /// the canonical journal (peek → ingest (id-deduped) → ack by offset).
    func drainJournalInbox() {
        guard let base = syncHostBase, let url = URL(string: "\(base)/journal/peek") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let off = obj["off"] as? Int64 ?? (obj["off"] as? Int).map(Int64.init),
                  off > 0,
                  let lines = obj["data"] as? String, !lines.isEmpty else { return }
            DispatchQueue.main.async {
                _ = ActivityJournal.shared.ingest(lines)
                // Ack regardless of per-line validity: ids are recorded, replays dedupe.
                guard let ack = URL(string: "\(base)/journal/ack?off=\(off)") else { return }
                var areq = URLRequest(url: ack)
                areq.httpMethod = "POST"
                areq.timeoutInterval = 8
                URLSession.shared.dataTask(with: areq).resume()
            }
        }.resume()
    }

    private func pushUserData<T: Codable>(_ key: String, _ data: T, _ ts: Int64,
                                          allowDestructive: Bool = false) {
        guard persistenceEnabled, let base = syncHostBase,
              let url = URL(string: "\(base)/userdata?key=\(key)") else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let body = try? enc.encode(SyncEnvelope(updatedAt: ts, data: data,
                                                      allowDestructive: allowDestructive)) else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Reconcile both keys with the sync store: adopt the remote when it's newer, push the
    /// local copy up when it's newer (or to bootstrap pre-existing data). Runs on the poll
    /// timer + at launch.
    func syncUserData() {
        guard persistenceEnabled else { return }
        syncWorkflows()
        syncTodos()
        syncNotes()
    }

    private func syncWorkflows() {
        guard let base = syncHostBase, let url = URL(string: "\(base)/userdata?key=workflows") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var remoteTs: Int64 = 0; var remote: [Workflow]?
            if let data, let env = try? dec.decode(SyncEnvelope<[Workflow]>.self, from: data) {
                remoteTs = env.updatedAt; remote = env.data
            }
            DispatchQueue.main.async {
                var localTs = self.workflowsUpdatedAt
                if localTs == 0, !self.workflows.isEmpty { localTs = self.nowMs(); self.workflowsUpdatedAt = localTs }
                if remoteTs > localTs, let remote {
                    self.applyingRemoteWorkflows = true
                    self.workflows = remote
                    self.applyingRemoteWorkflows = false
                    self.workflowsUpdatedAt = remoteTs
                    self.clearDestructiveSync("workflows")
                } else if localTs > remoteTs {
                    self.pushUserData("workflows", self.workflows, localTs,
                                      allowDestructive: self.pendingDestructiveSync.contains("workflows"))
                } else if localTs != 0 {
                    self.clearDestructiveSync("workflows")
                }
            }
        }.resume()
    }

    private func syncTodos() {
        guard let base = syncHostBase, let url = URL(string: "\(base)/userdata?key=todos") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var remoteTs: Int64 = 0; var remote: [TodoBoard]?
            if let data, let env = try? dec.decode(SyncEnvelope<[TodoBoard]>.self, from: data) {
                remoteTs = env.updatedAt; remote = env.data
            }
            DispatchQueue.main.async {
                let hasData = self.todoBoards.contains { !$0.isMisc || !$0.items.isEmpty }
                var localTs = self.todosUpdatedAt
                if localTs == 0, hasData { localTs = self.nowMs(); self.todosUpdatedAt = localTs }
                if remoteTs > localTs, var remote {
                    if !remote.contains(where: { $0.isMisc }) { remote.append(TodoBoard(isMisc: true)) }
                    self.applyingRemoteTodos = true
                    self.todoBoards = remote
                    self.applyingRemoteTodos = false
                    self.todosUpdatedAt = remoteTs
                    self.clearDestructiveSync("todos")
                } else if localTs > remoteTs {
                    self.pushUserData("todos", self.todoBoards, localTs,
                                      allowDestructive: self.pendingDestructiveSync.contains("todos"))
                } else if localTs != 0 {
                    self.clearDestructiveSync("todos")
                }
            }
        }.resume()
    }

    private func syncNotes() {
        guard let base = syncHostBase, let url = URL(string: "\(base)/userdata?key=notes") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            var remoteTs: Int64 = 0; var remote: [Note]?
            if let data, let env = try? dec.decode(SyncEnvelope<[Note]>.self, from: data) {
                remoteTs = env.updatedAt; remote = env.data
            }
            DispatchQueue.main.async {
                var localTs = self.notesUpdatedAt
                if localTs == 0, !self.notes.isEmpty { localTs = self.nowMs(); self.notesUpdatedAt = localTs }
                if remoteTs > localTs, let remote {
                    self.applyingRemoteNotes = true
                    self.notes = remote
                    self.applyingRemoteNotes = false
                    self.notesUpdatedAt = remoteTs
                    self.clearDestructiveSync("notes")
                } else if localTs > remoteTs {
                    self.pushUserData("notes", self.notes, localTs,
                                      allowDestructive: self.pendingDestructiveSync.contains("notes"))
                } else if localTs != 0 {
                    self.clearDestructiveSync("notes")
                }
            }
        }.resume()
    }

    /// Sessions the user has HIDDEN from the sidebar. BROKER-OWNED now (so the hide SYNCS
    /// across devices): each refresh rebuilds this machine's membership from the `hidden`
    /// flag on /sessions, and hide/unhide POSTs to the owning broker. Keyed by SessionRef.id.
    /// Seeded from the old local set for an immediate (no-flicker) hide; that legacy set is
    /// migrated to the brokers once on first sight, then dropped.
    @Published var hiddenSessions: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ut.hiddenSessions") ?? [])
    private var legacyHiddenToMigrate: [String] = UserDefaults.standard.stringArray(forKey: "ut.hiddenSessions") ?? []
    /// Drives the ⇧⌘B "Hidden Panels" restore sheet.
    @Published var showHiddenPicker = false
    /// Drives the ⇧⌘Y "Session History" sheet + its (durable, locally-cached) contents.
    @Published var showHistory = false
    @Published var historyItems: [SessionHistoryItem] = []
    @Published var historyLoading = false
    private let historyStoreKey = "ut.historyCache.v1"
    private let historyTTLDays = 90
    /// Durable local union of every history record this client has ever fetched, keyed by
    /// SessionHistoryItem.id (node/name/first). Persisted, so a machine's history survives
    /// the machine going offline — which is the whole point of history. A background task
    /// keeps it fresh from whatever brokers are online; the view reads THIS, never the
    /// live brokers, so nothing vanishes when a machine steps away.
    private var historyCache: [String: SessionHistoryItem] = [:]
    /// Nodes that answered /history in the most recent refresh — gates the "alive" dot so
    /// an offline machine's cached sessions don't keep showing as still-running.
    private var historyOnlineNodes: Set<String> = []
    /// Drives the ⇧⌘T theme picker sheet.
    @Published var showThemePicker = false

    func isHidden(_ ref: SessionRef) -> Bool { hiddenSessions.contains(ref.id) }

    /// Sessions the user has "ticked" to set aside in the command center — they drop
    /// out of the attention bands into a separate Backlog group (still visible, unlike
    /// a full hide). Persisted, keyed by SessionRef.id.
    @Published var backlog: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "ut.backlog") ?? []) {
        didSet { UserDefaults.standard.set(Array(backlog), forKey: "ut.backlog") }
    }
    func isBacklogged(_ ref: SessionRef) -> Bool { backlog.contains(ref.id) }
    func toggleBacklog(_ ref: SessionRef) {
        if backlog.contains(ref.id) { backlog.remove(ref.id) } else { backlog.insert(ref.id) }
    }

    /// Hide a session from the sidebar. If it was selected, move selection to the
    /// first still-visible session so the detail pane never shows a hidden panel.
    func hide(_ ref: SessionRef) {
        hiddenSessions.insert(ref.id)            // optimistic; the next refresh confirms from the broker
        setHiddenOnBroker(ref, hidden: true)
        if selection == ref { selection = firstVisibleSession() }
    }
    func unhide(_ ref: SessionRef) {
        hiddenSessions.remove(ref.id)
        setHiddenOnBroker(ref, hidden: false)
    }

    /// Toggle a session's hidden flag on its owning broker (the synced source of truth).
    private func setHiddenOnBroker(_ ref: SessionRef, hidden: Bool) {
        guard let m = machines.first(where: { $0.id == ref.machineID }),
              let enc = ref.session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(m.httpBase)/hidden?session=\(enc)&hidden=\(hidden)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Reconcile this machine's hidden membership with the broker's `hidden` flags (the
    /// synced truth), and migrate any legacy local hides to the broker once.
    private func syncHidden(machine m: Machine, sessions list: [SessionInfo]) {
        let mPrefix = m.id + "/"
        let legacyForM = legacyHiddenToMigrate.filter { $0.hasPrefix(mPrefix) }
        for id in legacyForM {                        // one-time: push old local hides up
            let name = String(id.dropFirst(mPrefix.count))
            if !list.contains(where: { $0.name == name && $0.hidden }) {
                setHiddenOnBroker(SessionRef(machineID: m.id, session: name), hidden: true)
            }
        }
        if !legacyForM.isEmpty {
            legacyHiddenToMigrate.removeAll { $0.hasPrefix(mPrefix) }
            if legacyHiddenToMigrate.isEmpty { UserDefaults.standard.removeObject(forKey: "ut.hiddenSessions") }
        }
        var nh = hiddenSessions.filter { !$0.hasPrefix(mPrefix) }   // drop this machine's old entries
        for s in list where s.hidden { nh.insert(SessionRef(machineID: m.id, session: s.name).id) }
        for id in legacyForM { nh.insert(id) }                      // keep just-migrated hidden until the broker confirms
        if nh != hiddenSessions { hiddenSessions = nh }
    }

    /// Hidden sessions that STILL EXIST, with machine label — drives the restore picker.
    var hiddenSessionList: [HiddenPanel] {
        machines.flatMap { m -> [HiddenPanel] in
            (sessionsByMachine[m.id] ?? []).compactMap { s in
                let r = SessionRef(machineID: m.id, session: s.name)
                return hiddenSessions.contains(r.id) ? HiddenPanel(ref: r, machineName: m.name, info: s) : nil
            }
        }
    }

    /// First session visible in the sidebar (not hidden, agent-toggle honored) — used
    /// to re-select after hiding the current one.
    private func firstVisibleSession() -> SessionRef? {
        for m in machines {
            for s in (sessionsByMachine[m.id] ?? []) {
                let r = SessionRef(machineID: m.id, session: s.name)
                if !hiddenSessions.contains(r.id), showAgentSessions || !s.agent { return r }
            }
        }
        return nil
    }

    /// All sessions flattened across machines (for the command palette). Honors the
    /// agent-visibility toggle and hidden set so neither surfaces in ⌘P.
    var allSessions: [SessionRef] {
        machines.flatMap { m in
            (sessionsByMachine[m.id] ?? [])
                .filter { (showAgentSessions || !$0.agent) && !hiddenSessions.contains(SessionRef(machineID: m.id, session: $0.name).id) }
                .map { SessionRef(machineID: m.id, session: $0.name) }
        }
    }

    /// The machine that owns a session ref (for routing a terminal path-click to
    /// the right host's Files/broker).
    func machine(for ref: SessionRef) -> Machine? { machines.first { $0.id == ref.machineID } }

    /// The session info (incl. its cwd in `.path`) for a ref.
    func session(for ref: SessionRef) -> SessionInfo? {
        (sessionsByMachine[ref.machineID] ?? []).first { $0.name == ref.session }
    }

    /// Snapshot the selected panel for artifact attribution.  This is called
    /// when Render opens, not when PDF generation finishes, so refreshes and
    /// renames cannot move a capture to a different panel.
    func artifactContext(for ref: SessionRef) -> ArtifactPanelContext? {
        guard let machine = machine(for: ref) else { return nil }
        let info = session(for: ref)
        return ArtifactPanelContext(
            machineID: machine.id,
            machineName: machine.name,
            machineHost: machine.host,
            sessionName: ref.session,
            stableSessionID: info?.tmuxID,
            folder: resolveBase(for: ref)
        )
    }

    /// Resolve an archived panel identity back to the current live name. tmux's
    /// stable id makes this continue to work after a rename.
    func liveRef(for panel: ArtifactPanelContext) -> SessionRef? {
        guard machines.contains(where: { $0.id == panel.machineID }) else { return nil }
        let sessions = sessionsByMachine[panel.machineID] ?? []
        let live: SessionInfo?
        if let stable = panel.stableSessionID, !stable.isEmpty {
            live = sessions.first { $0.tmuxID == stable }
        } else {
            live = sessions.first { $0.name == panel.sessionName }
        }
        return live.map { SessionRef(machineID: panel.machineID, session: $0.name) }
    }

    /// Present the Artifact library as the one active top-level surface.
    func presentArtifacts() {
        showArtifacts = true
        showOverview = false
        showTodos = false
        showNotes = false
        showLedger = false
        showLab = false
    }

    /// The user's pinned working dir for a session, if set (nil/blank → not pinned).
    func pathOverride(for ref: SessionRef) -> String? {
        let v = pathOverrides[ref.id]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }

    /// Pin (non-blank) or unpin (blank) a session's working dir; persisted immediately.
    func setPathOverride(_ path: String?, for ref: SessionRef) {
        let v = (path ?? "").trimmingCharacters(in: .whitespaces)
        if v.isEmpty { pathOverrides.removeValue(forKey: ref.id) } else { pathOverrides[ref.id] = v }
        UserDefaults.standard.set(pathOverrides, forKey: "ut.pathOverrides")
    }

    /// The directory a terminal cmd+click resolves against: the user's pin if set,
    /// else the broker's reported session cwd.
    func resolveBase(for ref: SessionRef) -> String {
        pathOverride(for: ref) ?? session(for: ref)?.path ?? ""
    }

    /// Every session across ALL machines whose broker state == "waiting"
    /// (blocked on the user), paired with its machine's display name and sorted
    /// most-recently-active first. Drives the pinned "Needs attention" inbox.
    var waitingSessions: [WaitingSession] {
        machines.flatMap { m -> [WaitingSession] in
            (sessionsByMachine[m.id] ?? []).filter { $0.isWaiting && (showAgentSessions || !$0.agent) && !hiddenSessions.contains(SessionRef(machineID: m.id, session: $0.name).id) }.compactMap { s in
                let ref = SessionRef(machineID: m.id, session: s.name)
                if acknowledged.contains(ref.id) { return nil } // user already saw/answered it
                return WaitingSession(ref: ref, machineName: m.name, activity: s.activity)
            }
        }
        .sorted { $0.activity > $1.activity }
    }

    /// Sessions the user has viewed or answered while waiting — suppressed from the
    /// inbox/badge until the broker reports them leaving "waiting" (which re-arms them
    /// for the next genuine prompt). Published so the inbox/badge recompute on change.
    @Published private var acknowledged: Set<String> = []

    private func isWaiting(_ ref: SessionRef) -> Bool {
        (sessionsByMachine[ref.machineID] ?? []).first { $0.name == ref.session }?.isWaiting ?? false
    }

    /// Mark a session acknowledged and push the new waiting total to the Dock badge
    /// immediately (the badge was previously only updated on the periodic poll).
    private func acknowledge(_ ref: SessionRef) {
        if !acknowledged.contains(ref.id) { acknowledged.insert(ref.id) }
        AttentionNotifier.shared.update(enteredWaiting: [], totalWaiting: waitingCount)
    }

    /// Count of sessions currently waiting on the user (for the header badge).
    var waitingCount: Int { waitingSessions.count }

    private var pollTimer: Timer?
    private var prevState: [String: String] = [:]  // ref.id -> last agent state (for waiting-transition notifications)
    /// ref.ids whose agent just finished a turn (working → idle) while NOT the active
    /// selection — rendered as an ORANGE "done, unseen" dot until you open the pane.
    @Published var unseen: Set<String> = []

    init(isolatedForTesting: Bool = false) {
        let isolated = isolatedForTesting || Self.isRunningTests
        persistenceEnabled = !isolated
        // Local (loopback) is fixed; cluster brokers are discovered from the tailnet.
        machines = [
            Machine(id: "local", name: "this mac", isLocal: true,
                    httpBase: "http://127.0.0.1:8722", wsBase: "ws://127.0.0.1:8722"),
        ]
        selection = SessionRef(machineID: "local", session: "ut-demo")
        loadHistoryCache()
        if !isolated {
            applyKeepAwake()   // honor a persisted "keep awake" across relaunches
            if !todoBoards.contains(where: { $0.isMisc }) { todoBoards.append(TodoBoard(isMisc: true)) }
        }
        // Activity journal: resolve machine names / session cwds at event time.
        if !isolated {
            ActivityJournal.shared.nameResolver = { [weak self] id in
                self?.machines.first(where: { $0.id == id })?.name
            }
            ActivityJournal.shared.folderResolver = { [weak self] mid, session in
                self?.sessionsByMachine[mid]?.first(where: { $0.name == session })?.path
            }
        }
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columns = (columns == .detailOnly) ? .all : .detailOnly
        }
    }

    func focusSearch() { searchFocusToken &+= 1 }

    /// Light periodic poll: re-fetch foreground sessions for known machines. Every
    /// 30s it takes a full hidden/agent snapshot; every ~12s it ALSO re-discovers,
    /// so a broker that comes online after launch (e.g. a Babel job landing on a
    /// fresh node) appears on its own instead of only on a manual refresh.
    func startAutoRefresh() {
        pollTimer?.invalidate()
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                tick += 1
                let scope: SessionRefreshScope = tick % 15 == 0 ? .all : .foreground
                for m in self.machines { self.refresh(m, scope: scope) }
                if tick % 6 == 0 { self.discoverNewBrokers() }
                // Pull durable history in the background while machines are reachable, so
                // it's captured before a node goes offline. ~2s after launch, then ~30s.
                if tick == 1 || tick % 15 == 0 { self.refreshHistoryCache() }
                // Sync Workflows + Todo Maps with this Mac's broker (the sync host) so the
                // phone shares them. ~4s after launch, then ~10s.
                if tick == 2 || tick % 5 == 0 { self.syncUserData(); self.drainJournalInbox() }
            }
        }
    }

    /// Pick up brokers that came online AFTER launch — MERGE only (never drops an
    /// existing machine on a transient probe miss; a full re-discovery still runs on
    /// manual refresh, which also prunes dead ones).
    func discoverNewBrokers() {
        DispatchQueue.global(qos: .utility).async {
            let found = discoverMachines()
            DispatchQueue.main.async {
                for m in found where !self.machines.contains(where: { $0.id == m.id }) {
                    self.machines.append(m)
                    self.refresh(m, scope: .all)
                }
            }
        }
    }

    /// Discover ut-* brokers on the tailnet, then refresh every machine's sessions.
    func refreshAll() {
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = discoverMachines()
            DispatchQueue.main.async {
                self.machines = found
                let group = DispatchGroup()
                for m in found { self.refresh(m, group: group, scope: .all, coalesce: false) }
                group.notify(queue: .main) { self.isRefreshing = false }
                // Safety: never leave the spinner stuck if a request hangs past timeout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.isRefreshing = false }
            }
        }
    }

    /// Open-the-view entry (⇧⌘Y / the refresh button): show the durable cache instantly —
    /// so an offline machine's history is right there — then fold in anything new from the
    /// brokers that are currently online.
    func loadHistory() {
        historyLoading = true
        rebuildHistoryItems()        // instant: the union of everything ever seen
        refreshHistoryCache()        // then merge fresh records from online brokers
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.historyLoading = false }
    }

    /// Fetch durable history from every ONLINE broker and fold it into the persistent
    /// local cache. Runs in the background off the poll timer (and when the view opens),
    /// so each machine's history is captured while it's reachable and kept after it leaves.
    /// Each broker owns its own node's history, so this is the union across nodes.
    func refreshHistoryCache() {
        let mlist = machines
        guard !mlist.isEmpty else { return }
        let group = DispatchGroup()
        var collected: [SessionHistoryItem] = []
        var responded: Set<String> = []
        let lock = NSLock()
        for m in mlist {
            guard let url = URL(string: m.httpBase + "/history") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            group.enter()
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { group.leave() }
                guard let data,
                      let decoded = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) else { return }
                lock.lock()
                collected.append(contentsOf: decoded.sessions)
                for s in decoded.sessions { responded.insert(s.node) }
                lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            self.mergeHistory(collected, respondedNodes: responded)
            self.historyLoading = false
        }
    }

    /// Union-merge fetched records into the durable cache. A broker's record for a given
    /// id only ever grows (folders accrue, lastSeen ticks), so a fresh fetch supersedes the
    /// cached copy. Prune by the 90-day TTL, persist, and rebuild the view list.
    private func mergeHistory(_ fetched: [SessionHistoryItem], respondedNodes: Set<String>) {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(historyTTLDays) * 24 * 3600
        for item in fetched where item.last >= cutoff {
            historyCache[item.id] = item
        }
        for (k, v) in historyCache where v.last < cutoff { historyCache.removeValue(forKey: k) }
        historyOnlineNodes = respondedNodes
        saveHistoryCache()
        rebuildHistoryItems()
    }

    /// Rebuild the published, sorted view list from the durable cache, gating each item's
    /// "alive" flag by whether its node answered the latest refresh — so a cached session
    /// on an offline machine isn't shown as still-running.
    private func rebuildHistoryItems() {
        let online = historyOnlineNodes
        historyItems = historyCache.values
            .map { var it = $0; it.alive = it.alive && online.contains(it.node); return it }
            .sorted { $0.last > $1.last }
    }

    private func loadHistoryCache() {
        if let data = UserDefaults.standard.data(forKey: historyStoreKey),
           let items = try? JSONDecoder().decode([SessionHistoryItem].self, from: data) {
            let cutoff = Int64(Date().timeIntervalSince1970) - Int64(historyTTLDays) * 24 * 3600
            for it in items where it.last >= cutoff { historyCache[it.id] = it }
        }
        rebuildHistoryItems()
    }

    private func saveHistoryCache() {
        if let data = try? JSONEncoder().encode(Array(historyCache.values)) {
            UserDefaults.standard.set(data, forKey: historyStoreKey)
        }
    }

    /// The online machine a history `node` refers to, whether or not the session is still
    /// running — so a row stays actionable as long as its MACHINE is up. `node` is the
    /// broker's `os.Hostname()`: for a remote broker that equals its `/whoami` name and thus
    /// `Machine.name`, so match on that. The local Machine carries the friendly "this mac",
    /// so match it by hostname — case-insensitively, since ProcessInfo lowercases it while
    /// the broker keeps the original case. Returns nil when that machine is offline.
    func machineForNode(_ node: String) -> Machine? {
        machines.first { $0.name == node }
            // /history records `node` as the broker's OS hostname, which can differ from the
            // display name (--name) — e.g. Windows: name=pranjala-win, host=DESKTOP-EFJI6J4.
            // Match the hostname reported by /whoami so those history rows stay restorable.
            ?? machines.first { !$0.host.isEmpty && $0.host.caseInsensitiveCompare(node) == .orderedSame }
            ?? machines.first { $0.isLocal && node.caseInsensitiveCompare(ProcessInfo.processInfo.hostName) == .orderedSame }
    }

    /// Act on a history row. If the session is still running, select it. If it ended but its
    /// machine is up, RE-CREATE it (same name, in the folder it last ran in) and open that —
    /// so clicking a dead row brings the session back. No-op if the machine is offline. The
    /// select-vs-recreate choice reads the LIVE session list, so it's right even if the row's
    /// cached `alive` flag is momentarily stale.
    func openHistoryItem(_ item: SessionHistoryItem) {
        guard let m = machineForNode(item.node) else { return }
        if (sessionsByMachine[m.id] ?? []).contains(where: { $0.name == item.name }) {
            selection = SessionRef(machineID: m.id, session: item.name)
        } else {
            createSession(on: m.id, name: item.name, dir: item.folders.last?.path)
        }
        showHistory = false
        showOverview = false
        showArtifacts = false
    }

    func refresh(
        _ m: Machine,
        group: DispatchGroup? = nil,
        scope: SessionRefreshScope = .foreground,
        coalesce: Bool = true
    ) {
        var components = URLComponents(string: m.httpBase + "/sessions")
        if scope == .foreground {
            components?.queryItems = [URLQueryItem(name: "scope", value: "foreground")]
        }
        guard let url = components?.url else { return }
        if coalesce, sessionRefreshesInFlight[m.id, default: 0] > 0 {
            // Never stack periodic requests behind a slow/offline broker. Preserve a
            // skipped full refresh and run it as soon as the active request finishes.
            if scope == .all { pendingFullSessionRefresh[m.id] = m }
            return
        }
        sessionRefreshesInFlight[m.id, default: 0] += 1
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let started = Date()
        group?.enter()
        URLSession.shared.dataTask(with: req) { data, response, err in
            let httpOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let decoded = data.flatMap { try? JSONDecoder().decode(SessionsResponse.self, from: $0) }
            let reachable = err == nil && httpOK && decoded != nil
            let status = reachable ? "reachable" : "unreachable"
            let rtt = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                if self.statusByMachine[m.id] != status {
                    self.statusByMachine[m.id] = status
                }

                if reachable {
                    let now = Date()
                    let lastRTT = self.lastRTTPublishedAt[m.id] ?? .distantPast
                    if self.rttByMachine[m.id] == nil || now.timeIntervalSince(lastRTT) >= 30 {
                        let roundedRTT = max(0, Int((Double(rtt) / 5).rounded()) * 5)
                        if self.rttByMachine[m.id] != roundedRTT {
                            self.rttByMachine[m.id] = roundedRTT
                        }
                        self.lastRTTPublishedAt[m.id] = now
                    }
                }

                if reachable, let fetched = decoded?.sessions {
                    let current = self.sessionsByMachine[m.id] ?? []
                    let merged = mergeSessionSnapshot(
                        current: current,
                        fetched: fetched,
                        scope: scope,
                        machineID: m.id,
                        locallyHidden: self.hiddenSessions
                    )
                    let sessionsChanged = current != merged
                    if sessionsChanged {
                        self.sessionsByMachine[m.id] = merged
                    }
                    if scope == .all {
                        self.syncHidden(machine: m, sessions: fetched)
                    }
                    if sessionsChanged {
                        self.applySessionTransitions(
                            machine: m,
                            changedSessions: fetched,
                            liveSessions: merged
                        )
                    }
                }
                self.finishSessionRefresh(machineID: m.id)
                group?.leave()
            }
        }.resume()
    }

    private func finishSessionRefresh(machineID: String) {
        let remaining = max(0, sessionRefreshesInFlight[machineID, default: 1] - 1)
        if remaining > 0 {
            sessionRefreshesInFlight[machineID] = remaining
            return
        }
        sessionRefreshesInFlight.removeValue(forKey: machineID)
        guard let machine = pendingFullSessionRefresh.removeValue(forKey: machineID),
              machines.contains(where: { $0.id == machineID }) else { return }
        refresh(machine, scope: .all)
    }

    /// Fold one changed broker snapshot into notification state using local copies,
    /// then publish each set at most once. The previous implementation mutated two
    /// @Published sets for nearly every session on every poll, even when nothing changed.
    private func applySessionTransitions(
        machine m: Machine,
        changedSessions: [SessionInfo],
        liveSessions: [SessionInfo]
    ) {
        var nextAcknowledged = acknowledged
        var nextUnseen = unseen
        var entered: [(ref: SessionRef, machine: String)] = []
        var becameIdle: Set<String> = []

        for s in changedSessions {
            let ref = SessionRef(machineID: m.id, session: s.name)
            let prev = prevState[ref.id]
            let hidden = s.hidden || hiddenSessions.contains(ref.id)
            let userFacing = !s.agent && !hidden

            if userFacing && s.state == "working" {
                nextUnseen.remove(ref.id)
            } else if userFacing && prev == "working" && s.state != "waiting" && selection != ref {
                nextUnseen.insert(ref.id)
            }
            if userFacing && s.state == "waiting" && (prev ?? "idle") != "waiting" {
                entered.append((ref: ref, machine: m.name))
            }
            if isVisibleWorkingToIdleTransition(
                previous: prev,
                current: s.state,
                isAgentSession: s.agent,
                isHidden: hidden,
                isBacklogged: backlog.contains(ref.id)
            ) {
                becameIdle.insert(ref.id)
            }
            if s.state != "waiting" { nextAcknowledged.remove(ref.id) }
            prevState[ref.id] = s.state
        }

        let live = Set(liveSessions.map { SessionRef(machineID: m.id, session: $0.name).id })
        let onThisMachine: (String) -> Bool = { $0.hasPrefix(m.id + "/") }
        prevState = prevState.filter { !onThisMachine($0.key) || live.contains($0.key) }
        nextAcknowledged = nextAcknowledged.filter { !onThisMachine($0) || live.contains($0) }
        nextUnseen = nextUnseen.filter { !onThisMachine($0) || live.contains($0) }

        if nextAcknowledged != acknowledged { acknowledged = nextAcknowledged }
        if nextUnseen != unseen { unseen = nextUnseen }
        AttentionNotifier.shared.update(enteredWaiting: entered, totalWaiting: waitingCount)
        if !becameIdle.isEmpty { AttentionNotifier.shared.workingBecameIdle(ids: becameIdle) }
    }

    // MARK: Session control (POST /control on the owning broker)

    func createSession(on machineID: String, name: String, dir: String? = nil) {
        var jf: [String: Any] = ["machineID": machineID, "session": name]
        if let dir, !dir.isEmpty { jf["folder"] = dir }
        ActivityJournal.shared.log("sessionNew", jf)
        var extra: [String: String] = [:]
        if let dir, !dir.isEmpty { extra["dir"] = dir }
        control(machineID, action: "create", session: name, extra: extra) { ok in
            if ok {
                self.selection = SessionRef(machineID: machineID, session: name)
                self.showOverview = false
                self.showArtifacts = false
            }
            self.refreshAll()
        }
    }

    func killSession(_ ref: SessionRef) {
        ActivityJournal.shared.log("sessionKill", ActivityJournal.shared.ctx(ref))
        control(ref.machineID, action: "kill", session: ref.session) { _ in
            // Selection was already moved off the dead session by the caller (before its
            // pane was dropped, so it isn't recreated). Just reconverge with the broker.
            self.refreshAll()
        }
    }

    /// Pick a sensible session to select after `ref` is killed: another on the
    /// same machine, else the first session on any reachable machine, else nil.
    func neighborSession(excluding ref: SessionRef) -> SessionRef? {
        let same = (sessionsByMachine[ref.machineID] ?? []).filter { $0.name != ref.session }
        if let s = same.first { return SessionRef(machineID: ref.machineID, session: s.name) }
        for m in machines where m.id != ref.machineID {
            if let s = (sessionsByMachine[m.id] ?? []).first {
                return SessionRef(machineID: m.id, session: s.name)
            }
        }
        return nil
    }

    func renameSession(_ ref: SessionRef, to newName: String, onResult: @escaping (Bool) -> Void = { _ in }) {
        let to = newName.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty, to != ref.session else { return }
        control(ref.machineID, action: "rename", session: ref.session, extra: ["to": to]) { ok in
            if ok, var list = self.sessionsByMachine[ref.machineID],
               let i = list.firstIndex(where: { $0.name == ref.session }) {
                // Optimistic: rename in the local list so the sidebar shows the new name
                // instantly (refreshAll reconciles a moment later).
                list[i].name = to
                self.sessionsByMachine[ref.machineID] = list
            }
            onResult(ok)
            self.refreshAll()
        }
    }

    private func control(_ machineID: String, action: String, session: String,
                         extra: [String: String] = [:], then: @escaping (Bool) -> Void) {
        guard let m = machines.first(where: { $0.id == machineID }),
              var comps = URLComponents(string: m.httpBase + "/control") else { return }
        var items = [URLQueryItem(name: "action", value: action),
                     URLQueryItem(name: "session", value: session)]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, resp, err in
            // Real success check: transport ok, 2xx, and the broker's {"ok":true}
            // (older brokers may omit the body — treat 2xx as success then).
            let http = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var ok = err == nil && (200..<300).contains(http)
            if ok, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let flag = obj["ok"] as? Bool { ok = flag }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { then(ok) }
        }.resume()
    }

    /// Sessions for a machine grouped by folder, folders sorted. An optional
    /// `query` filters by a case-insensitive substring of the name or path.
    func folderGroups(for machineID: String, matching query: String = "") -> [FolderGroup] {
        var sessions = sessionsByMachine[machineID] ?? []
        if !showAgentSessions { // agent (ut spawn) sessions are background work — hidden unless toggled on
            sessions = sessions.filter { !$0.agent }
        }
        if !hiddenSessions.isEmpty { // user-hidden panels (⇧⌘B to restore)
            sessions = sessions.filter { !hiddenSessions.contains(SessionRef(machineID: machineID, session: $0.name).id) }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            sessions = sessions.filter {
                $0.name.lowercased().contains(q) || ($0.path ?? "").lowercased().contains(q)
            }
        }
        let grouped = Dictionary(grouping: sessions) { ($0.path ?? "").isEmpty ? "—" : $0.path! }
        return grouped.keys.sorted().map { key in
            FolderGroup(folder: key, sessions: (grouped[key] ?? []).sorted { $0.name < $1.name })
        }
    }

    /// Friendly folder label: ~-relative for the local home, else a short tail.
    func folderDisplay(_ path: String, isLocal: Bool) -> String {
        if path == "—" { return "(no folder)" }
        if isLocal {
            let home = NSHomeDirectory()
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    func wsURL(for ref: SessionRef) -> URL? {
        guard let m = machines.first(where: { $0.id == ref.machineID }) else { return nil }
        // Connect by the STABLE tmux id ($N) when the broker reports one: it never
        // changes across a rename, so the auto-reconnecting socket survives a rename
        // even across a broker/app restart (the broker resolves the id to the current
        // name). Fall back to the name for older brokers that don't send an id.
        let handle = session(for: ref)?.tmuxID ?? ref.session
        let enc = handle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? handle
        return URL(string: m.wsBase + "/ws?session=" + enc)
    }
}

/// Compact relative time ("now", "5m", "2h", "3d", "2w") from a unix timestamp.
/// Used for the session row's trailing activity column.
func relativeShort(_ unixSeconds: Int64) -> String {
    guard unixSeconds > 0 else { return "" }
    let delta = Int(Date().timeIntervalSince1970) - Int(unixSeconds)
    switch delta {
    case ..<5:        return "now"
    case ..<60:       return "\(delta)s"
    case ..<3600:     return "\(delta / 60)m"
    case ..<86400:    return "\(delta / 3600)h"
    case ..<604800:   return "\(delta / 86400)d"
    default:          return "\(delta / 604800)w"
    }
}

/// Reads the local tailnet (`tailscale status --json`) and returns the local
/// broker plus every discovered `ut-*` broker. Spawns a process, so call off
/// the main thread.
func discoverMachines() -> [Machine] {
    var machines = [
        Machine(id: "local", name: "this mac", isLocal: true,
                httpBase: "http://127.0.0.1:8722", wsBase: "ws://127.0.0.1:8722"),
    ]
    let candidates = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]
    guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return machines
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: bin)
    task.arguments = ["status", "--json"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()
    do { try task.run() } catch { return machines }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return machines }

    // Capability-based discovery: probe every ONLINE peer's :8722 for the broker
    // identity handshake and accept only those that return it. No hostname or tag
    // matching, so it works for cluster nodes, other Macs, and Windows with no
    // renaming. `Self` is skipped — it is the hardcoded "local" entry above.
    var peers: [[String: Any]] = []
    if let p = json["Peer"] as? [String: [String: Any]] { peers.append(contentsOf: p.values) }

    var dnsNames: [String] = []
    var seen = Set<String>()
    for peer in peers {
        guard (peer["Online"] as? Bool) == true else { continue }
        var dns = (peer["DNSName"] as? String) ?? (peer["HostName"] as? String) ?? ""
        if dns.hasSuffix(".") { dns.removeLast() }
        guard !dns.isEmpty, !seen.contains(dns) else { continue }
        seen.insert(dns)
        dnsNames.append(dns)
    }

    let lock = NSLock()
    var found: [Machine] = []
    DispatchQueue.concurrentPerform(iterations: dnsNames.count) { i in
        let dns = dnsNames[i]
        guard let probe = probeBroker(dns: dns) else { return }
        // Use the scheme that actually answered: tsnet brokers serve real TLS
        // (https/wss), but a broker on a host's own tailnet IP (e.g. Windows via
        // the Tailscale app) serves plain http/ws. Hardcoding https made those
        // brokers discoverable but their /sessions + /ws unreachable.
        let ws = probe.scheme == "https" ? "wss" : "ws"
        let m = Machine(id: dns, name: probe.name, host: probe.host, os: probe.os, isLocal: false,
                        httpBase: "\(probe.scheme)://\(dns):8722", wsBase: "\(ws)://\(dns):8722")
        lock.lock(); found.append(m); lock.unlock()
    }
    machines.append(contentsOf: found.sorted { $0.name < $1.name })
    return machines
}

/// Probe one tailnet peer for the universal_tmux broker handshake, returning its
/// display name iff `:8722/whoami` returns our marker — so an unrelated service on
/// that port is never treated as a broker. Tries HTTPS (tsnet brokers serve a real
/// `*.ts.net` cert) then plain HTTP (a broker bound to a host's own tailnet IP).
private func probeBroker(dns: String) -> (name: String, host: String, os: String, scheme: String)? {
    for scheme in ["https", "http"] {
        if let r = probeWhoami("\(scheme)://\(dns):8722/whoami") { return (r.name, r.host, r.os, scheme) }
    }
    return nil
}

private func probeWhoami(_ urlString: String) -> (name: String, host: String, os: String)? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2.5
    let sem = DispatchSemaphore(value: 0)
    var result: (name: String, host: String, os: String)?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        guard err == nil, let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["service"] as? String == "universal-tmux-broker" else { return }
        let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "broker"
        let host = (obj["host"] as? String) ?? ""  // older brokers omit it; host-match just won't fire
        let os = (obj["os"] as? String) ?? ""      // older brokers: server-side path repair still applies
        result = (name, host, os)
    }.resume()
    _ = sem.wait(timeout: .now() + 3)
    return result
}
