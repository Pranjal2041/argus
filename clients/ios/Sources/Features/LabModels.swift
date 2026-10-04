import Foundation

// Argus Lab wire and presentation models (internal/labsvc, cmd/ut-broker /lab/*).
// Go encodes nil slices as `null` and omits empty strings, and event `data` is a
// free-form map, so every field decodes leniently: a malformed or missing field
// degrades to its default instead of failing the whole answer (as on Android).

// MARK: Lenient decoding

extension KeyedDecodingContainer {
    /// A value of the expected type, or nil when missing, null, or mistyped.
    func lab<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// A non-empty string (Android's `stringOrNull`).
    func labString(_ key: Key) -> String? {
        guard let s = lab(String.self, key), !s.isEmpty, s != "null" else { return nil }
        return s
    }

    /// An integer that may arrive as a JSON float (event data is `map[string]any`).
    func labInt(_ key: Key) -> Int? {
        if let i = lab(Int.self, key) { return i }
        if let d = lab(Double.self, key), d.isFinite { return Int(d) }
        return nil
    }

    /// An array whose individual elements may be malformed; bad ones are dropped.
    func labArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (lab([LabLossy<T>].self, key) ?? []).compactMap(\.value)
    }

    func labStrings(_ key: Key) -> [String] {
        labArray(String.self, key).filter { !$0.isEmpty }
    }
}

struct LabLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private struct LabKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private typealias LabFields = KeyedDecodingContainer<LabKey>

private extension Decoder {
    func labFields() throws -> LabFields { try container(keyedBy: LabKey.self) }
}

private extension LabFields {
    func s(_ k: String) -> String { labString(LabKey(k)) ?? "" }
    func o(_ k: String) -> String? { labString(LabKey(k)) }
    func b(_ k: String) -> Bool { lab(Bool.self, LabKey(k)) ?? false }
    func i(_ k: String) -> Int? { labInt(LabKey(k)) }
    func strings(_ k: String) -> [String] { labStrings(LabKey(k)) }
    func array<T: Decodable>(_ k: String, _ t: T.Type) -> [T] { labArray(t, LabKey(k)) }
    func obj<T: Decodable>(_ k: String, _ t: T.Type) -> T? { lab(t, LabKey(k)) }
}

// MARK: Wire models

struct LabSetMeta: Decodable, Hashable {
    var id: String
    var project: String
    var machine: String
    var store: String?
    var cwd: String
    var created: String

    init(id: String, project: String, machine: String, store: String? = nil, cwd: String, created: String) {
        self.id = id; self.project = project; self.machine = machine; self.store = store; self.cwd = cwd; self.created = created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        id = c.s("id"); project = c.s("project"); machine = c.s("machine")
        store = c.o("store"); cwd = c.s("cwd"); created = c.s("created")
    }
}

struct LabFileRef: Decodable, Hashable {
    var path: String
    var sha256: String?
    init(path: String, sha256: String? = nil) { self.path = path; self.sha256 = sha256 }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        path = c.s("path"); sha256 = c.o("sha256")
    }
    /// The run-dir copy the wrapper stores for a parameter file.
    var storedName: String { "files/" + (path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path) }
}

struct LabSnapshotInfo: Decodable, Hashable {
    var baseSha: String?
    var noGit = false
    var patchBytes: Int64 = 0
    var archived = 0
    init(baseSha: String? = nil, noGit: Bool = false, patchBytes: Int64 = 0) {
        self.baseSha = baseSha; self.noGit = noGit; self.patchBytes = patchBytes
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        baseSha = c.o("baseSha"); noGit = c.b("noGit")
        patchBytes = Int64(c.i("patchBytes") ?? 0); archived = c.i("archived") ?? 0
    }
}

struct LabEnvFacts: Decodable, Hashable {
    var os: String?
    var arch: String?
    var python: String?
    var gpus: String?
    init(os: String? = nil, arch: String? = nil, python: String? = nil, gpus: String? = nil) {
        self.os = os; self.arch = arch; self.python = python; self.gpus = gpus
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        os = c.o("os"); arch = c.o("arch"); python = c.o("python"); gpus = c.o("gpus")
    }
    /// "Python 3.11 · GPU 0: … · linux · amd64", or nil when nothing was captured.
    static func summary(_ env: LabEnvFacts?) -> String? {
        let parts = [env?.python, env?.gpus, env?.os, env?.arch].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The free-form `data` of an event: a proposal/run-start envelope, a run-end,
/// or a curation target.
struct LabEventData: Decodable, Hashable {
    var target: String?
    var machine: String?
    var argv: [String] = []
    var cwd: String?
    var tier: String?
    var group: String?
    var tmuxSession: String?
    var bind: String?
    var snapshot: LabSnapshotInfo?
    var params: [LabFileRef] = []
    var dataFiles: [LabFileRef] = []
    var env: LabEnvFacts?
    var exitCode: Int?
    var durationSec: Int?
    var wandb: [String] = []
    var drift: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        target = c.o("target"); machine = c.o("machine"); argv = c.strings("argv"); cwd = c.o("cwd")
        tier = c.o("tier"); group = c.o("group"); tmuxSession = c.o("tmuxSession"); bind = c.o("bind")
        snapshot = c.obj("snapshot", LabSnapshotInfo.self)
        params = c.array("params", LabFileRef.self); dataFiles = c.array("dataFiles", LabFileRef.self)
        env = c.obj("env", LabEnvFacts.self)
        exitCode = c.i("exit"); durationSec = c.i("durationSec")
        wandb = c.strings("wandb"); drift = c.strings("drift")
    }
}

struct LabEvent: Decodable, Hashable, Identifiable {
    var id: String
    var time: String
    var author: String
    var kind: String
    var text: String?
    var data: LabEventData?

