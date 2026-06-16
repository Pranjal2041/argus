import SwiftUI
import Foundation

// MARK: - Status model

/// A status for one agent session, produced by the status updater (claude -p).
/// This is the inferred layer that sits on top of the deterministic dot.
struct AgentStatus: Equatable, Codable {
    var label: String        // model token: working/needs-decision/look/milestone/stuck/drifting/no-progress/idle
    var oneLiner: String     // short plain description of what the agent is doing
    var lookAtThis: String?  // a line worth seeing now, quoted verbatim — or nil
    var updatedAt: Date

    /// SF Symbol for a label (unknown → neutral dot).
    var glyph: String {
        switch label {
        case "needs-decision": return "questionmark.circle.fill"
        case "look":           return "eye.fill"
        case "milestone":      return "checkmark.seal.fill"
        case "stuck":          return "exclamationmark.triangle.fill"
        case "drifting":       return "arrow.triangle.branch"
        case "no-progress":    return "hourglass"
        case "working":        return "gearshape.fill"
        default:               return "circle"
        }
    }

    /// Human label for the chip.
    var display: String {
        switch label {
        case "needs-decision": return "needs you"
        case "look":           return "worth a look"
        case "milestone":      return "milestone"
        case "stuck":          return "stuck"
        case "drifting":       return "drifting"
        case "no-progress":    return "no progress"
        case "working":        return "working"
        case "idle":           return "idle"
        default:               return label
        }
    }
}

// MARK: - Provider (swappable: claude -p now, Messages API later)

protocol AgentStatusProvider {
    /// Produce a status for `key` from its recent terminal `output`. nil on failure.
    func status(forKey key: String, output: String) async -> AgentStatus?
    /// Forget a session's conversation continuity (session ended).
    func forget(key: String)
    /// Cumulative spend (USD) + number of status calls, persisted across launches —
    /// so the cost of running the command center can be assessed.
    var spendUSD: Double { get }
    var callCount: Int { get }
}

/// Generates status updates by shelling out to `claude -p`. Keeps a claude session
/// id per terminal session and `--resume`s it so the model carries a rolling
/// understanding; resets the id every `resetEvery` turns so the resumed conversation
/// can't grow without bound. Swap this out for a Messages-API provider if cost bites.
final class ClaudeStatusProvider: AgentStatusProvider {
    private let model: String
    private let resetEvery = 20
    private var sessions: [String: (uuid: String, turns: Int)] = [:]
    private let lock = NSLock()

    // Cumulative spend, persisted so cost can be assessed across launches.
    private var _costUSD: Double = 0
    private var _calls: Int = 0
    var spendUSD: Double { lock.lock(); defer { lock.unlock() }; return _costUSD }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    init(model: String = "haiku") {
        self.model = model
        _costUSD = UserDefaults.standard.double(forKey: "ut.ccCostUSD")
        _calls = UserDefaults.standard.integer(forKey: "ut.ccCostCalls")
    }

