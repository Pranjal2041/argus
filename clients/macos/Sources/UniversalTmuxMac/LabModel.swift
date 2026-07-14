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
    var decided: String? = nil
    var note: String? = nil
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
    var latestAt: String? = nil
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
        let storeID: String
        let machineID: String
        let machineName: String
        let httpBase: String
        let brief: LabBrief
        var offline: Bool = false
        var mirroredAt: String = ""
        var id: String { machineID + "/" + brief.set.id }
    }
    struct PendingKey: Identifiable {
        let storeID: String
        let machineID: String
        let machineName: String
        let httpBase: String
        let key: LabKeyInfo
        var id: String { machineID + "/" + key.key }
    }
    struct PendingRun: Identifiable {
        let storeID: String
        let machineID: String
        let machineName: String
        let httpBase: String
        let proposal: LabProposal
        var id: String { machineID + "/" + proposal.id }
    }
    /// One key in the human access registry. Unlike PendingKey this includes
    /// active, denied, and revoked credentials so the dashboard matches
    /// `ut lab keys` instead of showing only decisions waiting in Inbox.
    struct AccessKey: Identifiable {
        let storeID: String
        let machineID: String
        let machineName: String
        let httpBase: String
        let key: LabKeyInfo
        var id: String { storeID + "/key/" + key.key }
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

    /// One broker's answer to a Lab refresh. Several brokers may be views of
    /// the same store (all Babel nodes mount the same NFS home), so these are
    /// collected first and reduced by store identity before anything reaches
    /// the UI.
    struct MachineSnapshot {
        let machine: Machine
        let briefs: [LabBrief]
        let keys: [LabKeyInfo]
        let proposals: [LabProposal]
        let notes: NotesResp?
    }

    struct AggregatedState {
        var sets: [SetCard]
        var accessKeys: [AccessKey]
        var pendingKeys: [PendingKey]
        var pendingRuns: [PendingRun]
        var hubNotes: [HubNotesGroup]
        var activeKeyBySet: [String: String]
    }

    /// A human action that belongs in every attention surface, not only inside
    /// the Lab pane. Keep this typed boundary here so Command Center does not
    /// have to understand Lab's wire structs (and future approval kinds get one
    /// obvious place to join the feed).
    struct AttentionItem: Identifiable {
        enum Kind: String, Equatable { case key, proposal }
        let id: String
        let targetID: String
        let kind: Kind
        let reference: String
        let project: String
        let machineName: String
        let summary: String
        let created: String
    }

    @Published var sets: [SetCard] = []
    @Published var accessKeys: [AccessKey] = []
    @Published var pendingKeys: [PendingKey] = []
    @Published var pendingRuns: [PendingRun] = []
    @Published var hubNotes: [HubNotesGroup] = []
    @Published var activeKeyBySet: [String: String] = [:]
    @Published var refreshing = false
    @Published var loadedOnce = false
    @Published private(set) var unattendedMode = false
    @Published private(set) var unattendedModeUpdating = false
    @Published private(set) var unattendedModeError: String?

    /// Newest first, matching the Lab decision queue. Everything in this list
    /// is blocked on a human action and therefore belongs in Command Center's
    /// top "Needs you" band.
    var attentionItems: [AttentionItem] {
        let keys = pendingKeys.map { item in
            AttentionItem(id: "key/" + item.id, targetID: item.id, kind: .key,
                          reference: "ACCESS", project: item.key.project,
                          machineName: item.machineName,
                          summary: "Approve agent access to a new isolated experiment set.",
                          created: item.key.created)
        }
        let runs = pendingRuns.map { item in
            let intent = item.proposal.intent.trimmingCharacters(in: .whitespacesAndNewlines)
            return AttentionItem(id: "proposal/" + item.id, targetID: item.id, kind: .proposal,
                                 reference: item.proposal.run, project: item.proposal.project,
                                 machineName: item.machineName,
                                 summary: intent.isEmpty ? "Review this experiment before it starts." : intent,
                                 created: item.proposal.created)
        }
        return (keys + runs).sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

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
            async let unattendedRequest = Self.fetchUnattendedMode(
                machines.first(where: { $0.isLocal }))
            var snapshots: [MachineSnapshot] = []
            await withTaskGroup(of: MachineSnapshot.self) { group in
                for m in machines {
                    group.addTask {
                        async let briefs = Self.fetchBriefs(m)
                        async let keys = Self.fetchKeys(m)
                        async let proposals = Self.fetchProposals(m)
                        async let notes = Self.fetchNotes(m)
                        return await MachineSnapshot(machine: m, briefs: briefs, keys: keys,
                                                     proposals: proposals, notes: notes)
                    }
                }
                for await snapshot in group { snapshots.append(snapshot) }
            }
            var mirrored: [LabMirrored] = []
            if let local = machines.first(where: { $0.isLocal }) {
                mirrored = await Self.fetchMirror(local)
            }
            let unattended = await unattendedRequest
            let aggregate = Self.aggregate(snapshots, mirrored: mirrored,
                                           mirrorHTTPBase: machines.first(where: { $0.isLocal })?.httpBase ?? "")
            guard gen == generation else { return }
            sets = aggregate.sets
            accessKeys = aggregate.accessKeys
            pendingKeys = aggregate.pendingKeys
            pendingRuns = aggregate.pendingRuns
            hubNotes = aggregate.hubNotes
            activeKeyBySet = aggregate.activeKeyBySet
            refreshing = false
            loadedOnce = true
            if !unattendedModeUpdating, let unattended {
                unattendedMode = unattended.enabled
                unattendedModeError = nil
            }
            AttentionNotifier.shared.updateLabAttention(total: attentionItems.count)
            notifyNewPendings()
        }
    }

    /// Collapse broker responses at the storage boundary. A set, key, or run
    /// proposal is a store-owned record, not a broker-owned record. Machine
    /// note groups deliberately remain per broker because machine-scoped notes
    /// are genuinely different even when global/project data is shared.
    static func aggregate(_ snapshots: [MachineSnapshot], mirrored: [LabMirrored],
                          mirrorHTTPBase: String) -> AggregatedState {
        let ordered = snapshots.sorted {
            ($0.machine.name.lowercased(), $0.machine.id) < ($1.machine.name.lowercased(), $1.machine.id)
        }
        let grouped = Dictionary(grouping: ordered) { snapshot in
            storeKey(for: snapshot.machine, reported: snapshot.notes?.store)
        }
        var cardsByRecord: [String: SetCard] = [:]
        var accessByRecord: [String: AccessKey] = [:]
        var pendingByRecord: [String: PendingKey] = [:]
        var proposalsByRecord: [String: PendingRun] = [:]
        var activeByRecord: [String: LabKeyInfo] = [:]
        var notes: [HubNotesGroup] = []

        for storeID in grouped.keys.sorted() {
            guard let peers = grouped[storeID], let fallback = peers.first else { continue }

            // Union first: two reads a few milliseconds apart can straddle a
            // write even on a shared store. Prefer the brief carrying more/newer
            // run state rather than depending on task completion order.
            var briefs: [String: LabBrief] = [:]
            var keys: [String: LabKeyInfo] = [:]
            var proposals: [String: LabProposal] = [:]
            for peer in peers {
                for brief in peer.briefs {
                    if let current = briefs[brief.set.id] {
                        if prefer(brief, over: current) { briefs[brief.set.id] = brief }
                    } else {
                        briefs[brief.set.id] = brief
                    }
                }
                for key in peer.keys {
                    if let current = keys[key.key] {
                        let candidateRank = keyStateRank(key.status)
                        let currentRank = keyStateRank(current.status)
                        if candidateRank > currentRank
                            || (candidateRank == currentRank && (key.decided ?? "") > (current.decided ?? "")) {
                            keys[key.key] = key
                        }
                    } else {
                        keys[key.key] = key
                    }
                }
                for proposal in peer.proposals {
                    proposals[proposal.id] = proposals[proposal.id] ?? proposal
                }
                // nil means unreachable; an empty note list is a real answer.
                if let response = peer.notes {
                    notes.append(HubNotesGroup(machineID: peer.machine.id, machineName: peer.machine.name,
                                               httpBase: peer.machine.httpBase, storeID: storeID,
                                               notes: response.notes ?? []))
                }
            }

            for brief in briefs.values {
                let route = peers.first(where: { machine($0.machine, matches: brief.set.machine) }) ?? fallback
                let record = storeID + "/set/" + brief.set.id
                cardsByRecord[record] = SetCard(storeID: storeID,
                                                machineID: route.machine.id,
                                                machineName: route.machine.name,
                                                httpBase: route.machine.httpBase,
                                                brief: brief)
            }
            for key in keys.values {
                let route = peers.first(where: { machine($0.machine, matches: key.machine) }) ?? fallback
                let keyRecord = storeID + "/key/" + key.key
                accessByRecord[keyRecord] = AccessKey(storeID: storeID,
                                                       machineID: route.machine.id,
                                                       machineName: route.machine.name,
                                                       httpBase: route.machine.httpBase,
                                                       key: key)
                if key.status == "pending" {
                    pendingByRecord[keyRecord] = PendingKey(storeID: storeID,
                                                            machineID: route.machine.id,
                                                            machineName: route.machine.name,
                                                            httpBase: route.machine.httpBase,
                                                            key: key)
                } else if key.status == "active", let set = key.set {
                    activeByRecord[storeID + "/set/" + set] = key
                }
            }
            for proposal in proposals.values {
                let route = peers.first(where: { machine($0.machine, matches: proposal.machine) }) ?? fallback
                let record = storeID + "/proposal/" + proposal.id
                proposalsByRecord[record] = PendingRun(storeID: storeID,
                                                        machineID: route.machine.id,
                                                        machineName: route.machine.name,
                                                        httpBase: route.machine.httpBase,
                                                        proposal: proposal)
            }
        }

        // A mirror can also contain the same shared-store set under more than
        // one peer directory. Its embedded home machine + set id is the durable
        // identity; retain only the freshest mirrored copy.
        let onlineHosts = Set(cardsByRecord.values.map { normalizedMachineName($0.brief.set.machine) })
        var mirrorByRecord: [String: LabMirrored] = [:]
        for item in mirrored {
            let owner = item.brief.set.machine.isEmpty ? item.machine : item.brief.set.machine
            guard !onlineHosts.contains(normalizedMachineName(owner)) else { continue }
            let record = normalizedMachineName(owner) + "/set/" + item.brief.set.id
            if let current = mirrorByRecord[record], current.updated >= item.updated { continue }
            mirrorByRecord[record] = item
        }
        for item in mirrorByRecord.values {
            let owner = item.brief.set.machine.isEmpty ? item.machine : item.brief.set.machine
            let record = "mirror/" + normalizedMachineName(owner) + "/set/" + item.brief.set.id
            cardsByRecord[record] = SetCard(storeID: "mirror/" + normalizedMachineName(owner),
                                            machineID: "mirror/" + owner, machineName: owner,
                                            httpBase: mirrorHTTPBase, brief: item.brief,
                                            offline: true, mirroredAt: item.updated)
        }

        func activity(_ card: SetCard) -> String {
            card.brief.runs?.map { $0.latestAt ?? $0.started ?? card.brief.set.created }.max()
                ?? card.brief.set.created
        }
        let cards = cardsByRecord.values.sorted {
            if $0.brief.set.project != $1.brief.set.project {
                return $0.brief.set.project < $1.brief.set.project
            }
            return (activity($0), $0.id) > (activity($1), $1.id)
        }
        var active: [String: String] = [:]
        for (record, key) in activeByRecord {
            if let card = cardsByRecord[record] { active[card.id] = key.key }
        }
        return AggregatedState(
            sets: cards,
            accessKeys: accessByRecord.values.sorted { ($0.key.created, $0.id) > ($1.key.created, $1.id) },
            pendingKeys: pendingByRecord.values.sorted { ($0.key.created, $0.id) > ($1.key.created, $1.id) },
            pendingRuns: proposalsByRecord.values.sorted { ($0.proposal.created, $0.id) > ($1.proposal.created, $1.id) },
            hubNotes: notes.sorted { ($0.machineName.lowercased(), $0.machineID) < ($1.machineName.lowercased(), $1.machineID) },
            activeKeyBySet: active
        )
    }

    /// Babel is a known shared NFS cluster. Its explicit key is also the safe
    /// fallback when one node answers the Lab routes but its /lab/notes identity
    /// request transiently fails. Other shared stores use the broker-reported id.
    static func storeKey(for machine: Machine, reported: String?) -> String {
        if isBabel(machine) { return "shared:babel" }
        if let id = reported?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "store:" + id
        }
        return "machine:" + machine.id
    }

    private static func isBabel(_ machine: Machine) -> Bool {
        [machine.name, machine.host, machine.id].contains { value in
            let first = value.lowercased().split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            return first.hasPrefix("babel-") || first.hasPrefix("ut-babel-")
        }
    }

    private static func normalizedMachineName(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".local") { name.removeLast(6) }
        if name.hasPrefix("ut-") { name.removeFirst(3) }
        return name
    }

    private static func machine(_ candidate: Machine, matches owner: String) -> Bool {
        let target = normalizedMachineName(owner)
        return [candidate.name, candidate.host, candidate.id].contains {
            normalizedMachineName($0).split(separator: ".", maxSplits: 1).first.map(String.init) == target
        }
    }

    private static func keyStateRank(_ status: String) -> Int {
        switch status {
        case "pending": return 0
        case "active", "denied": return 1
        case "revoked": return 2
        default: return 0
        }
    }

    private static func prefer(_ candidate: LabBrief, over current: LabBrief) -> Bool {
        let candidateRuns = candidate.runs ?? []
        let currentRuns = current.runs ?? []
        if candidateRuns.count != currentRuns.count { return candidateRuns.count > currentRuns.count }
        let candidateLatest = candidateRuns.compactMap(\.started).max() ?? ""
        let currentLatest = currentRuns.compactMap(\.started).max() ?? ""
        if candidateLatest != currentLatest { return candidateLatest > currentLatest }
        let candidateEvents = (candidate.notes?.count ?? 0) + (candidate.setEvents?.count ?? 0)
        let currentEvents = (current.notes?.count ?? 0) + (current.setEvents?.count ?? 0)
        return candidateEvents > currentEvents
    }

    private func notifyNewPendings() {
        var added = false
        for k in pendingKeys where !notified.contains(k.id) {
            AttentionNotifier.shared.labApprovalNeeded(
                id: k.id, title: "Lab: key request",
                body: "\(k.key.project) wants a set on \(k.machineName)", kind: "key")
            notified.insert(k.id)
            notifiedList.append(k.id)
            added = true
        }
        for r in pendingRuns where !notified.contains(r.id) {
            AttentionNotifier.shared.labApprovalNeeded(
                id: r.id, title: "Lab: experiment awaiting approval",
                body: "\(r.proposal.intent) (\(r.proposal.project) on \(r.machineName))",
                kind: "proposal")
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

    /// Toggle the broker-owned automation switch. The optimistic value keeps
    /// every surface in sync immediately; a failed POST rolls it back rather
    /// than pretending unattended approvals are active.
    func setUnattendedMode(_ enabled: Bool) {
        guard !unattendedModeUpdating else { return }
        guard let state = boundState,
              let local = state.machines.first(where: { $0.isLocal }) else {
            unattendedModeError = "This Mac's broker is not available."
            return
        }
        let previous = unattendedMode
        unattendedMode = enabled
        unattendedModeUpdating = true
        unattendedModeError = nil
        Task {
            let ok = await postNow(local.httpBase + "/automation/unattended",
                                   [URLQueryItem(name: "enabled", value: enabled ? "true" : "false")])
            unattendedModeUpdating = false
            if ok {
                // The broker starts an immediate sweep. Refresh shortly after
                // so auto-resolved Inbox rows disappear without waiting 20s.
                try? await Task.sleep(nanoseconds: 750_000_000)
                refresh(state)
            } else {
                unattendedMode = previous
                unattendedModeError = "This Mac's broker could not change Unattended Mode."
            }
        }
    }

    func decideKeyNow(_ k: PendingKey, approve: Bool, project: String,
                      policy: String, note: String) async -> Bool {
        var q = [URLQueryItem(name: "key", value: String(k.key.key.prefix(8))),
                 URLQueryItem(name: "approve", value: approve ? "1" : "0")]
        let p = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if approve, !p.isEmpty, p != k.key.project { q.append(URLQueryItem(name: "project", value: p)) }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { q.append(URLQueryItem(name: "note", value: n)) }
        if approve, ["all", "full-only", "none"].contains(policy) {
            q.append(URLQueryItem(name: "policy", value: policy))
        }
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

    func revokeKeyNow(_ item: AccessKey) async -> Bool {
        guard item.key.status == "active" else { return false }
        return await postNow(item.httpBase + "/lab/revoke",
                             [URLQueryItem(name: "key", value: String(item.key.key.prefix(8)))])
    }

    /// Dashboard equivalent of `ut lab init`, routed through the owning set so
    /// the broker—not web content—chooses the project folder.
    func installInstructionsNow(_ card: SetCard) async -> Bool {
        await postNow(card.httpBase + "/lab/init",
                      [URLQueryItem(name: "set", value: card.brief.set.id)])
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
    struct NotesResp: Decodable {
        var store: String?
        var notes: [LabHubNote]?
    }
    private struct KeysResp: Decodable { var keys: [LabKeyInfo]? }
    private struct ProposalsResp: Decodable { var proposals: [LabProposal]? }
    private struct MirrorResp: Decodable { var mirror: [LabMirrored]? }
    private struct EventsResp: Decodable { var events: [LabEventItem]? }
    private struct FilesResp: Decodable { var files: [LabRunFileInfo]? }
    private struct UnattendedModeResp: Decodable {
        let enabled: Bool
        var updatedAt: Int64?
    }

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
    private static func fetchUnattendedMode(_ m: Machine?) async -> UnattendedModeResp? {
        guard let m else { return nil }
        return await get(m.httpBase + "/automation/unattended", as: UnattendedModeResp.self)
    }
    /// nil when the machine's broker is unreachable (pre-lab or offline), so
    /// the Notes view can distinguish "no notes" from "no answer".
    private static func fetchNotes(_ m: Machine) async -> NotesResp? {
        await get(m.httpBase + "/lab/notes", as: NotesResp.self)
    }
}