    init(id: String, time: String, author: String, kind: String, text: String? = nil, data: LabEventData? = nil) {
        self.id = id; self.time = time; self.author = author; self.kind = kind; self.text = text; self.data = data
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        id = c.s("id"); time = c.s("time"); author = c.s("author"); kind = c.s("kind")
        text = c.o("text"); data = c.obj("data", LabEventData.self)
    }
}

struct LabRunSummary: Decodable, Hashable, Identifiable {
    var id: String
    var machine: String?
    var group: String?
    var tier: String?
    var status: String
    var started: String?
    var stoppedAt: String?
    var stopReason: String?
    var latest: String?
    var latestAt: String?
    /// -1 when the run has no mechanical ending (Go always sends it; old brokers may not).
    var exitCode: Int = -1
    var archived = false

    init(id: String, machine: String? = nil, group: String? = nil, tier: String? = nil, status: String,
         started: String? = nil, stoppedAt: String? = nil, stopReason: String? = nil,
         latest: String? = nil, latestAt: String? = nil, exitCode: Int = -1, archived: Bool = false) {
        self.id = id; self.machine = machine; self.group = group; self.tier = tier; self.status = status
        self.started = started; self.stoppedAt = stoppedAt; self.stopReason = stopReason
        self.latest = latest; self.latestAt = latestAt; self.exitCode = exitCode; self.archived = archived
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        id = c.s("id"); machine = c.o("machine"); group = c.o("group"); tier = c.o("tier"); status = c.s("status")
        started = c.o("started"); stoppedAt = c.o("stoppedAt"); stopReason = c.o("stopReason")
        latest = c.o("latest"); latestAt = c.o("latestAt")
        exitCode = c.i("exitCode") ?? -1; archived = c.b("archived")
    }

    /// Lifecycle phase, independent from the archive view flag.
    var phase: LabPhase { LabPhase.of(status) }

    /// The newest moment anything happened to this run.
    func activityAt(fallback: String = "") -> String {
        [latestAt, stoppedAt, started, fallback.isEmpty ? nil : fallback].compactMap { $0 }.max() ?? ""
    }

    /// A field-by-field fingerprint: when it changes, a loaded detail is stale.
    var fingerprint: String {
        [status, started ?? "", stoppedAt ?? "", stopReason ?? "", latest ?? "", latestAt ?? "",
         String(exitCode), String(archived)].joined(separator: "\u{0}")
    }

    /// R12 → 12, for ordering runs that share an activity time.
    var number: Int { Int(id.drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0 }
}

enum LabPhase: String, CaseIterable {
    case needs, approved, running, failed, stopped, rejected, finished, recorded

    static func of(_ rawStatus: String) -> LabPhase {
        let status = rawStatus.lowercased()
        if status.contains("awaiting approval") || status.hasPrefix("proposed") { return .needs }
        if status.hasPrefix("approved") { return .approved }
        if status.hasPrefix("running") { return .running }
        if status.hasPrefix("failed") { return .failed }
        if status.hasPrefix("stopped") { return .stopped }
        if status.hasPrefix("denied") { return .rejected }
        if status.hasPrefix("done") { return .finished }
        return .recorded
    }

    /// Phases that still change on their own; their details auto-refresh.
    var isLive: Bool { self == .running || self == .needs || self == .approved }
    var isActive: Bool { self == .running || self == .needs || self == .approved }
}

struct LabBrief: Decodable, Hashable {
    var set: LabSetMeta
    var policy: String = "full-only"
    var notes: [LabEvent] = []
    var setEvents: [LabEvent] = []
    var runs: [LabRunSummary] = []
    var archived = false

    init(set: LabSetMeta, policy: String = "full-only", notes: [LabEvent] = [], setEvents: [LabEvent] = [],
         runs: [LabRunSummary] = [], archived: Bool = false) {
        self.set = set; self.policy = policy; self.notes = notes; self.setEvents = setEvents
        self.runs = runs; self.archived = archived
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        set = c.obj("set", LabSetMeta.self) ?? LabSetMeta(id: "", project: "", machine: "", cwd: "", created: "")
        policy = c.o("policy") ?? "full-only"
        notes = c.array("notes", LabEvent.self); setEvents = c.array("setEvents", LabEvent.self)
        runs = c.array("runs", LabRunSummary.self); archived = c.b("archived")
    }