    private func recordCost(_ usd: Double) {
        lock.lock(); _costUSD += usd; _calls += 1; let t = _costUSD, n = _calls; lock.unlock()
        UserDefaults.standard.set(t, forKey: "ut.ccCostUSD")
        UserDefaults.standard.set(n, forKey: "ut.ccCostCalls")
        if UserDefaults.standard.object(forKey: "ut.ccCostSince") == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ut.ccCostSince")
        }
        NSLog("[cc-cost] +$%.4f  total $%.4f over %d calls", usd, t, n)
    }

    func forget(key: String) { lock.lock(); sessions[key] = nil; lock.unlock() }

    func status(forKey key: String, output: String) async -> AgentStatus? {
        // Bound the prompt (cost + avoid a stdin pipe stall): the last ~24KB of
        // scrollback is enough conversation context for a good summary.
        let prompt = String(output.suffix(24_000))

        // Decide create-vs-resume; reset periodically to bound context growth.
        lock.lock()
        var entry = sessions[key]
        if let e = entry, e.turns >= resetEvery { entry = nil }
        let uuid: String
        let resuming: Bool
        if let e = entry { uuid = e.uuid; resuming = true; sessions[key] = (e.uuid, e.turns + 1) }
        else { uuid = UUID().uuidString.lowercased(); resuming = false; sessions[key] = (uuid, 1) }
        lock.unlock()

        var args = ["-p", "--model", model, "--output-format", "json", "--system-prompt", Self.systemPrompt]
        args += resuming ? ["--resume", uuid] : ["--session-id", uuid]

        guard let out = await Self.runClaude(args: args, stdin: prompt),
              let env = Self.envelope(out),
              let status = Self.parseStatus(env.result)
        else { return nil }
        recordCost(env.cost)
        return status
    }

    // MARK: claude invocation

    /// GUI apps don't inherit a login shell's PATH, so resolve the binary explicitly.
    private static let claudePath: String = {
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          NSHomeDirectory() + "/.claude/local/claude",
                          NSHomeDirectory() + "/.local/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "/opt/homebrew/bin/claude" : out
    }()

    private static func runClaude(args: [String], stdin: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: claudePath)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()) // no project CLAUDE.md
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                // Write stdin on a separate thread so a large prompt can't deadlock
                // against us trying to read stdout from the same thread.
                DispatchQueue.global(qos: .utility).async {
                    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                    try? inPipe.fileHandleForWriting.close()
                }
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    // MARK: parsing

    /// Pull the `result` string + this call's cost out of `--output-format json`.
    private static func envelope(_ outer: String) -> (result: String, cost: Double)? {
        struct Outer: Decodable { let result: String?; let is_error: Bool?; let total_cost_usd: Double? }
        guard let d = outer.data(using: .utf8),
              let o = try? JSONDecoder().decode(Outer.self, from: d),
              o.is_error != true, let r = o.result else { return nil }
        return (r, o.total_cost_usd ?? 0)
    }

    /// The model wraps the JSON in ```json fences and sometimes adds prose, so strip
    /// fences and parse the first {...} block. Falls back to nil (caller keeps the dot).
    private static func parseStatus(_ s: String) -> AgentStatus? {
        var t = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let lo = t.firstIndex(of: "{"), let hi = t.lastIndex(of: "}"), lo < hi else { return nil }
        t = String(t[lo...hi])
        struct Raw: Decodable { let label: String?; let summary: String?; let oneLiner: String?; let lookAtThis: String? }
        guard let d = t.data(using: .utf8), let r = try? JSONDecoder().decode(Raw.self, from: d) else { return nil }
        let label = (r.label ?? "working").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var look = r.lookAtThis?.trimmingCharacters(in: .whitespacesAndNewlines)
        if look?.isEmpty == true || look?.lowercased() == "null" { look = nil }
        return AgentStatus(label: label,
                           oneLiner: (r.summary ?? r.oneLiner ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           lookAtThis: look, updatedAt: Date())
    }

    private static let systemPrompt = """
    You are the status monitor for ONE terminal pane in a dashboard of many running agents (Claude Code, Codex, training jobs, shells). You are given that session's recent scrollback — which INCLUDES the user's own messages to the agent, so use it to infer the task the user gave and report where it stands. Across calls you keep seeing this same session, so maintain a running understanding of its trajectory.

    Reply with ONLY a single-line JSON object, nothing else:
    {"label":"<LABEL>","summary":"<2 to 4 sentences>","lookAtThis":<string or null>}

    LABEL — exactly one:
    - "needs-decision": the agent is genuinely BLOCKED on the user — a numbered choice menu ("❯ 1. Yes / 2. No"), an explicit question awaiting an answer, or a permission prompt with options.
    - "milestone": just finished something notable (tests passed, run/epoch completed, PR opened, task done).
    - "look": mid-task it produced a result, finding, or decision the user would want to see now.
    - "stuck": repeating, looping, or hitting the same error with no progress.
    - "drifting": working on something off the task the user actually asked for.
    - "no-progress": active but spinning with nothing to show.
    - "working": actively making progress.
    - "idle": nothing happening / sitting at a shell prompt.

    CRITICAL — agent-UI conventions you MUST NOT misread as blocking:
    - "esc to interrupt" or "/stop to interrupt" anywhere on screen = the agent is ACTIVELY WORKING. Never label that "needs-decision".
    - "bypass permissions on (shift+tab to cycle)", "? for shortcuts", a blinking composer prompt, the model name, token/context counters = permanent UI chrome. They are NOT a block and NOT worth surfacing.
    - Only "needs-decision" when there is a REAL choice or question the agent is waiting on.

    summary: 2–4 plain sentences with real substance — what the agent is working on (the user's task), what it has done or found recently, and what's happening right now. Be concrete: names, numbers, files, errors. If something notable happened earlier in the transcript that the user likely hasn't seen, keep surfacing it until it's clearly resolved — don't only describe the last line.

    lookAtThis: usually null. Set it ONLY for a specific moment the user would want to see right now — a real question to answer, a key result/number, a risky or irreversible action, a blocking error. Quote or tightly paraphrase it. NEVER terminal chrome, footers, or mode indicators. If nothing qualifies, null.

    Be accurate over dramatic. Output one line of JSON.
    """
}

