import SwiftUI

// Argus Lab: the hub-side data layer. Unions every online broker's /lab
// routes (sets, briefs, pending keys, pending run proposals) plus the local
// broker's permanent mirror for machines that are offline, and posts the
// human's decisions and curation back to the machine that owns them. Polls
// app-wide (20s) so approval notifications fire with the pane closed, and
// faster (5s) while the pane is visible. Presentation lives entirely in
// Resources/lab; this file never styles anything.

// MARK: wire structs (labsvc JSON)

struct LabSetMeta: Codable, Hashable, Identifiable {
    let id: String
    let project: String
    let machine: String
    let cwd: String
    let created: String
}

struct LabKeyInfo: Codable, Hashable {
    let key: String
    var `set`: String?
    let project: String
    let machine: String
    let cwd: String
    var session: String?
    let status: String
    let created: String
}

struct LabEventInfo: Codable, Hashable, Identifiable {
    let id: String
    let time: String
    let author: String
    let kind: String
    var text: String?
    var data: LabEventData?
}

struct LabFileRef: Codable, Hashable {
    let path: String
    var sha256: String?
}

struct LabRunFileInfo: Codable, Hashable {
    let name: String
    let size: Int64
}

struct LabSnapshotInfo: Codable, Hashable {
    var baseSha: String?
    var noGit: Bool?
    var patchBytes: Int64?
    var archived: Int?
}

struct LabEnvFacts: Codable, Hashable {
    var os: String?
    var arch: String?
    var python: String?
    var gpus: String?
}

/// The structured payload an event can carry. Every field is optional, so one
/// type decodes a hide marker, a run envelope, and a run ending alike.
struct LabEventData: Codable, Hashable {
    var target: String?
    var argv: [String]?
    var cwd: String?
    var tier: String?
    var group: String?
    var tmuxSession: String?
    var bind: String?
    var snapshot: LabSnapshotInfo?
    var params: [LabFileRef]?
    var dataFiles: [LabFileRef]?
    var env: LabEnvFacts?
    var exit: Int?
    var durationSec: Int?
    var wandb: [String]?
    var drift: [String]?
}

struct LabEventItem: Codable, Hashable, Identifiable {
    let id: String
    let time: String
    let author: String
    let kind: String
    var text: String?
    var data: LabEventData?
}

struct LabRunSummary: Codable, Hashable, Identifiable {
    let id: String
    var group: String?
    var tier: String?
    let status: String
    var started: String?
    var latest: String?
    let exitCode: Int
    var archived: Bool?
}

struct LabBrief: Codable {
    let `set`: LabSetMeta
    var policy: String?
    var notes: [LabEventInfo]?
    var setEvents: [LabEventInfo]?
    var runs: [LabRunSummary]?
    var archived: Bool?
}

struct LabProposal: Codable, Hashable, Identifiable {
    let `set`: String
    let run: String
    let project: String
    let machine: String
    let intent: String
    var tier: String?
    var group: String?
    var argv: [String]?
    var cwd: String?
    let created: String
    var id: String { `set` + "/" + run }
}

struct LabMirrored: Codable {
    let machine: String
    let `set`: String
    let updated: String
    let brief: LabBrief
}

/// One scope-level note (global / this machine / a project) from /lab/notes.
struct LabHubNote: Codable, Hashable, Identifiable {
    let scope: String
    var project: String?
    let id: String
    let time: String
    let author: String
    let text: String
    let hidden: Bool
}

// MARK: model

@MainActor
final class LabModel: ObservableObject {
    struct SetCard: Identifiable {
        let machineID: String
        let machineName: String
        let httpBase: String
        let brief: LabBrief
        var offline: Bool = false
        var mirroredAt: String = ""
        var id: String { machineID + "/" + brief.set.id }
    }
    struct PendingKey: Identifiable {
        let machineID: String
        let machineName: String
        let httpBase: String
        let key: LabKeyInfo
        var id: String { machineID + "/" + key.key }
    }
    struct PendingRun: Identifiable {
        let machineID: String
        let machineName: String
        let httpBase: String
        let proposal: LabProposal
        var id: String { machineID + "/" + proposal.id }
    }
    /// One online machine's scope-level notes for the hub's Notes view.
    struct HubNotesGroup: Identifiable {
        let machineID: String
        let machineName: String
        let httpBase: String
        let storeID: String   // same id on two machines = one shared store
        let notes: [LabHubNote]
        var id: String { machineID }
    }