    /// The newest activity of any run, else the set's creation.
    var activityAt: String { runs.map { $0.activityAt(fallback: set.created) }.max() ?? set.created }
}

struct LabKeyInfo: Decodable, Hashable {
    var key: String
    var set: String?
    var project: String
    var machine: String
    var store: String?
    var cwd: String
    var session: String?
    var status: String
    var created: String

    init(key: String, set: String? = nil, project: String, machine: String, store: String? = nil, cwd: String,
         session: String? = nil, status: String, created: String) {
        self.key = key; self.set = set; self.project = project; self.machine = machine; self.store = store
        self.cwd = cwd; self.session = session; self.status = status; self.created = created
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        key = c.s("key"); set = c.o("set"); project = c.s("project"); machine = c.s("machine"); store = c.o("store")
        cwd = c.s("cwd"); session = c.o("session"); status = c.s("status"); created = c.s("created")
    }
}

struct LabProposal: Decodable, Hashable {
    var set: String
    var run: String
    var project: String
    var machine: String
    var intent: String
    var tier: String?
    var group: String?
    var argv: [String] = []
    var cwd: String?
    var created: String

    init(set: String, run: String, project: String, machine: String, intent: String, tier: String? = nil,
         group: String? = nil, argv: [String] = [], cwd: String? = nil, created: String) {
        self.set = set; self.run = run; self.project = project; self.machine = machine; self.intent = intent
        self.tier = tier; self.group = group; self.argv = argv; self.cwd = cwd; self.created = created
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        set = c.s("set"); run = c.s("run"); project = c.s("project"); machine = c.s("machine"); intent = c.s("intent")
        tier = c.o("tier"); group = c.o("group"); argv = c.strings("argv"); cwd = c.o("cwd"); created = c.s("created")
    }
    var id: String { "\(set)/\(run)" }
}

/// A scope-level human note (global, machine, project) from `/lab/notes`.
struct LabHubNote: Decodable, Hashable {
    var scope: String
    var project: String?
    var id: String
    var time: String
    var author: String
    var text: String
    var hidden = false

    init(scope: String, project: String? = nil, id: String, time: String, author: String, text: String, hidden: Bool = false) {
        self.scope = scope; self.project = project; self.id = id; self.time = time
        self.author = author; self.text = text; self.hidden = hidden
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        scope = c.s("scope"); project = c.o("project"); id = c.s("id"); time = c.s("time")
        author = c.s("author"); text = c.s("text"); hidden = c.b("hidden")
    }
}

struct LabRunFileInfo: Decodable, Hashable, Identifiable {
    var name: String
    var size: Int64
    var id: String { name }
    init(name: String, size: Int64) { self.name = name; self.size = size }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        name = c.s("name"); size = Int64(c.i("size") ?? 0)
    }
}

struct LabMirrored: Decodable, Hashable {
    var machine: String
    var set: String
    var updated: String
    var brief: LabBrief?

    init(machine: String, set: String, updated: String, brief: LabBrief) {
        self.machine = machine; self.set = set; self.updated = updated; self.brief = brief
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.labFields()
        machine = c.s("machine"); set = c.s("set"); updated = c.s("updated"); brief = c.obj("brief", LabBrief.self)
    }
}

/// Response envelopes. Every list is optional: Go sends `null` for none.
struct LabNotesResponse: Decodable { let store: String?; let notes: [LabLossy<LabHubNote>]? }
struct LabSetsResponse: Decodable { let sets: [LabLossy<LabSetMeta>]? }
struct LabKeysResponse: Decodable { let keys: [LabLossy<LabKeyInfo>]? }
struct LabProposalsResponse: Decodable { let proposals: [LabLossy<LabProposal>]? }
struct LabEventsResponse: Decodable { let events: [LabLossy<LabEvent>]? }
struct LabFilesResponse: Decodable { let files: [LabLossy<LabRunFileInfo>]? }
struct LabMirrorResponse: Decodable { let mirror: [LabLossy<LabMirrored>]? }
/// `/automation/unattended`; `updatedAt` is Unix milliseconds.
struct LabUnattendedState: Decodable { let enabled: Bool; let updatedAt: Int64? }

// MARK: Aggregation models

extension Machine {
    /// Android's `Broker.id` (the broker's host), so attention ids and notification
    /// identities match across clients.
    var labBrokerID: String { httpBase.host ?? id }
}

/// One reachable broker's complete Lab answer. `notes` is nil only when the
/// identity endpoint was unreachable; an empty list is a valid answer.
struct LabBrokerSnapshot {
    let broker: Machine
    let reportedStoreID: String?
    let briefs: [LabBrief]
    let keys: [LabKeyInfo]
    let proposals: [LabProposal]
    let notes: [LabHubNote]?