// MARK: - Controller

/// Drives the command center: every 30s (and for any session whose dot just changed),
/// pulls recent output from each active session's broker and asks the provider for a
/// status. Holds the latest status per session for the UI. Runs only while the window
/// is open. Reads the session list + dot state from AppState.
@MainActor
final class CommandCenterModel: ObservableObject {
    @Published var statuses: [String: AgentStatus] = [:]   // keyed by SessionRef.id
    @Published var inflight: Set<String> = []              // sessions whose status is being regenerated (drives the spinner)
    @Published var costUSD: Double = 0                     // cumulative claude -p spend
    @Published var costCalls: Int = 0

    private let provider: AgentStatusProvider = ClaudeStatusProvider()
    private weak var app: AppState?
    private var timer: Timer?
    private var lastHash: [String: Int] = [:]   // content fingerprint of the last summarized output
    private var lastDot: [String: String] = [:] // last seen dot state — a flip forces a refresh
    private var busy: Set<String> = []          // per-session op dedup (a fetch/summarize in flight)
    private var claudeInflight = 0              // concurrent model calls (the expensive part)
    private var pulseN = 0
    private let maxClaude = 5
    private let storeKey = "ut.ccStatuses.v1"

    init() {
        // Show last-known statuses instantly on launch (refreshed within ~30s), so the
        // grid is never a wall of empty tiles after a relaunch.
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: AgentStatus].self, from: d) {
            statuses = saved
        }
        costUSD = provider.spendUSD
        costCalls = provider.callCount
    }

    /// Fingerprint of the output IGNORING volatile agent chrome (the ticking
    /// "esc to interrupt" footer / spinner), so a session that's only animating its
    /// timer isn't re-summarized. Real new output changes the content lines → new key.
    private func contentKey(_ s: String) -> Int {
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let low = raw.lowercased()
            if low.contains("esc to interrupt") || low.contains("stop to interrupt") {
                lines.append("·working·")   // collapse the line whose only change is the timer
            } else {
                lines.append(String(raw).trimmingCharacters(in: .whitespaces))
            }
        }
        return lines.joined(separator: "\n").hashValue
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(statuses) { UserDefaults.standard.set(d, forKey: storeKey) }
    }

    func bind(_ app: AppState) { self.app = app }

    func start() {
        guard timer == nil else { return }
        pulse()   // immediate first pass (every session is "new" → summarized)
        // Fast pulse: cheaply watch for dot flips every 5s and force an immediate
        // re-summary on a flip; do the full content-driven sweep every 6th pulse (~30s).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pulse() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func pulse() {
        guard let app else { return }
        pulseN += 1
        let fullSweep = (pulseN % 6 == 0)   // content-driven refresh ~every 30s
        var liveKeys = Set<String>()
        for m in app.machines {
            for s in (app.sessionsByMachine[m.id] ?? []) where !s.agent {
                let ref = SessionRef(machineID: m.id, session: s.name)
                liveKeys.insert(ref.id)
                let dotChanged = lastDot[ref.id] != s.state   // nil (new session) counts as changed
                lastDot[ref.id] = s.state
                // A dot flip forces an immediate refresh (bypassing content-detection AND the
                // 30s window). Otherwise the 30s sweep re-checks content and refreshes only
                // if the output actually changed.
                if dotChanged || fullSweep {
                    update(ref: ref, machine: m, name: s.name, force: dotChanged)
                }
            }
        }
        guard fullSweep else { return }
        // Drop status + continuity for sessions that vanished.
        var pruned = false
        for k in Array(statuses.keys) where !liveKeys.contains(k) {
            statuses[k] = nil; provider.forget(key: k); lastHash[k] = nil; lastDot[k] = nil; pruned = true
        }
        if pruned { persist() }
    }

    private func update(ref: SessionRef, machine: Machine, name: String, force: Bool = false) {
        guard !busy.contains(ref.id) else { return }   // one op per session; NO global cap on the cheap fetch
        busy.insert(ref.id)
        let key = ref.id, httpBase = machine.httpBase
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(key) }
            guard let output = await Self.fetchRecent(httpBase: httpBase, session: name),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("[cc] %@ recent empty/failed", key); return
            }
            // Skip the (paid) model call when the output is unchanged since the last
            // summary — ignoring the ticking working-footer. Saves cost + UI churn.
            // `force` (a dot flip) bypasses this so the transition refreshes immediately.
            let h = self.contentKey(output)
            if !force && self.lastHash[key] == h { return }
            // Output changed → needs a model call. Cap concurrent model calls only;
            // if full, bail WITHOUT setting lastHash so this session retries next tick
            // (no starvation — every session keeps getting fetched + a fair shot).
            guard self.claudeInflight < self.maxClaude else { return }
            self.claudeInflight += 1
            self.inflight.insert(key)
            let status = await self.provider.status(forKey: key, output: output)
            self.claudeInflight -= 1
            self.inflight.remove(key)
            guard let status else { NSLog("[cc] %@ claude returned nil", key); return }
            self.lastHash[key] = h
            self.statuses[key] = status
            self.costUSD = self.provider.spendUSD
            self.costCalls = self.provider.callCount
            self.persist()
            NSLog("[cc] %@ -> [%@] %@", key, status.label, status.oneLiner)
        }
    }

    private static func fetchRecent(httpBase: String, session: String) async -> String? {
        guard let enc = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(httpBase)/recent?session=\(enc)&lines=500") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Importance ordering

/// Lower sorts first (more of your attention). The model's label is the PRIMARY
/// signal — the dot is only a fallback when there's no status yet, since the dot
/// misclassifies often. needs-you items land at priority <= 1 (the top band).
func attentionPriority(state: String, status: AgentStatus?) -> Int {
    switch status?.label {
    case "needs-decision": return 0
    case "look":           return 1
    case "stuck":          return 2
    case "no-progress", "drifting": return 3
    case "milestone":      return 4
    case "working":        return 5
    case "idle":           return 8
    default: break   // no status yet → lean on the dot
    }
    if state == "waiting" { return 0 }
    if state == "working" { return 6 }
    return 9
}

// MARK: - View

/// The command center: a grid of agent tiles sorted by attention. Needs-you sit on
/// top, larger, with the line worth reading; the rest follow as uniform cards. EVERY
/// tile shows a one-line summary + a status label from the status updater — the dot is
/// only a small secondary cue (it misclassifies too often to be the whole signal).
/// A panel in the main window (⇧⌘A); tap a tile to dive into that session.
struct CommandCenterView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cc: CommandCenterModel
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    private struct Tile: Identifiable {
        let ref: SessionRef; let machineName: String; let session: SessionInfo
        let status: AgentStatus?; let inflight: Bool; let priority: Int
        var id: String { ref.id }
    }

    private var tiles: [Tile] {
        var out: [Tile] = []
        for m in state.machines {
            for s in (state.sessionsByMachine[m.id] ?? []) where !s.agent {
                let ref = SessionRef(machineID: m.id, session: s.name)
                if state.hiddenSessions.contains(ref.id) { continue }
                let st = cc.statuses[ref.id]
                out.append(Tile(ref: ref, machineName: m.name, session: s, status: st,
                                inflight: cc.inflight.contains(ref.id),
                                priority: attentionPriority(state: s.state, status: st)))
            }
        }
        return out.sorted { ($0.priority, $0.session.name) < ($1.priority, $1.session.name) }
    }

    var body: some View {
        let all = tiles
        let backlogged = all.filter { state.backlog.contains($0.ref.id) }
        let activeT    = all.filter { !state.backlog.contains($0.ref.id) }
        let needsYou = activeT.filter { $0.priority <= 1 }
        let rest     = activeT.filter { $0.priority > 1 }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                glance(needsYou: needsYou.count, rest: rest.count)
                if !needsYou.isEmpty {
                    header("Needs you", needsYou.count)
                    grid(needsYou, minWidth: 360, size: .large)
                }
                if !rest.isEmpty {
                    header("All sessions", rest.count)
                    grid(rest, minWidth: 270, size: .medium)
                }
                if !backlogged.isEmpty {
                    header("Backlog", backlogged.count)
                    grid(backlogged, minWidth: 240, size: .medium).opacity(0.6)
                }
                if all.isEmpty {
                    Text("No sessions.").foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .padding(.top, 34)   // clear the window's title/traffic-light zone
        }
        .background(Theme.appBackground)
        .onAppear { cc.bind(state); cc.start() }
        .onDisappear { cc.stop() }
    }

    private func glance(needsYou: Int, rest: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Command Center").font(cf(21, .bold)).foregroundStyle(Theme.textPrimary)
            Text(needsYou > 0 ? "\(needsYou) need\(needsYou == 1 ? "s" : "") you · \(rest) other"
                              : "all \(rest) quiet")
                .font(cf(13)).foregroundStyle(needsYou > 0 ? Theme.waiting : Theme.textTertiary)
            Spacer()
            if cc.costCalls > 0 {
                Text(String(format: "$%.2f · %d updates", cc.costUSD, cc.costCalls))
                    .font(cf(11)).foregroundStyle(Theme.textTertiary)
                    .help("Cumulative claude -p spend (status updates) since first run")
            }
        }
    }

    private func header(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(cf(11.5, .semibold)).foregroundStyle(Theme.textSecondary)
            Text("\(n)").font(cf(11, .medium)).foregroundStyle(Theme.textTertiary.opacity(0.7))
        }
    }

    @ViewBuilder
    private func grid(_ items: [Tile], minWidth: CGFloat, size: AgentTileView.Size) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 10) {
            ForEach(items) { t in
                AgentTileView(machineName: t.machineName, session: t.session,
                              unseen: state.unseen.contains(t.ref.id), status: t.status,
                              inflight: t.inflight, size: size,
                              backlogged: state.backlog.contains(t.ref.id),
                              onBacklog: { state.toggleBacklog(t.ref) }) {
                    state.selection = t.ref
                    state.showOverview = false
                }
            }
        }
    }
}

