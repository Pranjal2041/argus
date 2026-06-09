import Foundation
import SwiftUI

/// A host running a broker (one entry in the sidebar).
struct Machine: Identifiable, Hashable {
    let id: String
    var name: String
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
    var id: String { name }

    /// True when the broker reports the agent as blocked on the user.
    var isWaiting: Bool { state == "waiting" }

    enum CodingKeys: String, CodingKey {
        case name, windows, attached, activity, path, state
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
    }
}

struct SessionsResponse: Codable { let sessions: [SessionInfo] }

/// Identifies the selected (machine, session) pair.
struct SessionRef: Identifiable, Hashable {
    let machineID: String
    let session: String
    var id: String { machineID + "/" + session }
}

/// Sessions on one machine grouped by their working directory.
struct FolderGroup: Identifiable {
    let folder: String
    let sessions: [SessionInfo]
    var id: String { folder }
}

@MainActor
final class AppState: ObservableObject {
    @Published var machines: [Machine]
    @Published var sessionsByMachine: [String: [SessionInfo]] = [:]
    @Published var statusByMachine: [String: String] = [:]
    @Published var rttByMachine: [String: Int] = [:]  // round-trip ms per machine
    @Published var selection: SessionRef? {
        didSet {
            guard let ref = selection else { return }
            // Visiting a panel clears its orange "done, unseen" flag → back to green.
            unseen.remove(ref.id)
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
    @Published var searchFocusToken = 0   // bumped to request focusing the filter field
    @Published var isRefreshing = false
    @Published var clock = Date()          // bumped periodically so relative times re-render

    /// User-pinned working directory per session (`ref.id` → absolute path on the
    /// host). Used as the resolve base for a terminal cmd+click when the broker's
    /// reported cwd is stale — notably the Windows ConPTY backend, which can't yet
    /// track `cd`. Persisted across launches.
    @Published var pathOverrides: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "ut.pathOverrides") as? [String: String]) ?? [:]

    /// All sessions flattened across machines (for the command palette).
    var allSessions: [SessionRef] {
        machines.flatMap { m in (sessionsByMachine[m.id] ?? []).map { SessionRef(machineID: m.id, session: $0.name) } }
    }

    /// The machine that owns a session ref (for routing a terminal path-click to
    /// the right host's Files/broker).
    func machine(for ref: SessionRef) -> Machine? { machines.first { $0.id == ref.machineID } }

    /// The session info (incl. its cwd in `.path`) for a ref.
    func session(for ref: SessionRef) -> SessionInfo? {
        (sessionsByMachine[ref.machineID] ?? []).first { $0.name == ref.session }
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
            (sessionsByMachine[m.id] ?? []).filter(\.isWaiting).compactMap { s in
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
        acknowledged.insert(ref.id)
        AttentionNotifier.shared.update(enteredWaiting: [], totalWaiting: waitingCount)
    }

    /// Count of sessions currently waiting on the user (for the header badge).
    var waitingCount: Int { waitingSessions.count }

    private var pollTimer: Timer?
    private var prevState: [String: String] = [:]  // ref.id -> last agent state (for waiting-transition notifications)
    /// ref.ids whose agent just finished a turn (working → idle) while NOT the active
    /// selection — rendered as an ORANGE "done, unseen" dot until you open the pane.
    @Published var unseen: Set<String> = []

    init() {
        // Local (loopback) is fixed; cluster brokers are discovered from the tailnet.
        machines = [
            Machine(id: "local", name: "this mac", isLocal: true,
                    httpBase: "http://127.0.0.1:8722", wsBase: "ws://127.0.0.1:8722"),
        ]
        selection = SessionRef(machineID: "local", session: "ut-demo")
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columns = (columns == .detailOnly) ? .all : .detailOnly
        }
    }

    func focusSearch() { searchFocusToken &+= 1 }