    var answered: Bool { notes != nil || !briefs.isEmpty || !keys.isEmpty || !proposals.isEmpty }
}

struct LabSetCard: Identifiable, Hashable {
    let storeID: String
    /// The broker data actions for this set go to.
    let broker: Machine
    let machineName: String
    let brief: LabBrief
    var offline = false
    var mirroredAt = ""
    var id: String { "\(broker.labBrokerID)/\(brief.set.id)" }
}

struct LabPendingKey: Identifiable, Hashable {
    let storeID: String
    let broker: Machine
    let machineName: String
    let key: LabKeyInfo
    var id: String { "\(broker.labBrokerID)/\(key.key)" }
}

struct LabPendingRun: Identifiable, Hashable {
    let storeID: String
    let broker: Machine
    let machineName: String
    let proposal: LabProposal
    var id: String { "\(broker.labBrokerID)/\(proposal.id)" }
}

struct LabNotesGroup: Identifiable, Hashable {
    let storeID: String
    let broker: Machine
    let machineName: String
    let notes: [LabHubNote]
    var id: String { broker.labBrokerID }
}

struct LabAggregate {
    var sets: [LabSetCard] = []
    var pendingKeys: [LabPendingKey] = []
    var pendingRuns: [LabPendingRun] = []
    var notes: [LabNotesGroup] = []
    /// card id → active key (full secret; only an 8-char prefix is ever sent).
    var activeKeyBySet: [String: String] = [:]
    var attention: [LabAttentionItem] = []
}

/// Shared-store reduction, a line-for-line port of Android's `LabAggregator`.
/// Sets, keys and proposals belong to a Lab store — not to each broker that
/// happens to expose it — so every NFS-shared record appears exactly once.
enum LabAggregator {
    static func aggregate(_ snapshots: [LabBrokerSnapshot], mirrored: [LabMirrored] = [],
                          mirrorBroker: Machine? = nil) -> LabAggregate {
        let ordered = snapshots.sorted {
            ($0.broker.name.lowercased(), $0.broker.labBrokerID) < ($1.broker.name.lowercased(), $1.broker.labBrokerID)
        }
        var groups: [String: [LabBrokerSnapshot]] = [:]
        for s in ordered { groups[storeKey(s.broker, reported: s.reportedStoreID), default: []].append(s) }

        var cards = OrderedMap<LabSetCard>()
        var pendingKeys = OrderedMap<LabPendingKey>()
        var pendingRuns = OrderedMap<LabPendingRun>()
        var activeKeys = OrderedMap<LabKeyInfo>()
        var noteGroups: [LabNotesGroup] = []

        for storeID in groups.keys.sorted() {
            guard let peers = groups[storeID], let fallback = peers.first else { continue }
            var briefs = OrderedMap<LabBrief>()
            var keys = OrderedMap<LabKeyInfo>()
            var proposals = OrderedMap<LabProposal>()
            for peer in peers {
                for candidate in peer.briefs {
                    if let current = briefs[candidate.set.id], !prefer(candidate, over: current) { continue }
                    briefs[candidate.set.id] = candidate
                }
                for candidate in peer.keys {
                    if let current = keys[candidate.key], keyRank(candidate.status) <= keyRank(current.status) { continue }
                    keys[candidate.key] = candidate
                }
                for p in peer.proposals where proposals[p.id] == nil { proposals[p.id] = p }
                if let notes = peer.notes {
                    noteGroups.append(LabNotesGroup(storeID: storeID, broker: peer.broker, machineName: peer.broker.name, notes: notes))
                }
            }
            func route(_ owner: String) -> Machine { (peers.first { machineMatches($0.broker, owner) } ?? fallback).broker }

            for brief in briefs.values {
                let b = route(brief.set.machine)
                cards["\(storeID)/set/\(brief.set.id)"] = LabSetCard(storeID: storeID, broker: b, machineName: b.name, brief: brief)
            }
            for key in keys.values {
                let b = route(key.machine)
                if key.status == "pending" {
                    pendingKeys["\(storeID)/key/\(key.key)"] = LabPendingKey(storeID: storeID, broker: b, machineName: b.name, key: key)
                } else if key.status == "active", let set = key.set {
                    activeKeys["\(storeID)/set/\(set)"] = key
                }
            }
            for p in proposals.values {
                let b = route(p.machine)
                pendingRuns["\(storeID)/proposal/\(p.id)"] = LabPendingRun(storeID: storeID, broker: b, machineName: b.name, proposal: p)
            }
        }

        // A Mac mirror may itself hold the same NFS-backed set under more than
        // one peer directory. Embedded home machine + set id is durable.
        let onlineOwners = Set(cards.values.map { normalizeMachine($0.brief.set.machine) })
        var mirrorByRecord = OrderedMap<(LabMirrored, LabBrief)>()
        for item in mirrored {
            guard let brief = item.brief else { continue }
            let owner = brief.set.machine.isEmpty ? item.machine : brief.set.machine
            if onlineOwners.contains(normalizeMachine(owner)) { continue }
            let record = "\(normalizeMachine(owner))/set/\(brief.set.id)"
            if let current = mirrorByRecord[record], item.updated <= current.0.updated { continue }
            mirrorByRecord[record] = (item, brief)
        }
        if let mirrorBroker {
            for (item, brief) in mirrorByRecord.values {
                let owner = brief.set.machine.isEmpty ? item.machine : brief.set.machine
                let norm = normalizeMachine(owner)
                cards["mirror/\(norm)/set/\(brief.set.id)"] = LabSetCard(
                    storeID: "mirror/\(norm)", broker: mirrorBroker, machineName: owner, brief: brief,
                    offline: true, mirroredAt: item.updated)
            }
        }

        var out = LabAggregate()
        out.sets = cards.values.sorted { a, b in
            if a.brief.set.project != b.brief.set.project { return a.brief.set.project < b.brief.set.project }
            if a.brief.activityAt != b.brief.activityAt { return a.brief.activityAt > b.brief.activityAt }
            return a.id > b.id
        }
        for (record, key) in activeKeys.pairs { if let card = cards[record] { out.activeKeyBySet[card.id] = key.key } }
        out.pendingKeys = pendingKeys.values.sorted { ($0.key.created, $0.id) > ($1.key.created, $1.id) }
        out.pendingRuns = pendingRuns.values.sorted { ($0.proposal.created, $0.id) > ($1.proposal.created, $1.id) }
        out.notes = noteGroups.sorted { ($0.machineName.lowercased(), $0.id) < ($1.machineName.lowercased(), $1.id) }

        var attention: [(created: String, item: LabAttentionItem)] = []
        for k in out.pendingKeys {
            attention.append((k.key.created, LabAttentionItem(
                kind: .key, targetID: k.id, reference: "ACCESS", project: k.key.project, machineName: k.machineName,
                summary: "Approve agent access to a new isolated experiment set.", created: LabTime.date(k.key.created))))
        }
        for r in out.pendingRuns {
            let intent = r.proposal.intent.trimmingCharacters(in: .whitespacesAndNewlines)
            attention.append((r.proposal.created, LabAttentionItem(
                kind: .proposal, targetID: r.id, reference: r.proposal.run, project: r.proposal.project,
                machineName: r.machineName, summary: intent.isEmpty ? "Review this experiment before it starts." : r.proposal.intent,
                created: LabTime.date(r.proposal.created))))
        }
        out.attention = attention.sorted { ($0.created, $0.item.id) > ($1.created, $1.item.id) }.map(\.item)
        return out
    }

