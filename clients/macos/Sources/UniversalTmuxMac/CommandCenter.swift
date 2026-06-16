import SwiftUI
import Foundation

// MARK: - Status model

/// A status for one agent session, produced by the status updater (claude -p).
/// This is the inferred layer that sits on top of the deterministic dot.
struct AgentStatus: Equatable {
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

    init(model: String = "haiku") { self.model = model }

    func forget(key: String) { lock.lock(); sessions[key] = nil; lock.unlock() }

    func status(forKey key: String, output: String) async -> AgentStatus? {
        // Bound the prompt (cost + avoid a stdin pipe stall): last ~16KB is plenty.
        let prompt = String(output.suffix(16_000))

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
              let result = Self.resultField(out),
              let status = Self.parseStatus(result)
        else { return nil }
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

    /// Pull the `result` string out of `--output-format json`'s envelope.
    private static func resultField(_ outer: String) -> String? {
        struct Outer: Decodable { let result: String?; let is_error: Bool? }
        guard let d = outer.data(using: .utf8),
              let o = try? JSONDecoder().decode(Outer.self, from: d),
              o.is_error != true, let r = o.result else { return nil }
        return r
    }

    /// The model wraps the JSON in ```json fences and sometimes adds prose, so strip
    /// fences and parse the first {...} block. Falls back to nil (caller keeps the dot).
    private static func parseStatus(_ s: String) -> AgentStatus? {
        var t = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let lo = t.firstIndex(of: "{"), let hi = t.lastIndex(of: "}"), lo < hi else { return nil }
        t = String(t[lo...hi])
        struct Raw: Decodable { let label: String?; let oneLiner: String?; let lookAtThis: String? }
        guard let d = t.data(using: .utf8), let r = try? JSONDecoder().decode(Raw.self, from: d) else { return nil }
        let label = (r.label ?? "working").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var look = r.lookAtThis?.trimmingCharacters(in: .whitespacesAndNewlines)
        if look?.isEmpty == true || look?.lowercased() == "null" { look = nil }
        return AgentStatus(label: label,
                           oneLiner: (r.oneLiner ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           lookAtThis: look, updatedAt: Date())
    }

    private static let systemPrompt = """
    You monitor one terminal pane running a coding or training agent. You are given its recent visible output. Reply with ONLY a single-line JSON object, nothing else:
    {"label":"<LABEL>","oneLiner":"<short phrase>","lookAtThis":<string or null>}

    LABEL is exactly one of:
    - "needs-decision": blocked, asking the user to confirm or choose.
    - "milestone": just finished something notable (tests passed, run completed, PR opened).
    - "look": mid-task it produced a result/answer/decision the user would want to see now.
    - "stuck": repeating, looping, or erroring with no progress.
    - "drifting": working on something off the apparent task.
    - "no-progress": active but spinning with nothing to show.
    - "working": normal progress.
    - "idle": nothing happening / sitting at a shell prompt.

    oneLiner: at most ~10 words, plain words, what the agent is doing now. No preamble.
    lookAtThis: usually null. Set ONLY if a specific line is worth the user's eyes right now (risky/irreversible action, key result, a direct question); quote that line verbatim from the output. Never invent it.
    Be conservative: unsure -> "working" or "idle" and null. One line of JSON.
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
    @Published var inflight: Set<String> = []              // updates currently running

    private let provider: AgentStatusProvider = ClaudeStatusProvider()
    private weak var app: AppState?
    private var timer: Timer?
    private var lastState: [String: String] = [:]
    private let maxConcurrent = 4

    func bind(_ app: AppState) { self.app = app }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let app else { return }
        var liveKeys = Set<String>()
        for m in app.machines {
            for s in (app.sessionsByMachine[m.id] ?? []) where !s.agent {
                let ref = SessionRef(machineID: m.id, session: s.name)
                liveKeys.insert(ref.id)
                let changed = lastState[ref.id] != nil && lastState[ref.id] != s.state
                lastState[ref.id] = s.state
                let active = s.state == "working" || s.state == "waiting"
                let needFirst = statuses[ref.id] == nil
                if active || changed || needFirst { update(ref: ref, machine: m, name: s.name) }
            }
        }
        // Drop status + continuity for sessions that vanished.
        for k in Array(statuses.keys) where !liveKeys.contains(k) {
            statuses[k] = nil; provider.forget(key: k); lastState[k] = nil
        }
    }

    private func update(ref: SessionRef, machine: Machine, name: String) {
        guard !inflight.contains(ref.id), inflight.count < maxConcurrent else { return }
        inflight.insert(ref.id)
        let key = ref.id, httpBase = machine.httpBase
        Task { [weak self] in
            defer { self?.inflight.remove(key) }
            guard let output = await Self.fetchRecent(httpBase: httpBase, session: name),
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("[cc] %@ recent empty/failed", key); return
            }
            guard let status = await self?.provider.status(forKey: key, output: output) else {
                NSLog("[cc] %@ claude returned nil", key); return
            }
            NSLog("[cc] %@ -> [%@] %@", key, status.label, status.oneLiner)
            self?.statuses[key] = status
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

/// Lower sorts first (more of your attention). Deterministic "waiting" outranks any
/// inferred label; otherwise the model's label drives it; healthy/idle sink.
func attentionPriority(state: String, status: AgentStatus?) -> Int {
    if state == "waiting" { return 0 }
    switch status?.label {
    case "needs-decision": return 0
    case "look":           return 1
    case "stuck":          return 2
    case "no-progress", "drifting": return 3
    case "milestone":      return 4
    default: break
    }
    if state == "working" { return 5 }
    return 9
}

// MARK: - View

/// One agent per row, sorted by attention: the ones that need you sit at the top and
/// stay full-size; quiet ones drop to a compact, dimmed line. (v1 layout — the
/// stable-grid + needs-you-zone refinement comes next.)
struct CommandCenterView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cc: CommandCenterModel

    private struct Row: Identifiable {
        let ref: SessionRef; let machineName: String; let session: SessionInfo
        let status: AgentStatus?; let inflight: Bool; let priority: Int
        var id: String { ref.id }
    }

    private var rows: [Row] {
        var out: [Row] = []
        for m in state.machines {
            for s in (state.sessionsByMachine[m.id] ?? []) where !s.agent {
                let ref = SessionRef(machineID: m.id, session: s.name)
                if state.hiddenSessions.contains(ref.id) { continue }
                let st = cc.statuses[ref.id]
                out.append(Row(ref: ref, machineName: m.name, session: s, status: st,
                               inflight: cc.inflight.contains(ref.id),
                               priority: attentionPriority(state: s.state, status: st)))
            }
        }
        return out.sorted { ($0.priority, $0.session.name) < ($1.priority, $1.session.name) }
    }

    var body: some View {
        let all = rows
        let needsYou = all.filter { $0.priority <= 1 }
        let active = all.filter { $0.priority > 1 && $0.priority < 9 }
        let quiet = all.filter { $0.priority >= 9 }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !needsYou.isEmpty {
                    sectionHeader("Needs you", count: needsYou.count)
                    ForEach(needsYou) { card($0, compact: false) }
                }
                if !active.isEmpty {
                    sectionHeader("Active", count: active.count)
                    ForEach(active) { card($0, compact: false) }
                }
                if !quiet.isEmpty {
                    sectionHeader("Quiet", count: quiet.count)
                    ForEach(quiet) { card($0, compact: true) }
                }
                if all.isEmpty {
                    Text("No sessions.").foregroundStyle(Theme.textTertiary).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(Theme.appBackground.ignoresSafeArea())
        .onAppear { cc.bind(state); cc.start() }
        .onDisappear { cc.stop() }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            Text("\(count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary.opacity(0.7))
            Spacer()
        }
        .padding(.top, 6)
    }

    private func card(_ r: Row, compact: Bool) -> some View {
        AgentCardView(machineName: r.machineName, session: r.session,
                      unseen: state.unseen.contains(r.ref.id), status: r.status,
                      inflight: r.inflight, compact: compact) {
            state.selection = r.ref
            NSApp.windows.first(where: { $0.title.isEmpty || $0.title == "Argus" })?.makeKeyAndOrderFront(nil)
        }
    }
}

struct AgentCardView: View {
    let machineName: String
    let session: SessionInfo
    let unseen: Bool
    let status: AgentStatus?
    let inflight: Bool
    let compact: Bool
    let onOpen: () -> Void

    private var tint: SwiftUI.Color {
        if session.state == "waiting" { return Theme.waiting }
        switch status?.label {
        case "needs-decision": return Theme.waiting
        case "look":           return Theme.accent
        case "stuck", "no-progress": return SwiftUI.Color(red: 0.90, green: 0.42, blue: 0.42)
        case "drifting":       return Theme.unseen
        case "milestone":      return Theme.attached
        case "working":        return Theme.running
        default:               return Theme.textTertiary
        }
    }

    var body: some View {
        let style = AgentIndicatorStyle.resolve(state: AgentState(raw: session.state),
                                                attached: session.attached, unseen: unseen)
        VStack(alignment: .leading, spacing: compact ? 3 : 8) {
            HStack(spacing: 8) {
                AgentIndicator(style: style)
                Text(session.name).font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(machineName).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 6)
                if inflight { ProgressView().controlSize(.small).scaleEffect(0.6) }
                if let status { labelChip(status) }
            }
            if !compact, let status, !status.oneLiner.isEmpty {
                Text(status.oneLiner).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !compact, let look = status?.lookAtThis, !look.isEmpty {
                Text(look).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.45), lineWidth: 1))
                    .lineLimit(3)
            }
        }
        .padding(compact ? 9 : 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebarBackground.opacity(compact ? 0.4 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(compact ? 0.15 : 0.4), lineWidth: 1))
        .opacity(compact ? 0.8 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func labelChip(_ s: AgentStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: s.glyph).font(.system(size: 9.5))
            Text(s.display).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
    }
}
