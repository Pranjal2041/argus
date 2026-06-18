import SwiftUI
import Foundation

// MARK: - Status model

/// A status for one agent session, produced by the status updater (claude -p).
/// This is the inferred layer that sits on top of the deterministic dot.
struct AgentStatus: Equatable, Codable {
    var label: String        // model token: needs-decision/stuck/drifting/working/look/milestone/idle (no-progress legacy)
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
    /// Produce a status for `key` from its recent terminal `output`. `note`, if present,
    /// is a one-time message prepended to the prompt (e.g. a user status correction). nil on failure.
    func status(forKey key: String, output: String, note: String?) async -> AgentStatus?
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

    func status(forKey key: String, output: String, note: String? = nil) async -> AgentStatus? {
        // Bound the prompt to the recent tail (cost + focus): the last ~14KB keeps the
        // model on the CURRENT state rather than diluting it with old scrollback. A `note`
        // (e.g. the user just corrected the status) rides at the top, before the scrollback.
        let tail = String(output.suffix(14_000))
        let prompt = note.map { $0 + "\n\n" + tail } ?? tail

        // Decide create-vs-resume; reset periodically to bound context growth.
        lock.lock()
        var entry = sessions[key]
        if let e = entry, e.turns >= resetEvery { entry = nil }
        let uuid: String
        let resuming: Bool
        if let e = entry { uuid = e.uuid; resuming = true; sessions[key] = (e.uuid, e.turns + 1) }
        else { uuid = UUID().uuidString.lowercased(); resuming = false; sessions[key] = (uuid, 1) }
        lock.unlock()

        // Up to 2 attempts: a transient API/connection error (ECONNRESET, overloaded)
        // shouldn't leave the card stale until the next 30s sweep. After the first
        // attempt the claude session exists, so the retry --resume's it.
        for attempt in 0..<2 {
            var args = ["-p", "--model", model, "--output-format", "json", "--system-prompt", Self.systemPrompt]
            args += (resuming || attempt > 0) ? ["--resume", uuid] : ["--session-id", uuid]
            if let out = await Self.runClaude(args: args, stdin: prompt), let env = Self.envelope(out) {
                recordCost(env.cost)
                if let status = Self.parseStatus(env.result) { return status }
            }
            if attempt == 0 {
                NSLog("[cc] %@ status attempt failed — retrying in 3s", key)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        return nil
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
    You are the at-a-glance status for ONE agent session in a command center where the user runs many coding/research agents and cannot watch them all. In one glance, tell them the ONE thing that matters about THIS agent right now, relative to what they asked it to do — like a sharp collaborator glancing over their shoulder.

    You get the recent scrollback, which includes the USER'S OWN MESSAGES (their instructions) and the agent's work; the bottom is the present. First infer what the user asked this agent to do, then report where it stands ON THAT TASK and what, if anything, the user needs to know or do.

    Reply with ONLY one line of JSON: {"label":"<LABEL>","summary":"<1-3 sentences>","lookAtThis":<string or null>}

    If the input starts with a "[USER STATUS CORRECTION]" line: the user just manually changed this agent's status because they judged your auto-status wrong. Take it seriously — work out from the scrollback WHY they'd pick the status they chose, and lean toward a status consistent with their judgment. Don't simply revert to what you had. (You're not forced to output their exact label if the screen now clearly shows something different — but their correction is a strong signal about what matters here.)

    READING THE SCREEN CORRECTLY (this is where mistakes happen):
    - The bottom-most line that looks like "❯ <some text>" sitting just above the "⏵⏵ bypass permissions…" status bar is the LIVE INPUT BOX. The text in it is very often an AUTO-GENERATED suggestion (ghost text the agent proposes, like "yes go ahead", "continue", "yes please"). It is NOT something the user typed and NOT an approval. NEVER treat that composer line as a user message, an answer, or a go-ahead.
    - The user's REAL messages are earlier in the transcript, each one followed by the agent actually acting on it. If the agent asked a question and the next thing is just the input box (no agent work after it, no "esc to interrupt"), then the user has NOT answered yet — the agent is WAITING ON THE USER.
    - "esc to interrupt" / "/stop to interrupt" on screen = the agent is generating right now (working). Its ABSENCE means the agent is not currently generating.

    The summary is INSIGHT, not a recap:
    - Lead with the meaningful state: the key result/finding it produced, the decision it's waiting on, whether it finished, or where it's stuck — relative to the user's task.
    - Concrete: real numbers, results, filenames, the actual question. Skip routine steps and tool chatter.
    - Surface any loose end that needs the user — a pending approval, an unanswered question it asked, a known blocker. That is often the single most useful thing to say.
    - NO FILLER. Never write "ready for next task", "awaiting command", "ready for you to try", "sitting at the prompt", or restate routine steps.

    BACKGROUND JOBS: a long-running job whose output is VISIBLY PROGRESSING — a training run with a climbing step count, a sweep with a rising %, an rsync with files ticking up, fresh log lines — counts as ACTIVE even when the agent itself is idle at the prompt; report the job's state and progress ("training step 393/400, val healthy"), label working. BUT: a count of shells or processes merely existing ("17 shells still running") is NOT progress and NOT "working" on its own — only count a job as active if its output is actually advancing. And a pending question to the user (see below) ALWAYS takes priority over a running job.

    SUB-AGENTS: an agent that spawned its own background sub-agents and is "Waiting for N background agents to finish" (you'll see a list of running sub-tasks / "↓ to manage" / "← for agents") is WORKING — it delegated the work and is waiting on ITS OWN agents, NOT on you. This is NEVER needs-decision. Summarize what the sub-agents are doing.

    OPTIONAL FEEDBACK PROMPTS: the agent CLIs periodically pop an OPTIONAL "how was this session? / rate this response / feedback on session quality" prompt on their own. It is not a real question and the user just ignores it — it is NEVER needs-decision and never "needs you". Treat it as chrome and report the actual underlying state instead (e.g. the background job that is still running, or idle).

    OVERRIDES — check these FIRST; if one fits, use it and stop:
    - Is the newest real activity a USER MESSAGE — new instructions, requirements, a description of what to build, a correction, or pushback like "still broken / check it again"? Then the ball is in the AGENT's court: it owns the next move and should just do it. Label "working" (or "idle" only if nothing is running and it plainly has not started yet). NEVER "needs-decision" or "stuck". This holds even if the user's message looks unfinished or trails off mid-sentence, and even if you think the agent ought to confirm the approach first — a user GIVING direction is the agent's cue to act, NOT the agent waiting on the user. Do NOT invent an "awaiting requirements / awaiting confirmation / awaiting clarification" state from a user who is handing the agent a task.
    - Is the only thing "asking" the user an optional session-quality/feedback/rating prompt? It is never needs-decision (see OPTIONAL FEEDBACK PROMPTS) — fall through to the real state below.

    LABEL — work down this list IN ORDER and pick the FIRST that applies. Do not skip ahead.
    1. needs-decision: the AGENT itself asked the user a SPECIFIC question and is blocked on the answer — you can point to the actual question the agent wrote on screen (no agent work after it, no "esc to interrupt"). It is NOT needs-decision if YOU are the one inferring "awaiting requirements / awaiting confirmation / needs the user to clarify" — that is you second-guessing; when the USER is the one giving instructions, the agent should act (working), it is not waiting on anyone. Ghost text in the composer is not an answer; an optional session-quality/feedback prompt is not a question (see OPTIONAL FEEDBACK PROMPTS).
    2. stuck: the agent is genuinely halted — the SAME error/failure repeating with no progress, a crash or permission loop, or it explicitly gave up. NOT a hard or still-unsolved problem it is actively working on, NOT user frustration, NOT the mere existence of an open bug, NOT a fresh user message. A difficult task in progress is "working", not "stuck".
    3. drifting: clearly off-track or churning without making progress (only if obvious).
    4. working: the agent is generating now ("esc to interrupt" present), OR a background job's output is visibly advancing (see BACKGROUND JOBS).
    5. look: nothing is running, but a notable or surprising result is on screen the user should see (no decision needed).
    6. milestone: nothing is running, but a substantial deliverable just landed — an experiment finished with findings, a PR merged, a feature built and tested. NOT a routine one-line commit or minor edit.
    7. idle: none of the above — at the prompt, nothing running or advancing, last action minor or the task quietly done. Do not invent importance.

    Only labels 1-3 mean "the user should look now"; reserve them for when they genuinely apply. Among 4-7, if unsure, it does not matter much — do not agonize.

    Ignore as chrome: "bypass permissions…", "? for shortcuts", the model name, token/context counters, "/clear to save Xk tokens".

    lookAtThis: usually null. Only set it to the single most important current line — quote it verbatim. Otherwise null.
    """
}

// MARK: - Controller

/// File logger for diagnosing the command-center sweep — NSLog does not surface to
/// `log show`/stderr when the app is launched via `open`. Appends to /tmp/argus_cc.log.
func ccLog(_ s: String) {
    guard let data = (String(format: "%.0f ", Date().timeIntervalSince1970) + s + "\n").data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/argus_cc.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
}

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
    private var lastOKAt: [String: Double] = [:] // when each session was last successfully summarized (for fair scheduling)
    private var correction: [String: String] = [:] // one-time note for the model after a manual status change (NOT persisted; no learning)
    private var consumedOverrideTS: [String: Int64] = [:] // last phone-set override applied per session (so each is consumed once)

    /// The user manually set a card's status. Show it immediately and queue a one-time
    /// note so the NEXT model call is told the user corrected it (and reasons about why) —
    /// it then re-decides on its own. Nothing is persisted or learned; the label is not locked.
    func setManualLabel(ref: SessionRef, label: String) {
        let key = ref.id
        let prev = statuses[key]
        let old = prev?.label ?? "idle"
        guard label != old else { return }
        statuses[key] = AgentStatus(label: label, oneLiner: prev?.oneLiner ?? "", lookAtThis: prev?.lookAtThis, updatedAt: Date())
        correction[key] = "[USER STATUS CORRECTION] The user just changed this session's status from \"\(old)\" to \"\(label)\" — they judged \"\(old)\" wrong for what's actually happening. Work out why and weigh it."
        lastHash[key] = nil   // force the next sweep to re-summarize (and deliver the note) even if the screen is unchanged
        persist(); publish()
    }
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
        ccLog("start() called (timer already? \(timer != nil))")
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
        guard let app else { ccLog("pulse: app nil (not bound)"); return }
        // Pick up manual statuses set on another device (the phone) and apply them here.
        for m in app.machines { Task { [weak self] in await self?.consumeOverrides(machine: m) } }
        pulseN += 1
        let fullSweep = (pulseN % 6 == 0)   // content-driven refresh ~every 30s
        if fullSweep {
            let nonAgent = app.machines.reduce(0) { $0 + (app.sessionsByMachine[$1.id]?.filter { !$0.agent }.count ?? 0) }
            ccLog("pulse n=\(pulseN) machines=\(app.machines.count) sessions=\(nonAgent)")
        }
        var liveKeys = Set<String>()
        var candidates: [(ref: SessionRef, machine: Machine, name: String, force: Bool)] = []
        for m in app.machines {
            // Skip hidden sessions entirely: no model call is spent on them (the
            // status agent is inactive for hidden panels) and they never reach the
            // published /ccstatus blob, so neither this Mac nor the phone shows them
            // in the command center.
            for s in (app.sessionsByMachine[m.id] ?? []) where !s.agent && !s.hidden {
                let ref = SessionRef(machineID: m.id, session: s.name)
                liveKeys.insert(ref.id)
                let dotChanged = lastDot[ref.id] != s.state   // nil (new session) counts as changed
                lastDot[ref.id] = s.state
                // A dot flip forces an immediate refresh (bypassing content-detection AND the
                // 30s window). Otherwise the 30s sweep re-checks content and refreshes only
                // if the output actually changed.
                if dotChanged || fullSweep {
                    candidates.append((ref, m, s.name, dotChanged))
                }
            }
        }
        // Fair scheduling: only `maxClaude` model calls run concurrently, so issue them
        // LEAST-RECENTLY-SUMMARIZED first. Machine order put local sessions first, so they
        // grabbed every slot and remote (babel) sessions were perpetually `gated`/starved.
        candidates.sort { (lastOKAt[$0.ref.id] ?? 0) < (lastOKAt[$1.ref.id] ?? 0) }
        for c in candidates { update(ref: c.ref, machine: c.machine, name: c.name, force: c.force) }
        guard fullSweep else { return }
        // Drop status + continuity for sessions that vanished.
        var pruned = false
        for k in Array(statuses.keys) where !liveKeys.contains(k) {
            statuses[k] = nil; provider.forget(key: k); lastHash[k] = nil; lastDot[k] = nil; pruned = true
        }
        if pruned { persist() }
        publish()   // keep the broker blob fresh for the phone each sweep
    }

    /// Pull manual status overrides a phone set (it can't run the model itself), apply
    /// each through the normal correction path — so the Mac shows it immediately, the
    /// model is told the user corrected it, and it re-publishes /ccstatus so the change
    /// syncs back to every device — then clear it on the broker.
    private func consumeOverrides(machine: Machine) async {
        guard let url = URL(string: machine.httpBase + "/ccoverride") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        struct Ov: Decodable { let session: String; let label: String; let ts: Int64 }
        struct Wrap: Decodable { let overrides: [Ov] }
        guard let w = try? JSONDecoder().decode(Wrap.self, from: data) else { return }
        for ov in w.overrides {
            let ref = SessionRef(machineID: machine.id, session: ov.session)
            guard consumedOverrideTS[ref.id] != ov.ts else { continue }   // consume each once
            consumedOverrideTS[ref.id] = ov.ts
            setManualLabel(ref: ref, label: ov.label)
            // Clear it on the broker (compare-and-clear by ts, so a newer one survives).
            guard let enc = ov.session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let cu = URL(string: machine.httpBase + "/ccoverride?session=\(enc)&clear=\(ov.ts)") else { continue }
            var creq = URLRequest(url: cu); creq.httpMethod = "POST"; creq.timeoutInterval = 6
            URLSession.shared.dataTask(with: creq).resume()
        }
    }

    private func update(ref: SessionRef, machine: Machine, name: String, force: Bool = false) {
        guard !busy.contains(ref.id) else { return }   // one op per session; NO global cap on the cheap fetch
        busy.insert(ref.id)
        let key = ref.id, httpBase = machine.httpBase
        Task { [weak self] in
            guard let self else { return }
            defer { self.busy.remove(key) }
            ccLog("sweep \(key) base=\(httpBase) force=\(force)")
            guard let output = await Self.fetchRecent(httpBase: httpBase, session: name),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ccLog("FETCH-FAIL \(key) base=\(httpBase)")
                NSLog("[cc] %@ recent empty/failed", key); return
            }
            ccLog("fetch-ok \(key) len=\(output.count)")
            // Skip the (paid) model call when the output is unchanged since the last
            // summary — ignoring the ticking working-footer. Saves cost + UI churn.
            // `force` (a dot flip) bypasses this so the transition refreshes immediately.
            let h = self.contentKey(output)
            if !force && self.lastHash[key] == h { ccLog("skip-unchanged \(key)"); return }
            // Output changed → needs a model call. Cap concurrent model calls only;
            // if full, bail WITHOUT setting lastHash so this session retries next tick
            // (no starvation — every session keeps getting fetched + a fair shot).
            guard self.claudeInflight < self.maxClaude else { ccLog("gated \(key)"); return }
            self.claudeInflight += 1
            self.inflight.insert(key)
            let status = await self.provider.status(forKey: key, output: output, note: self.correction[key])
            self.claudeInflight -= 1
            self.inflight.remove(key)
            guard let status else { ccLog("claude-nil \(key)"); NSLog("[cc] %@ claude returned nil", key); return }
            self.correction[key] = nil   // delivered — --resume keeps it in context so it won't just revert
            ccLog("OK \(key) [\(status.label)] \(status.oneLiner.prefix(80))")
            self.lastHash[key] = h
            self.lastOKAt[key] = Date().timeIntervalSince1970
            self.statuses[key] = status
            self.costUSD = self.provider.spendUSD
            self.costCalls = self.provider.callCount
            self.persist()
            self.publish()
            NSLog("[cc] %@ -> [%@] %@", key, status.label, status.oneLiner)
        }
    }

    /// Publish the current status map to the LOCAL broker so other clients (the phone)
    /// can read it via GET /ccstatus. Keyed by machine name + session so any client can
    /// match it to its own session list. ("Mac publishes, phone reads.")
    private func publish() {
        guard let app else { return }
        struct Item: Encodable {
            let session: String; let label: String; let summary: String
            let lookAtThis: String?; let updatedAt: Double
        }
        // Per-broker: each broker stores ITS sessions' statuses, keyed by session name.
        // The phone reads each broker's /ccstatus and joins by name — no cross-client
        // machine-name ambiguity (the Mac calls its host "this mac"; the phone sees a
        // tailnet hostname for the same broker).
        for m in app.machines {
            var items: [Item] = []
            // Hidden sessions are excluded from the published blob too, so the phone's
            // command center never sees them (matches this Mac hiding them from view).
            for s in (app.sessionsByMachine[m.id] ?? []) where !s.agent && !s.hidden {
                guard let st = statuses[SessionRef(machineID: m.id, session: s.name).id] else { continue }
                items.append(Item(session: s.name, label: st.label, summary: st.oneLiner,
                                  lookAtThis: st.lookAtThis, updatedAt: st.updatedAt.timeIntervalSince1970))
            }
            guard let url = URL(string: m.httpBase + "/ccstatus"),
                  let body = try? JSONEncoder().encode(["items": items]) else { continue }
            var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = body; req.timeoutInterval = 6
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    private static func fetchRecent(httpBase: String, session: String) async -> String? {
        guard let enc = session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(httpBase)/recent?session=\(enc)&lines=300") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Importance ordering

/// Lower sorts first (more of your attention). The model's label is the PRIMARY
/// signal — the dot is only a fallback when there's no status yet, since the dot
/// misclassifies often. Only the must-act labels (needs-decision, stuck) land in the
/// top band (priority <= 1). The "no action needed" labels (look/milestone/idle) all
/// share ONE bucket (5) on purpose: the label can wobble between them on the same
/// unchanged screen, so giving them equal priority keeps a card from jumping around —
/// only its tint shifts, never its position. working sits just above (active now).
/// The command-center SECTION a session belongs to (the user-visible grouping):
/// 0 = needs you, 1 = done/idle, 2 = working. Backlog (3) is a user choice handled by
/// the view. A card moves between sections only when its category genuinely changes;
/// the flappy labels (idle/look/milestone) all map to ONE section and within a section
/// cards are ordered by name, so nothing reshuffles from a label flap or a text update.
func ccSection(state: String, status: AgentStatus?) -> Int {
    switch status?.label {
    case "needs-decision", "stuck":            return 0   // act now
    case "working", "drifting", "no-progress": return 2   // running on its own
    case "milestone", "look", "idle":          return 1   // done / quiet
    default: break   // no status yet → lean on the dot
    }
    switch state { case "waiting": return 0; case "working": return 2; default: return 1 }
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
        let status: AgentStatus?; let inflight: Bool; let section: Int
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
                                section: ccSection(state: s.state, status: st)))
            }
        }
        // Name-ordered so each section reads stably; section grouping happens in the body.
        return out.sorted { $0.session.name < $1.session.name }
    }

    /// The section a tile is shown under — backlog (a user choice) overrides its status.
    private func displaySection(_ t: Tile) -> Int { state.backlog.contains(t.ref.id) ? 3 : t.section }

    var body: some View {
        let all = tiles
        let needsCount = all.filter { displaySection($0) == 0 }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                glance(needsYou: needsCount, rest: all.count - needsCount)
                sectionBlock(0, "Needs you",   .large,  360, in: all)
                sectionBlock(1, "Done & idle", .medium, 270, in: all)
                sectionBlock(2, "Working",     .medium, 270, in: all)
                sectionBlock(3, "Backlog",     .medium, 240, in: all)
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
        // The model is started app-wide (App.swift) so it keeps running when this page is
        // not visible. start() is idempotent; we deliberately do NOT stop() on disappear.
        .onAppear { cc.bind(state); cc.start() }
    }

    /// One section: header + grid, in fixed position. Cards within are name-ordered (from
    /// `tiles`), so a status change can move a card to a DIFFERENT section but never
    /// reshuffles cards within one — no ad-hoc jumping while you watch.
    private func sectionBlock(_ id: Int, _ title: String, _ size: AgentTileView.Size, _ minW: CGFloat, in all: [Tile]) -> some View {
        let cards = all.filter { displaySection($0) == id }
        return Group {
            if !cards.isEmpty {
                header(title, cards.count)
                grid(cards, minWidth: minW, size: size).opacity(id == 3 ? 0.6 : 1)
            }
        }
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
                              onSetStatus: { cc.setManualLabel(ref: t.ref, label: $0) },
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
    let onSetStatus: (String) -> Void
    let onBacklog: () -> Void
    let onOpen: () -> Void

    /// User-facing names for the status labels in the right-click "Set status" menu.
    private func statusName(_ l: String) -> String {
        switch l {
        case "needs-decision": return "Needs you"
        case "stuck":          return "Stuck"
        case "drifting":       return "Drifting"
        case "working":        return "Working"
        case "look":           return "Worth a look"
        case "milestone":      return "Milestone"
        default:               return "Idle"
        }
    }

    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }
    private var isLarge: Bool { size == .large }

    /// Color from the model's label first; fall back to the dot only when there's no
    /// status yet (the dot alone misclassifies, so it never drives content).
    private var tint: SwiftUI.Color {
        switch status?.label {
        case "needs-decision": return Theme.waiting
        case "look":           return Theme.accent
        case "stuck", "no-progress": return Theme.unreachable
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

    /// The leading dot is the DETERMINISTIC state, resolved with the EXACT SAME logic
    /// as the sidebar dot so the two always agree — including ORANGE for "done, unseen"
    /// (a turn finished on a pane you haven't opened). blue = working, orange = done-unseen,
    /// green = idle/ready.
    private var stateDot: SwiftUI.Color {
        AgentIndicatorStyle.resolve(state: AgentState(raw: session.state),
                                    attached: session.attached, unseen: unseen).color
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
                Circle().fill(stateDot).frame(width: 9, height: 9)   // deterministic tmux state — glanceable next to the model chip
                    .help("state: \(session.state)")
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
        .contextMenu {
            // Right-click → fix a wrong auto-status. The choice is shown immediately and
            // fed to the model as a one-time correction (it then re-reasons); nothing is
            // locked or remembered. Built from constant values only (no observable reads).
            Section("Set status") {
                ForEach(["working", "idle", "needs-decision", "stuck", "milestone", "look", "drifting"], id: \.self) { lbl in
                    Button(statusName(lbl)) { onSetStatus(lbl) }
                }
            }
        }
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
