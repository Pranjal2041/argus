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
    private let maxConcurrent = 6

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

/// The command center: a 2-D grid of agent tiles. Most urgent sit top-left and big;
/// as agents matter less they shrink and dim. Three bands by attention (needs-you /
/// active / quiet), each its own grid. Lives as a panel in the main window (⇧⌘O);
/// tap a tile to dive into that session's terminal.
struct CommandCenterView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cc: CommandCenterModel

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
        let needsYou = all.filter { $0.priority <= 1 }
        let active   = all.filter { $0.priority > 1 && $0.priority < 9 }
        let quiet    = all.filter { $0.priority >= 9 }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                glance(needsYou: needsYou.count, active: active.count, quiet: quiet.count)
                if !needsYou.isEmpty { band("Needs you", needsYou, minWidth: 340, height: 96, size: .large) }
                if !active.isEmpty   { band("Active",    active,   minWidth: 240, height: 78, size: .medium) }
                if !quiet.isEmpty    { band("Quiet",     quiet,    minWidth: 165, height: 50, size: .small) }
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

    private func glance(needsYou: Int, active: Int, quiet: Int) -> some View {
        var parts: [String] = []
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if active > 0 { parts.append("\(active) active") }
        if quiet > 0 { parts.append("\(quiet) quiet") }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Command Center").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(parts.isEmpty ? "no sessions" : parts.joined(separator: " · "))
                .font(.system(size: 12.5)).foregroundStyle(needsYou > 0 ? Theme.waiting : Theme.textTertiary)
            Spacer()
        }
    }

    @ViewBuilder
    private func band(_ title: String, _ items: [Tile], minWidth: CGFloat, height: CGFloat,
                      size: AgentTileView.Size) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text("\(items.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary.opacity(0.6))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                ForEach(items) { t in
                    AgentTileView(machineName: t.machineName, session: t.session,
                                  unseen: state.unseen.contains(t.ref.id), status: t.status,
                                  inflight: t.inflight, size: size, minHeight: height) {
                        state.selection = t.ref
                        state.showOverview = false
                    }
                }
            }
        }
    }
}

struct AgentTileView: View {
    enum Size { case large, medium, small }
    let machineName: String
    let session: SessionInfo
    let unseen: Bool
    let status: AgentStatus?
    let inflight: Bool
    let size: Size
    let minHeight: CGFloat
    let onOpen: () -> Void

    private var small: Bool { size == .small }

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
        VStack(alignment: .leading, spacing: small ? 2 : 6) {
            HStack(spacing: 7) {
                AgentIndicator(style: style)
                Text(session.name)
                    .font(.system(size: small ? 12 : (size == .large ? 15 : 13.5), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                if inflight { ProgressView().controlSize(.small).scaleEffect(0.5) }
                else if let s = status { chip(s, tiny: small) }
            }
            if !small, let s = status, !s.oneLiner.isEmpty {
                Text(s.oneLiner).font(.system(size: size == .large ? 12.5 : 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(size == .large ? 3 : 2).fixedSize(horizontal: false, vertical: true)
            }
            if size == .large, let look = status?.lookAtThis, !look.isEmpty {
                Text(look).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.4), lineWidth: 1))
            }
            if !small {
                Text(machineName).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(small ? 9 : 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sidebarBackground.opacity(small ? 0.35 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint.opacity(small ? 0.18 : 0.5), lineWidth: small ? 1 : 1.6))
        .opacity(small ? 0.82 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(status?.oneLiner ?? session.name)
    }

    private func chip(_ s: AgentStatus, tiny: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: s.glyph).font(.system(size: tiny ? 8.5 : 9.5))
            if !tiny { Text(s.display).font(.system(size: 10.5, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, tiny ? 5 : 7).padding(.vertical, tiny ? 2 : 3)
        .background(Capsule().fill(tint.opacity(0.16)))
    }
}