    static func storeKey(_ broker: Machine, reported: String?) -> String {
        if [broker.name, broker.httpBase.host ?? ""].contains(where: isBabelName) { return "shared:babel" }
        let clean = (reported ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "machine:\(broker.labBrokerID)" : "store:\(clean)"
    }

    private static func isBabelName(_ raw: String) -> Bool {
        let first = raw.lowercased().split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.hasPrefix("babel-") || first.hasPrefix("ut-babel-")
    }

    static func normalizeMachine(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if s.hasPrefix("ut-") { s.removeFirst(3) }
        return s
    }

    static func machineMatches(_ broker: Machine, _ owner: String) -> Bool {
        let target = normalizeMachine(owner)
        return [broker.name, broker.httpBase.host ?? ""].contains { normalizeMachine($0) == target }
    }

    private static func keyRank(_ status: String) -> Int { status == "pending" ? 0 : 1 }

    /// The fuller replica of the same set wins (NFS caches can lag per node).
    private static func prefer(_ candidate: LabBrief, over current: LabBrief) -> Bool {
        if candidate.runs.count != current.runs.count { return candidate.runs.count > current.runs.count }
        let a = candidate.runs.compactMap(\.started).max() ?? "", b = current.runs.compactMap(\.started).max() ?? ""
        if a != b { return a > b }
        return candidate.notes.count + candidate.setEvents.count > current.notes.count + current.setEvents.count
    }
}

/// Insertion-ordered string-keyed map (Kotlin's `linkedMapOf`).
struct OrderedMap<V> {
    private(set) var keys: [String] = []
    private var storage: [String: V] = [:]
    subscript(key: String) -> V? {
        get { storage[key] }
        set {
            if storage[key] == nil, newValue != nil { keys.append(key) }
            if newValue == nil { keys.removeAll { $0 == key } }
            storage[key] = newValue
        }
    }
    var values: [V] { keys.compactMap { storage[$0] } }
    var pairs: [(String, V)] { keys.compactMap { k in storage[k].map { (k, $0) } } }
}

// MARK: Run detail

struct LabRunDetail: Hashable {
    var events: [LabEvent] = []
    var files: [LabRunFileInfo] = []
    var textByName: [String: String] = [:]