    /// Light periodic poll: re-fetch sessions for known machines and tick the clock so
    /// activity labels age. Every ~12s it ALSO re-discovers, so a broker that comes
    /// online after launch (e.g. a Babel job landing on a fresh node) appears on its
    /// own instead of only on a manual refresh.
    func startAutoRefresh() {
        pollTimer?.invalidate()
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clock = Date()
                for m in self.machines { self.refresh(m) }
                tick += 1
                if tick % 6 == 0 { self.discoverNewBrokers() }
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
                    self.refresh(m)
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
                for m in found { self.refresh(m, group: group) }
                group.notify(queue: .main) { self.isRefreshing = false }
                // Safety: never leave the spinner stuck if a request hangs past timeout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { self.isRefreshing = false }
            }
        }
    }

    func refresh(_ m: Machine, group: DispatchGroup? = nil) {
        guard let url = URL(string: m.httpBase + "/sessions") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let started = Date()
        group?.enter()
        URLSession.shared.dataTask(with: req) { data, _, err in
            var list: [SessionInfo] = []
            if let data, let resp = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
                list = resp.sessions
            }
            let status = err == nil ? "\(list.count) session\(list.count == 1 ? "" : "s")" : "unreachable"
            DispatchQueue.main.async {
                self.sessionsByMachine[m.id] = list.sorted { $0.name < $1.name }
                self.statusByMachine[m.id] = status
                if err == nil { self.rttByMachine[m.id] = Int(Date().timeIntervalSince(started) * 1000) }
                if err == nil {
                    var entered: [(ref: SessionRef, machine: String)] = []
                    for s in list {
                        let ref = SessionRef(machineID: m.id, session: s.name)
                        let prev = self.prevState[ref.id]
                        // Orange "done, unseen": a turn just finished (working → not-working)
                        // while this wasn't the pane you're looking at. Cleared when working
                        // resumes (→ blue) or when you select it (see `selection`).
                        if s.state == "working" {
                            self.unseen.remove(ref.id)
                        } else if prev == "working" && self.selection != ref {
                            self.unseen.insert(ref.id)
                        }
                        if s.state == "waiting" && (prev ?? "idle") != "waiting" {
                            entered.append((ref: ref, machine: m.name))
                        }
                        // Re-arm: once a session leaves "waiting", a future prompt should
                        // surface again, so drop any prior acknowledgement.
                        if s.state != "waiting" { self.acknowledged.remove(ref.id) }
                        self.prevState[ref.id] = s.state
                    }
                    // Prune state for sessions that vanished on this machine (killed/renamed)
                    // so prevState/acknowledged don't grow unbounded or suppress a future banner.
                    let live = Set(list.map { SessionRef(machineID: m.id, session: $0.name).id })
                    let onThisMachine: (String) -> Bool = { $0.hasPrefix(m.id + "/") }
                    self.prevState = self.prevState.filter { !onThisMachine($0.key) || live.contains($0.key) }
                    self.acknowledged = self.acknowledged.filter { !onThisMachine($0) || live.contains($0) }
                    self.unseen = self.unseen.filter { !onThisMachine($0) || live.contains($0) }
                    // Badge from waitingCount (excludes acknowledged) so the optimistic clear
                    // on view/steer is NOT reverted by this very poll.
                    AttentionNotifier.shared.update(enteredWaiting: entered, totalWaiting: self.waitingCount)
                }
                group?.leave()
            }
        }.resume()
    }

    // MARK: Session control (POST /control on the owning broker)

    func createSession(on machineID: String, name: String, dir: String? = nil) {
        var extra: [String: String] = [:]
        if let dir, !dir.isEmpty { extra["dir"] = dir }
        control(machineID, action: "create", session: name, extra: extra) { ok in
            if ok { self.selection = SessionRef(machineID: machineID, session: name) }
            self.refreshAll()
        }
    }

    func killSession(_ ref: SessionRef) {
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

    /// Send input bytes to a session via a one-shot WebSocket (op=2 input,
    /// empty pane → the broker's active pane). Works for any session without a
    /// live terminal pane. Used by steering buttons + snippets.
    func sendInput(text: String, to ref: SessionRef) {
        guard !text.isEmpty, let url = wsURL(for: ref) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        var frame: [UInt8] = [2, 0]            // op=input, paneLen=0
        frame.append(contentsOf: Array(text.utf8))
        task.send(.data(Data(frame))) { _ in
            DispatchQueue.main.async {
                // Answering a prompt should clear it from the inbox/badge at once, then
                // reconverge with the broker (which reports it leaving "waiting" shortly).
                self.acknowledge(ref)
                if let m = self.machines.first(where: { $0.id == ref.machineID }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh(m) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.refresh(m) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    func wsURL(for ref: SessionRef) -> URL? {
        guard let m = machines.first(where: { $0.id == ref.machineID }) else { return nil }
        let enc = ref.session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ref.session
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
        let m = Machine(id: dns, name: probe.name, isLocal: false,
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
private func probeBroker(dns: String) -> (name: String, scheme: String)? {
    for scheme in ["https", "http"] {
        if let name = probeWhoami("\(scheme)://\(dns):8722/whoami") { return (name, scheme) }
    }
    return nil
}

private func probeWhoami(_ urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 2.5
    let sem = DispatchSemaphore(value: 0)
    var name: String?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        guard err == nil, let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["service"] as? String == "universal-tmux-broker" else { return }
        name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "broker"
    }.resume()
    _ = sem.wait(timeout: .now() + 3)
    return name
}