struct AgentTileView: View {
    enum Size { case large, medium }
    let machineName: String
    let session: SessionInfo
    let unseen: Bool
    let status: AgentStatus?
    let inflight: Bool
    let size: Size
    let backlogged: Bool
    let onBacklog: () -> Void
    let onOpen: () -> Void

    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }
    private var isLarge: Bool { size == .large }

    /// Color from the model's label first; fall back to the dot only when there's no
    /// status yet (the dot alone misclassifies, so it never drives content).
    private var tint: SwiftUI.Color {
        switch status?.label {
        case "needs-decision": return Theme.waiting
        case "look":           return Theme.accent
        case "stuck", "no-progress": return SwiftUI.Color(red: 0.90, green: 0.42, blue: 0.42)
        case "drifting":       return Theme.unseen
        case "milestone":      return Theme.attached
        case "working":        return Theme.running
        case "idle":           return Theme.textTertiary
        default: break
        }
        switch session.state {
        case "waiting": return Theme.waiting
        case "working": return Theme.running
        default:        return Theme.textTertiary
        }
    }

    private var chipGlyph: String {
        if let s = status { return s.glyph }
        switch session.state { case "working": return "gearshape.fill"; case "waiting": return "questionmark.circle.fill"; default: return "circle" }
    }
    private var chipText: String {
        if let s = status { return s.display }
        switch session.state { case "working": return "working"; case "waiting": return "needs you"; default: return "idle" }
    }
    private var summary: String {
        if let s = status, !s.oneLiner.isEmpty { return s.oneLiner }
        return inflight ? "reading output…" : "no status yet"
    }
    private var summaryMuted: Bool { status?.oneLiner.isEmpty ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 8, height: 8)   // small secondary cue, not the whole signal
                Text(session.name).font(cf(isLarge ? 16 : 15, .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(machineName).font(cf(11)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 6)
                if inflight { ProgressView().controlSize(.small).scaleEffect(0.6) }
                chip.fixedSize().layoutPriority(1)   // never clip the status
                Button(action: onBacklog) {
                    Image(systemName: backlogged ? "checkmark.circle.fill" : "circle")
                        .font(cf(13))
                        .foregroundStyle(backlogged ? Theme.attached : Theme.textTertiary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(backlogged ? "Remove from backlog" : "Backlog — set aside")
            }
            Text(summary)
                .font(cf(isLarge ? 13.5 : 13))
                .foregroundStyle(summaryMuted ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(isLarge ? 7 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLarge, let look = status?.lookAtThis, !look.isEmpty {
                Text(look).font(cf(12.5).monospaced()).foregroundStyle(Theme.textPrimary)
                    .lineLimit(4).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: (isLarge ? 88 : 58) * uiScale, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sidebarBackground.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint.opacity(isLarge ? 0.55 : 0.32), lineWidth: isLarge ? 1.6 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(status?.oneLiner ?? session.name)
    }

    private var chip: some View {
        HStack(spacing: 3) {
            Image(systemName: chipGlyph).font(cf(10))
            Text(chipText).font(cf(11.5, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.16)))
    }
}