    /// What was approved or started: the run-start envelope, else the proposal's.
    var envelope: LabEventData? {
        events.first { $0.kind == "run-start" }?.data ?? events.first { $0.kind == "proposal" }?.data
    }
    var end: LabEventData? { events.last { $0.kind == "run-end" }?.data }

    /// The newest reported result text.
    func latestResult(fallback: String?) -> String {
        let latest = events.filter { $0.kind == "result" && !($0.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .max { ($0.time, $0.id) < ($1.time, $1.id) }?.text
        let raw = latest ?? fallback ?? ""
        return raw.isEmpty ? "—" : LabMarkdown.plainText(raw)
    }

    /// The first captured parameter file's text, for the literal delta.
    var firstParameterText: String? { envelope?.params.first.flatMap { textByName[$0.storedName] } }
}

enum LabEvents {
    /// Results and notes, newest first, minus anything a human hid.
    static func visibleResults(_ events: [LabEvent]) -> [LabEvent] {
        let hidden = Set(events.filter { $0.kind == "hide" }.compactMap { $0.data?.target })
        return events.filter { ["result", "note", "hnote"].contains($0.kind) && !hidden.contains($0.id) }
            .sorted { ($0.time, $0.id) > ($1.time, $1.id) }
    }

    /// Human guidance written directly to a set, newest first.
    static func humanNotes(_ events: [LabEvent]) -> [LabEvent] {
        events.filter { $0.kind == "hnote" || ($0.kind == "note" && $0.author == "human") }
            .sorted { ($0.time, $0.id) > ($1.time, $1.id) }
    }

    static func isHidden(_ event: LabEvent, in events: [LabEvent]) -> Bool {
        events.contains { $0.kind == "hide" && $0.data?.target == event.id }
    }
}

/// Literal line delta between two captured parameter files.
struct LabParameterDelta: Equatable {
    let onlyA: [String]
    let onlyB: [String]
    var identical: Bool { onlyA.isEmpty && onlyB.isEmpty }

    init(_ a: String, _ b: String) {
        let la = a.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lb = b.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let sa = Set(la), sb = Set(lb)
        onlyA = la.filter { !sb.contains($0) }
        onlyB = lb.filter { !sa.contains($0) }
    }
}

// MARK: Guidance

enum LabGuidanceType { case all, machine, project, set }

struct LabGuidanceScope: Identifiable, Hashable {
    let key: String
    let type: LabGuidanceType
    let label: String
    let sub: String
    var storeID = ""
    var group: LabNotesGroup?
    var project = ""
    var card: LabSetCard?
    var id: String { key }

    var explanation: String {
        switch type {
        case .all: return "One network instruction is replicated to each reachable store and shown here once. Every agent brief receives its store's copy."
        case .machine: return "Every approved agent on \(label) receives this, regardless of project."
        case .project: return "Agents working on \(project) in this shared store receive it."
        case .set: return "Only the agent holding this experiment set receives it, plus inherited guidance above."
        }
    }
}

struct LabGuidanceNote: Identifiable, Hashable {
    struct Replica: Hashable { let group: LabNotesGroup; let note: LabHubNote }
    var group: LabNotesGroup?
    var card: LabSetCard?
    var note: LabHubNote
    var replicas: [Replica] = []
    var id: String { "\(group?.id ?? card?.id ?? "")/\(note.id)" }
}

enum LabGuidance {
    static func scopes(notes: [LabNotesGroup], sets: [LabSetCard]) -> [LabGuidanceScope] {
        var out = [LabGuidanceScope(key: "all", type: .all, label: "Everywhere", sub: "all reachable Lab stores")]
        let online = sets.filter { !$0.offline }
        for group in notes {
            out.append(LabGuidanceScope(key: "machine:\(group.id)", type: .machine, label: group.machineName, sub: "machine",
                                        storeID: group.storeID, group: group))
            let projects = Set(online.filter { $0.broker.labBrokerID == group.broker.labBrokerID || $0.machineName == group.machineName }
                .map(\.brief.set.project)).sorted()
            for project in projects {
                out.append(LabGuidanceScope(key: "project:\(group.id):\(project)", type: .project, label: project,
                                            sub: "project · \(group.machineName)", storeID: group.storeID, group: group, project: project))
            }
        }
        for card in online {
            let group = notes.first { $0.storeID == card.storeID && $0.broker.labBrokerID == card.broker.labBrokerID }
                ?? notes.first { $0.storeID == card.storeID }
            out.append(LabGuidanceScope(key: "set:\(card.id)", type: .set, label: card.brief.set.id,
                                        sub: "\(card.brief.set.project) · \(LabFormat.shortPath(card.brief.set.cwd))",
                                        storeID: card.storeID, group: group, project: card.brief.set.project, card: card))
        }
        return out
    }

    /// Everything an agent in this audience reads, store-deduplicated, with one
    /// "Everywhere" broadcast shown once however many stores received it.
    static func notes(_ groups: [LabNotesGroup], scope: LabGuidanceScope) -> [LabGuidanceNote] {
        var out: [LabGuidanceNote] = []
        var seen = Set<String>()
        for group in groups {
            for note in group.notes {
                let sameStore = group.storeID == scope.storeID
                let sameMachine = group.id == scope.group?.id
                let match: Bool
                switch scope.type {
                case .all: match = note.scope == "global"
                case .machine: match = (sameStore && note.scope == "global") || (sameMachine && note.scope == "machine")
                case .project, .set:
                    match = (sameStore && note.scope == "global") || (sameMachine && note.scope == "machine")
                        || (sameStore && note.scope == "project" && note.project == scope.project)
                }
                guard match else { continue }
                let owner = note.scope == "machine" ? "machine:\(group.id)" : "store:\(group.storeID)"
                if seen.insert("\(owner)/\(note.id)").inserted { out.append(LabGuidanceNote(group: group, note: note)) }
            }
        }
        if let card = scope.card {
            let hidden = Set(card.brief.setEvents.filter { $0.kind == "hide" }.compactMap { $0.data?.target })
            for e in card.brief.setEvents where e.kind == "hnote" || (e.kind == "note" && e.author == "human") {
                out.append(LabGuidanceNote(card: card, note: LabHubNote(
                    scope: "set", id: e.id, time: e.time, author: e.author, text: e.text ?? "", hidden: hidden.contains(e.id))))
            }
        }
        return mergeGlobal(out).sorted { $0.note.time > $1.note.time }
    }

    /// Fold per-store replicas of one "Everywhere" publish (same author and
    /// whitespace-normalized text, different stores, within two minutes).
    static func mergeGlobal(_ notes: [LabGuidanceNote]) -> [LabGuidanceNote] {
        struct Broadcast { var first: LabGuidanceNote; let signature: String; let at: Date?; var stores: Set<String>; var replicas: [LabGuidanceNote.Replica] }
        var direct = notes.filter { $0.note.scope != "global" }
        var broadcasts: [Broadcast] = []
        for entry in notes.filter({ $0.note.scope == "global" }).sorted(by: { $0.note.time < $1.note.time }) {
            guard let group = entry.group else { continue }
            let text = entry.note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let signature = "\(entry.note.author)\n\(text)"
            let at = LabTime.date(entry.note.time)
            let candidates = broadcasts.indices.filter { i in
                let b = broadcasts[i]
                guard b.signature == signature, !b.stores.contains(group.storeID), let at, let bAt = b.at else { return false }
                return abs(at.timeIntervalSince(bAt)) <= 120
            }
            if let i = candidates.min(by: { abs(at!.timeIntervalSince(broadcasts[$0].at!)) < abs(at!.timeIntervalSince(broadcasts[$1].at!)) }) {
                broadcasts[i].stores.insert(group.storeID)
                broadcasts[i].replicas.append(.init(group: group, note: entry.note))
            } else {
                broadcasts.append(Broadcast(first: entry, signature: signature, at: at, stores: [group.storeID],
                                            replicas: [.init(group: group, note: entry.note)]))
            }
        }
        for b in broadcasts {
            var merged = b.first
            merged.note.time = b.replicas.map(\.note.time).max() ?? merged.note.time
            merged.note.hidden = b.replicas.allSatisfy(\.note.hidden)
            merged.replicas = b.replicas
            direct.append(merged)
        }
        return direct
    }
}

// MARK: Formatting

enum LabTime {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// RFC 3339 (seconds, optionally fractional) → Date.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }

    /// "now", "5m", "3h", "2d" — the raw string when unparseable.
    static func ago(_ raw: String?, now: Date = Date()) -> String {
        guard let d = date(raw) else { return raw ?? "" }
        return ago(d, now: now)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

enum LabFormat {
    static func shortPath(_ path: String) -> String {
        path.count <= 34 ? path : "…/" + (path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path)
    }

    static func bytes(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    static func duration(_ seconds: Int?) -> String {
        guard let s = seconds else { return "—" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func codeState(_ snapshot: LabSnapshotInfo?) -> String {
        guard let snapshot else { return "—" }
        if snapshot.noGit { return "no Git repository" }
        let sha = String((snapshot.baseSha ?? "").prefix(10))
        return (sha.isEmpty ? "unknown" : sha) + (snapshot.patchBytes > 0 ? " + \(snapshot.patchBytes) B diff" : " · clean")
    }

    static func storeLabel(_ storeID: String) -> String {
        if storeID == "shared:babel" { return "Babel shared store" }
        if storeID.hasPrefix("mirror/") { return "Offline mirror" }
        return "Lab store"
    }

    /// W&B references are either URLs or `entity/project/runs/id` paths.
    static func wandbURL(_ ref: String) -> URL? {
        URL(string: ref.hasPrefix("http") ? ref : "https://wandb.ai/" + ref)
    }
}

// MARK: Markdown

/// Agent-authored Markdown, parsed into blocks (inline styling is rendered via
/// AttributedString). A port of Android's `parseLabMarkdown`.
enum LabMarkdown {
    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    static func parse(_ value: String) -> [Block] {
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        func heading(_ s: String) -> (Int, String)? {
            let hashes = s.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = s.dropFirst(hashes)
            guard rest.first == " " || rest.first == "\t" else { return nil }
            let text = trimmed(String(rest))
            return text.isEmpty ? nil : (hashes, text)
        }
        func listItem(_ s: String) -> String? {
            let t = s.drop { $0 == " " || $0 == "\t" }
            if let f = t.first, "-+*".contains(f), t.dropFirst().first == " " || t.dropFirst().first == "\t" {
                let item = trimmed(String(t.dropFirst(2)))
                return item.isEmpty ? nil : item
            }
            let digits = t.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            let after = t.dropFirst(digits.count)
            guard let m = after.first, m == "." || m == ")", after.dropFirst().first == " " else { return nil }
            let item = trimmed(String(after.dropFirst(2)))
            return item.isEmpty ? nil : item
        }
        func cells(_ s: String) -> [String] {
            trimmed(s).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map(trimmed)
        }
        func isTableRule(_ s: String) -> Bool {
            let c = cells(s)
            return !c.isEmpty && c.allSatisfy { cell in
                var x = Substring(cell)
                if x.hasPrefix(":") { x = x.dropFirst() }
                if x.hasSuffix(":") { x = x.dropLast() }
                return x.count >= 3 && x.allSatisfy { $0 == "-" }
            }
        }
        func fence(_ s: String) -> String? {
            let t = s.drop { $0 == " " || $0 == "\t" }
            return t.hasPrefix("```") ? "```" : t.hasPrefix("~~~") ? "~~~" : nil
        }
        func isRule(_ s: String) -> Bool { trimmed(s) == "---" || trimmed(s) == "***" }
        func isQuote(_ s: String) -> Bool { s.drop { $0 == " " || $0 == "\t" }.hasPrefix(">") }
        func startsBlock(_ at: Int) -> Bool {
            if at >= lines.count { return true }
            let l = lines[at]
            return blank(l) || heading(l) != nil || listItem(l) != nil || isQuote(l) || fence(l) != nil || isRule(l)
                || (at + 1 < lines.count && l.contains("|") && isTableRule(lines[at + 1]))
        }
        while i < lines.count {
            let line = lines[i]
            if blank(line) { i += 1; continue }
            if let h = heading(line) { out.append(.heading(h.0, h.1)); i += 1; continue }
            if isRule(line) { out.append(.rule); i += 1; continue }
            if let marker = fence(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, fence(lines[i]) != marker { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                out.append(.code(code.joined(separator: "\n")))
                continue
            }
            if i + 1 < lines.count, line.contains("|"), isTableRule(lines[i + 1]) {
                var rows = [cells(line)]
                i += 2
                while i < lines.count, lines[i].contains("|"), !blank(lines[i]) { rows.append(cells(lines[i])); i += 1 }
                out.append(.table(rows))
                continue
            }
            if listItem(line) != nil {
                var items: [String] = []
                while i < lines.count, let item = listItem(lines[i]) { items.append(item); i += 1 }
                out.append(.bullets(items))
                continue
            }
            if isQuote(line) {
                var quote: [String] = []
                while i < lines.count, isQuote(lines[i]) {
                    var t = lines[i].drop { $0 == " " || $0 == "\t" }.dropFirst()
                    t = t.drop { $0 == " " }
                    quote.append(String(t)); i += 1
                }
                out.append(.quote(quote.joined(separator: " ")))
                continue
            }
            var paragraph: [String] = []
            while i < lines.count, !startsBlock(i) { paragraph.append(trimmed(lines[i])); i += 1 }
            if paragraph.isEmpty { paragraph.append(trimmed(lines[i])); i += 1 }
            out.append(.paragraph(paragraph.joined(separator: " ")))
        }
        return out
    }

    /// Inline Markdown (bold, code, links, strikethrough) as an AttributedString.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// One-line plain text for previews and comparisons.
    static func plainText(_ value: String) -> String {
        let parts: [String] = parse(value).map { block in
            switch block {
            case .heading(_, let t), .paragraph(let t), .quote(let t), .code(let t): return t
            case .bullets(let items): return items.joined(separator: "; ")
            case .table(let rows): return rows.map { $0.joined(separator: " · ") }.joined(separator: "; ")
            case .rule: return ""
            }
        }
        let flattened = parts.map { String(inline($0).characters) }.joined(separator: " ")
        return flattened.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
