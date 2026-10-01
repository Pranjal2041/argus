import Foundation
import SwiftUI

/// The phone's view of the fleet. The iPhone joins the tailnet through the
/// Tailscale app; Argus asks one "hub" broker (normally your Mac) for its
/// `/mesh/peers`, exactly as the macOS app asks its local broker, and then
/// talks to every broker directly. Brokers added by hand are probed too.
@MainActor
final class FleetStore: ObservableObject {
    static let hubKey = "argus.hub"
    static let manualKey = "argus.manualBrokers"
    static let backlogKey = "argus.backlog"
    static let showAgentKey = "argus.showAgent"
    static let nicknamesKey = "argus.machineNicknames"
    static let machinesKey = "argus.knownMachines.v1"
    static let hubIDKey = "argus.hubID"

    @Published var hubAddress: String = UserDefaults.standard.string(forKey: FleetStore.hubKey) ?? "" {
        didSet {
            UserDefaults.standard.set(hubAddress, forKey: Self.hubKey)
            guard hubAddress != oldValue else { return }
            // A different hub is a different fleet: forget the remembered one.
            machines = []; allSessions = [:]; commandCenter = [:]; reachable = []; misses = [:]
            hubID = nil
            UserDefaults.standard.removeObject(forKey: Self.hubIDKey)
            Self.saveMachines([])
        }
    }

    var isDemo: Bool { hubAddress == DemoFleet.hubHost }
    /// Hostnames added by hand (never pruned by discovery).
    @Published var manualBrokers: [String] = UserDefaults.standard.stringArray(forKey: FleetStore.manualKey) ?? [] {
        didSet { UserDefaults.standard.set(manualBrokers, forKey: Self.manualKey) }
    }
    /// Remembered across launches, so the fleet shows (and its terminals stay
    /// reachable) even when the hub is offline.
    @Published private(set) var machines: [Machine] = FleetStore.loadMachines()
    /// Identity of the configured hub (your Mac), learned from its /whoami.
    private var hubID = UserDefaults.standard.string(forKey: FleetStore.hubIDKey)
    /// Successful discoveries in a row that did not list a machine.
    private var misses: [String: Int] = [:]
    /// Every session a broker reports (including background and hidden).
    @Published private(set) var allSessions: [String: [SessionInfo]] = [:]
    @Published private(set) var commandCenter: [String: [String: CommandCenterItem]] = [:] // machine → session → item
    @Published private(set) var reachable: Set<String> = []
    @Published private(set) var hubError: String?
    @Published private(set) var lastRefresh: Date?
    @Published var showAgentSessions = UserDefaults.standard.bool(forKey: FleetStore.showAgentKey) {
        didSet { UserDefaults.standard.set(showAgentSessions, forKey: Self.showAgentKey) }
    }
    @Published var showHidden = false
    /// Phone-local display names for machines, keyed by machine id.
    @Published private(set) var nicknames: [String: String] = UserDefaults.standard.dictionary(forKey: FleetStore.nicknamesKey) as? [String: String] ?? [:]
    /// Device-local "set aside" list, keyed "machineID session" (as on Android).
    @Published private(set) var backlog: Set<String> = Set(UserDefaults.standard.stringArray(forKey: FleetStore.backlogKey) ?? [])
    /// Sessions the user has looked at since they started waiting.
    @Published private(set) var acknowledged: Set<String> = []
    /// Optimistic Command Center labels until the Mac republishes (15 s max).
    private var pendingOverride: [String: (label: String, at: Date)] = [:]
    private var previousState: [String: String] = [:]

    /// Fired once per poll with sessions that just entered "waiting".
    var onEnteredWaiting: (([(Machine, SessionInfo)]) -> Void)?
    /// Called every tick after sessions refresh (feature stores hang off this).
    var onTick: ((Int) -> Void)?

    private var loop: Task<Void, Never>?
    private(set) var tick = 0