    @Published var sets: [SetCard] = []
    @Published var pendingKeys: [PendingKey] = []
    @Published var pendingRuns: [PendingRun] = []
    @Published var hubNotes: [HubNotesGroup] = []
    @Published var activeKeyBySet: [String: String] = [:]
    @Published var refreshing = false
    @Published var loadedOnce = false

    private weak var boundState: AppState?
    private var timer: Timer?
    private var paneVisible = false
    private var generation = 0

    private var notifiedList: [String] = UserDefaults.standard.stringArray(forKey: "ut.lab.notified.v1") ?? []
    private lazy var notified: Set<String> = Set(notifiedList)

    /// App-wide start (RootView.onAppear). Idempotent.
    func bind(_ state: AppState) {
        boundState = state
        if timer == nil {
            schedule()
            refresh(state)
        }
    }

    func setPaneVisible(_ v: Bool) {
        guard paneVisible != v else { return }
        paneVisible = v
        schedule()
        if v, let s = boundState { refresh(s) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: paneVisible ? 5 : 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.boundState else { return }
                self.refresh(s)
            }
        }
    }

    func refresh(_ state: AppState) {
        let machines = state.machines
        generation += 1
        let gen = generation
        refreshing = true
        Task {
            var newSets: [SetCard] = []
            var newKeys: [PendingKey] = []
            var newRuns: [PendingRun] = []
            var newActive: [String: String] = [:]
            var newNotes: [HubNotesGroup] = []
            await withTaskGroup(of: (Machine, [LabBrief], [LabKeyInfo], [LabProposal], NotesResp?).self) { group in
                for m in machines {
                    group.addTask { (m, await Self.fetchBriefs(m), await Self.fetchKeys(m), await Self.fetchProposals(m), await Self.fetchNotes(m)) }
                }
                for await (m, briefs, keys, proposals, notes) in group {
                    for b in briefs {
                        newSets.append(SetCard(machineID: m.id, machineName: m.name, httpBase: m.httpBase, brief: b))
                    }
                    for k in keys {
                        if k.status == "pending" {
                            newKeys.append(PendingKey(machineID: m.id, machineName: m.name, httpBase: m.httpBase, key: k))
                        } else if k.status == "active", let set = k.set {
                            newActive[m.id + "/" + set] = k.key
                        }
                    }
                    for p in proposals {
                        newRuns.append(PendingRun(machineID: m.id, machineName: m.name, httpBase: m.httpBase, proposal: p))
                    }
                    // nil = machine unreachable; an empty list is a real answer
                    if let notes {
                        newNotes.append(HubNotesGroup(machineID: m.id, machineName: m.name, httpBase: m.httpBase,
                                                      storeID: notes.store ?? "", notes: notes.notes ?? []))
                    }
                }
            }
            // offline machines show through the local broker's permanent mirror
            let onlineHosts = Set(newSets.map { $0.brief.set.machine })
            if let local = machines.first(where: { $0.isLocal }) {
                for m in await Self.fetchMirror(local) where !onlineHosts.contains(m.machine) {
                    newSets.append(SetCard(machineID: "mirror/" + m.machine, machineName: m.machine,
                                           httpBase: local.httpBase, brief: m.brief,
                                           offline: true, mirroredAt: m.updated))
                }
            }
            guard gen == generation else { return }
            sets = newSets.sorted { ($0.brief.set.project, $0.brief.set.created) < ($1.brief.set.project, $1.brief.set.created) }
            pendingKeys = newKeys.sorted { $0.key.created < $1.key.created }
            pendingRuns = newRuns.sorted { $0.proposal.created < $1.proposal.created }
            hubNotes = newNotes.sorted { $0.machineName < $1.machineName }
            activeKeyBySet = newActive
            refreshing = false
            loadedOnce = true
            notifyNewPendings()
        }
    }

    private func notifyNewPendings() {
        var added = false
        for k in pendingKeys where !notified.contains(k.id) {
            AttentionNotifier.shared.labApprovalNeeded(
                id: k.id, title: "Lab: key request",
                body: "\(k.key.project) wants a set on \(k.machineName)")
            notified.insert(k.id)
            notifiedList.append(k.id)
            added = true
        }
        for r in pendingRuns where !notified.contains(r.id) {
            AttentionNotifier.shared.labApprovalNeeded(
                id: r.id, title: "Lab: experiment awaiting approval",
                body: "\(r.proposal.intent) (\(r.proposal.project) on \(r.machineName))")
            notified.insert(r.id)
            notifiedList.append(r.id)
            added = true
        }
        if added {
            if notifiedList.count > 1000 {
                notifiedList.removeFirst(notifiedList.count - 1000)
                notified = Set(notifiedList)
            }
            UserDefaults.standard.set(notifiedList, forKey: "ut.lab.notified.v1")
        }
    }

    // MARK: decisions and curation (the human channel)

    func decideKeyNow(_ k: PendingKey, approve: Bool, project: String) async -> Bool {
        var q = [URLQueryItem(name: "key", value: String(k.key.key.prefix(8))),
                 URLQueryItem(name: "approve", value: approve ? "1" : "0")]
        let p = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if approve, !p.isEmpty, p != k.key.project { q.append(URLQueryItem(name: "project", value: p)) }
        return await postNow(k.httpBase + "/lab/decide", q)
    }

    func decideRunNow(_ card: SetCard, run: String, approve: Bool, note: String) async -> Bool {
        var q = [URLQueryItem(name: "set", value: card.brief.set.id),
                 URLQueryItem(name: "run", value: run),
                 URLQueryItem(name: "approve", value: approve ? "1" : "0")]
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { q.append(URLQueryItem(name: "note", value: n)) }
        return await postNow(card.httpBase + "/lab/decide-run", q)
    }

    @discardableResult
    func hide(_ card: SetCard, target: String) async -> Bool {
        await postNow(card.httpBase + "/lab/hide",
                      [URLQueryItem(name: "set", value: card.brief.set.id),
                       URLQueryItem(name: "target", value: target)])
    }

    func postNoteNow(_ card: SetCard, scope: String, run: String, text: String) async -> Bool {
        var q = [URLQueryItem(name: "scope", value: scope),
                 URLQueryItem(name: "text", value: text)]
        switch scope {
        case "set": q.append(URLQueryItem(name: "set", value: card.brief.set.id))
        case "run":
            q.append(URLQueryItem(name: "set", value: card.brief.set.id))
            q.append(URLQueryItem(name: "run", value: run))
        case "project": q.append(URLQueryItem(name: "project", value: card.brief.set.project))
        default: break
        }
        return await postNow(card.httpBase + "/lab/note", q)
    }

    /// "Everywhere" write: one copy of a global note into every reachable
    /// store — the honest form of "all my agents"; stores never sync. Brokers
    /// sharing a store (cluster nodes on NFS) get exactly one copy.
    func postHubNoteAllNow(text: String) async -> Bool {
        var seen = Set<String>()
        var bases: [String] = []
        for g in hubNotes {
            let key = g.storeID.isEmpty ? g.httpBase : g.storeID
            if seen.insert(key).inserted { bases.append(g.httpBase) }
        }
        guard !bases.isEmpty else { return false }
        var success = true
        for base in bases {
            if !(await postNow(base + "/lab/note",
                               [URLQueryItem(name: "scope", value: "global"),
                                URLQueryItem(name: "text", value: text)])) {
                success = false
            }
        }
        return success
    }

    /// Notes-view write: a note at global/machine/project scope on one machine.
    func postHubNoteNow(machineID: String, scope: String, project: String, text: String) async -> Bool {
        guard let g = hubNotes.first(where: { $0.machineID == machineID }) else { return false }
        var q = [URLQueryItem(name: "scope", value: scope),
                 URLQueryItem(name: "text", value: text)]
        if scope == "project" { q.append(URLQueryItem(name: "project", value: project)) }
        return await postNow(g.httpBase + "/lab/note", q)
    }

    /// Notes-view hide: scope-level notes live outside sets, so the hide
    /// carries the scope instead of a set id.
    func hideHubNoteNow(machineID: String, scope: String, project: String, target: String) async -> Bool {
        guard let g = hubNotes.first(where: { $0.machineID == machineID }) else { return false }
        var q = [URLQueryItem(name: "scope", value: scope),
                 URLQueryItem(name: "target", value: target)]
        if scope == "project" { q.append(URLQueryItem(name: "project", value: project)) }
        return await postNow(g.httpBase + "/lab/hide", q)
    }

    /// Archive view-state for a set (run empty) or one run — recorded, reversible.
    func setArchivedNow(_ card: SetCard, run: String, on: Bool) async -> Bool {
        var q = [URLQueryItem(name: "set", value: card.brief.set.id),
                 URLQueryItem(name: "on", value: on ? "1" : "0")]
        if !run.isEmpty { q.append(URLQueryItem(name: "run", value: run)) }
        return await postNow(card.httpBase + "/lab/archive", q)
    }

    func setPolicyNow(_ card: SetCard, policy: String) async -> Bool {
        await postNow(card.httpBase + "/lab/policy",
                      [URLQueryItem(name: "set", value: card.brief.set.id),
                       URLQueryItem(name: "policy", value: policy)])
    }

    func revokeKeyNow(_ card: SetCard) async -> Bool {
        guard let key = activeKeyBySet[card.id] else { return false }
        return await postNow(card.httpBase + "/lab/revoke",
                             [URLQueryItem(name: "key", value: String(key.prefix(8)))])
    }

    // MARK: reads for the run page

    func runEvents(_ card: SetCard, run: String) async -> [LabEventItem] {
        var c = URLComponents(string: card.httpBase + "/lab/events")
        var q = [URLQueryItem(name: "set", value: card.brief.set.id),
                 URLQueryItem(name: "run", value: run)]
        if card.offline { q.append(URLQueryItem(name: "machine", value: card.machineName)) }
        c?.queryItems = q
        guard let url = c?.url?.absoluteString,
              let resp = await Self.get(url, as: EventsResp.self) else { return [] }
        return resp.events ?? []
    }

    func runFiles(_ card: SetCard, run: String) async -> [LabRunFileInfo] {
        guard !card.offline else { return [] } // the permanent mirror stores events, not artifacts
        var c = URLComponents(string: card.httpBase + "/lab/files")
        c?.queryItems = [URLQueryItem(name: "set", value: card.brief.set.id),
                         URLQueryItem(name: "run", value: run)]
        guard let url = c?.url?.absoluteString,
              let resp = await Self.get(url, as: FilesResp.self) else { return [] }
        return resp.files ?? []
    }

    func runFileText(_ card: SetCard, run: String, name: String, tailBytes: Int? = nil) async -> String? {
        guard !card.offline else { return nil }
        var c = URLComponents(string: card.httpBase + "/lab/file")
        var q = [URLQueryItem(name: "set", value: card.brief.set.id),
                 URLQueryItem(name: "run", value: run),
                 URLQueryItem(name: "name", value: name)]
        if let t = tailBytes { q.append(URLQueryItem(name: "tail", value: String(t))) }
        c?.queryItems = q
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: d.prefix(2_000_000), encoding: .utf8)
    }

    // MARK: plumbing

    private func postNow(_ base: String, _ query: [URLQueryItem]) async -> Bool {
        guard var c = URLComponents(string: base) else { return false }
        c.queryItems = query
        guard let url = c.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private static func get<T: Decodable>(_ url: String, as type: T.Type) async -> T? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 6
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private struct SetsResp: Decodable { var sets: [LabSetMeta]? }
    private struct NotesResp: Decodable {
        var store: String?
        var notes: [LabHubNote]?
    }
    private struct KeysResp: Decodable { var keys: [LabKeyInfo]? }
    private struct ProposalsResp: Decodable { var proposals: [LabProposal]? }
    private struct MirrorResp: Decodable { var mirror: [LabMirrored]? }
    private struct EventsResp: Decodable { var events: [LabEventItem]? }
    private struct FilesResp: Decodable { var files: [LabRunFileInfo]? }

    private static func fetchBriefs(_ m: Machine) async -> [LabBrief] {
        guard let resp = await get(m.httpBase + "/lab/sets", as: SetsResp.self), let metas = resp.sets else { return [] }
        var out: [LabBrief] = []
        for meta in metas {
            if let b = await get(m.httpBase + "/lab/brief?set=" + meta.id, as: LabBrief.self) {
                out.append(b)
            }
        }
        return out
    }
    private static func fetchKeys(_ m: Machine) async -> [LabKeyInfo] {
        (await get(m.httpBase + "/lab/keys", as: KeysResp.self))?.keys ?? []
    }
    private static func fetchProposals(_ m: Machine) async -> [LabProposal] {
        (await get(m.httpBase + "/lab/proposals", as: ProposalsResp.self))?.proposals ?? []
    }
    private static func fetchMirror(_ m: Machine) async -> [LabMirrored] {
        (await get(m.httpBase + "/lab/mirror", as: MirrorResp.self))?.mirror ?? []
    }
    /// nil when the machine's broker is unreachable (pre-lab or offline), so
    /// the Notes view can distinguish "no notes" from "no answer".
    private static func fetchNotes(_ m: Machine) async -> NotesResp? {
        await get(m.httpBase + "/lab/notes", as: NotesResp.self)
    }
}