    var isConfigured: Bool { !hubAddress.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The Mac: the durable sync host for Notes/Todos/Workflows, the Journal
    /// inbox, Weekly Progress, the Lab mirror and Unattended Mode.
    var syncHost: Machine? {
        machines.first { $0.isHub && $0.os == "darwin" } ?? machines.first { $0.os == "darwin" }
    }

    func machine(id: String) -> Machine? { machines.first { $0.id == id } }

    /// Match a broker-reported machine name (`ut-host`, `host.domain`, `host`).
    func machine(named raw: String) -> Machine? {
        let want = Self.normalizedHost(raw)
        guard !want.isEmpty else { return nil }
        return machines.first {
            Self.normalizedHost($0.brokerName) == want || Self.normalizedHost($0.name) == want
                || Self.normalizedHost($0.httpBase.host ?? "") == want
        }
    }

    nonisolated static func normalizedHost(_ s: String) -> String {
        var h = s.lowercased().split(separator: ".").first.map(String.init) ?? ""
        if h.hasPrefix("ut-") { h.removeFirst(3) }
        return h
    }

    func session(on m: Machine, named name: String) -> SessionInfo? {
        allSessions[m.id]?.first { $0.name == name }
    }

    /// Sessions shown in lists, honoring the agent/hidden toggles.
    func sessions(on m: Machine) -> [SessionInfo] {
        (allSessions[m.id] ?? []).filter { (showAgentSessions || !$0.agent) && (showHidden || !$0.hidden) }
    }

    var hasHiddenSessions: Bool { allSessions.values.contains { $0.contains(where: \.hidden) } }

    static func key(_ m: Machine, _ s: SessionInfo) -> String { m.id + " " + s.name }

    // MARK: Loop

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.step()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    func refreshNow() async {
        await discover()
        await refreshSessions()
        lastRefresh = Date()
    }

    /// Discovery every ~15 s (5 ticks), sessions and Command Center every tick.
    private func step() async {
        guard isConfigured else { return }
        if tick % 5 == 0 || machines.isEmpty { await discover() }
        await refreshSessions()
        lastRefresh = Date()
        onTick?(tick)
        tick += 1
    }

    // MARK: Discovery

    /// Ask the hub for its peers; if it's offline, ask any other known broker —
    /// every broker serves /mesh/peers. Remembered machines are only pruned
    /// after three successful scans that don't list them (as on Android).
    private func discover() async {
        guard isConfigured else { return }
        var found: [Machine] = []
        var source: Machine?
        if let hub = try? await resolveHub(hubAddress) {
            hubID = hub.id
            UserDefaults.standard.set(hub.id, forKey: Self.hubIDKey)
            found = [hub]
            if let peers = try? await peerMachines(of: hub) { found += peers; source = hub }
        }
        if source == nil {
            let others = machines.filter { $0.id != hubID }
                .sorted { reachable.contains($0.id) && !reachable.contains($1.id) }
            for m in others {
                if let peers = try? await peerMachines(of: m) { found = [m] + peers; source = m; break }
            }
        }
        for host in manualBrokers where !found.contains(where: { $0.httpBase.host?.lowercased() == host.lowercased() }) {
            if var m = try? await resolveHub(host) {
                m.isHub = false
                found.append(m)
            }
        }
        // De-dupe by identity; the hub keeps its role however it was found.
        var unique: [Machine] = []
        for var m in found where !unique.contains(where: { $0.id == m.id }) {
            m.isHub = m.id == hubID
            if m.brokerName.isEmpty { m.brokerName = m.name }
            if let nick = nicknames[m.id], !nick.isEmpty { m.name = nick }
            unique.append(m)
        }
        if let source {
            hubError = source.id == hubID ? nil
                : "Your Mac is offline — machines found through \(source.name). Terminals work as usual; summaries stop updating, and Notes sync and Weekly Progress wait for it."
            for m in unique { misses[m.id] = 0 }
            let manualIDs = Set(unique.filter { m in manualBrokers.contains { $0.lowercased() == m.httpBase.host?.lowercased() } }.map(\.id))
            for old in machines where !unique.contains(where: { $0.id == old.id }) {
                misses[old.id, default: 0] += 1
                if misses[old.id, default: 0] < 3 || reachable.contains(old.id) || manualIDs.contains(old.id) { unique.append(old) }
            }
        } else {
            hubError = machines.isEmpty
                ? "Can't reach your Mac at \(hubAddress). Is Tailscale connected on this iPhone?"
                : "Can't reach your Mac or the machines' list right now. Showing the machines Argus remembers."
            for old in machines where !unique.contains(where: { $0.id == old.id }) { unique.append(old) }
        }
        machines = unique.sorted { ($0.isHub ? 0 : 1, $0.name.lowercased()) < ($1.isHub ? 0 : 1, $1.name.lowercased()) }
        Self.saveMachines(machines)
    }

    private func peerMachines(of m: Machine) async throws -> [Machine] {
        try await BrokerHTTP.get(m.httpBase, "mesh/peers", as: PeersResponse.self).peers.compactMap(Machine.from)
    }

    private static func loadMachines() -> [Machine] {
        guard let d = UserDefaults.standard.data(forKey: machinesKey),
              let m = try? JSONDecoder().decode([Machine].self, from: d) else { return [] }
        return m
    }

    private static func saveMachines(_ m: [Machine]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: machinesKey) }
    }

    private struct PeersResponse: Decodable { let peers: [MeshPeer] }

    /// A hub address is a tailnet name or IP (optionally with a port). Native
    /// brokers (a Mac) serve http; tsnet brokers serve https by MagicDNS name.
    func resolveHub(_ raw: String) async throws -> Machine {
        var host = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["http://", "https://"] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let colon = host.lastIndex(of: ":"), !host.contains("]"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        var lastError: Error = BrokerError.notABroker
        for scheme in ["http", "https"] {
            guard let base = URL(string: "\(scheme)://\(host):\(brokerPort)"),
                  let ws = URL(string: "\(scheme == "https" ? "wss" : "ws")://\(host):\(brokerPort)") else { continue }
            do {
                let who = try await BrokerHTTP.get(base, "whoami", as: Whoami.self)
                guard who.isBroker else { throw BrokerError.notABroker }
                return Machine(id: Machine.identity(host: who.host, socket: who.socket) ?? "hub:" + host.lowercased(),
                               name: who.name ?? host, brokerName: who.name ?? host, os: who.os ?? "",
                               httpBase: base, wsBase: ws, isHub: true)
            } catch { lastError = error }
        }
        throw lastError
    }

    func setNickname(_ name: String, for m: Machine) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        nicknames[m.id] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(nicknames, forKey: Self.nicknamesKey)
        if let i = machines.firstIndex(where: { $0.id == m.id }) {
            machines[i].name = trimmed.isEmpty ? machines[i].brokerName : trimmed
        }
    }

    func addManualBroker(_ host: String) async throws {
        let h = host.trimmingCharacters(in: .whitespaces)
        _ = try await resolveHub(h)
        if !manualBrokers.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) { manualBrokers.append(h) }
        await refreshNow()
    }

    func removeManualBroker(_ host: String) {
        manualBrokers.removeAll { $0.caseInsensitiveCompare(host) == .orderedSame }
        machines.removeAll { $0.id == "manual:" + host.lowercased() }
    }

    // MARK: Sessions + Command Center

    private struct SessionsResponse: Decodable { let sessions: [SessionInfo] }
    private struct CCResponse: Decodable { let items: [CommandCenterItem]? }

    private func refreshSessions() async {
        let snapshot = machines
        var entered: [(Machine, SessionInfo)] = []
        await withTaskGroup(of: (String, [SessionInfo]?, [CommandCenterItem]?).self) { group in
            for m in snapshot {
                group.addTask {
                    let s = try? await BrokerHTTP.get(m.httpBase, "sessions", as: SessionsResponse.self).sessions
                    let cc = try? await BrokerHTTP.get(m.httpBase, "ccstatus", as: CCResponse.self).items
                    return (m.id, s, cc)
                }
            }
            for await (id, s, cc) in group {
                guard let m = snapshot.first(where: { $0.id == id }) else { continue }
                if let s {
                    let sorted = s.sorted { $0.name.lowercased() < $1.name.lowercased() }
                    allSessions[id] = sorted
                    reachable.insert(id)
                    for session in sorted where session.isForeground {
                        let key = Self.key(m, session)
                        let state = session.state ?? ""
                        if state == "waiting", previousState[key] != "waiting" { entered.append((m, session)) }
                        if state != "waiting" { acknowledged.remove(key) }   // re-arm
                        previousState[key] = state
                    }
                } else {
                    reachable.remove(id)
                }
                if let cc { commandCenter[id] = Dictionary(cc.map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a }) }
            }
        }
        if !entered.isEmpty { onEnteredWaiting?(entered) }
    }

    // MARK: Command Center rows

    struct Card: Identifiable, Hashable {
        let machine: Machine
        let session: SessionInfo
        let item: CommandCenterItem?
        let label: String?
        let backlogged: Bool
        var id: String { machine.id + "/" + session.id }
        var status: AttentionSection { .of(label: label, state: session.state) }
    }

    var cards: [Card] {
        machines.flatMap { m in
            (allSessions[m.id] ?? []).filter(\.isForeground).map { s in
                let key = Self.key(m, s)
                let item = commandCenter[m.id]?[s.name]
                var label = item?.label
                if let p = pendingOverride[key] {
                    if p.label == label || Date().timeIntervalSince(p.at) > 15 { pendingOverride[key] = nil } else { label = p.label }
                }
                return Card(machine: m, session: s, item: item, label: label, backlogged: backlog.contains(key))
            }
        }
        .sorted { $0.session.name.lowercased() < $1.session.name.lowercased() }
    }

    /// Sessions waiting on you that you haven't looked at yet.
    var needsAttention: [(Machine, SessionInfo)] {
        machines.flatMap { m in
            sessions(on: m).filter { $0.state == "waiting" && !$0.hidden && !acknowledged.contains(Self.key(m, $0)) }.map { (m, $0) }
        }
    }

    func acknowledge(_ m: Machine, _ s: SessionInfo) { acknowledged.insert(Self.key(m, s)) }

    func toggleBacklog(_ m: Machine, _ s: SessionInfo) {
        let key = Self.key(m, s)
        if backlog.contains(key) { backlog.remove(key) } else { backlog.insert(key) }
        UserDefaults.standard.set(Array(backlog), forKey: Self.backlogKey)
    }

    // MARK: Actions

    func createSession(on m: Machine, name: String, dir: String? = nil) async throws {
        var q: [URLQueryItem] = [.init(name: "action", value: "create"), .init(name: "session", value: name),
                                 .init(name: "kind", value: "visible")]
        if let dir, !dir.isEmpty { q.append(.init(name: "dir", value: dir)) }
        try await BrokerHTTP.post(m.httpBase, "control", query: q)
        await refreshNow()
    }

    func killSession(_ s: SessionInfo, on m: Machine) async throws {
        try await BrokerHTTP.post(m.httpBase, "control", query: [
            .init(name: "action", value: "kill"), .init(name: "session", value: s.name),
        ])
        await refreshNow()
    }

    func renameSession(_ s: SessionInfo, on m: Machine, to: String) async throws {
        try await BrokerHTTP.post(m.httpBase, "control", query: [
            .init(name: "action", value: "rename"), .init(name: "session", value: s.name), .init(name: "to", value: to),
        ])
        await refreshNow()
    }

    func setHidden(_ s: SessionInfo, on m: Machine, hidden: Bool) async throws {
        try await BrokerHTTP.post(m.httpBase, "hidden", query: [
            .init(name: "session", value: s.name), .init(name: "hidden", value: hidden ? "true" : "false"),
        ])
        await refreshNow()
    }

    /// Type text into a session (Enter appended unless `enter` is false).
    func send(_ text: String, to s: SessionInfo, on m: Machine, enter: Bool = true) async throws {
        try await BrokerHTTP.post(m.httpBase, "send", query: [
            .init(name: "session", value: s.name), .init(name: "enter", value: enter ? "1" : "0"),
        ], body: Data(text.utf8))
    }

    /// Manual Command Center status; the Mac applies and republishes it.
    func setStatus(_ label: String, for s: SessionInfo, on m: Machine) async throws {
        pendingOverride[Self.key(m, s)] = (label, Date())
        objectWillChange.send()
        try await BrokerHTTP.post(m.httpBase, "ccoverride", query: [
            .init(name: "session", value: s.name), .init(name: "label", value: label),
        ])
    }

    static let statusLabels: [(label: String, title: String)] = [
        ("working", "Working"), ("idle", "Idle"), ("needs-decision", "Needs you"), ("stuck", "Stuck"),
        ("milestone", "Milestone"), ("look", "Worth a look"), ("drifting", "Drifting"),
    ]
}
