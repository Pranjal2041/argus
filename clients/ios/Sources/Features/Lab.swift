import SwiftUI

// Argus Lab on iPhone: the human side of the agent research protocol
// (docs/content/docs/lab.mdx). The store reads every broker's Lab, reduces it
// through LabAggregator (one copy per shared store), and performs the human
// decisions; LabView and its pages live in LabViews.swift / LabPages.swift.

struct LabAttentionItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case key = "KEY", proposal = "PROPOSAL" }
    let kind: Kind
    /// Android-compatible target id: "<brokerID>/<fullKey>" or "<brokerID>/<set>/<run>".
    let targetID: String
    let reference: String
    let project: String
    let machineName: String
    let summary: String
    let created: Date?
    var id: String { (kind == .key ? "key/" : "proposal/") + targetID }
}

@MainActor
final class LabStore: ObservableObject {
    @Published var attention: [LabAttentionItem] = []
    /// Unattended Mode on the Mac (nil = unknown).
    @Published var unattended: Bool?

    @Published private(set) var sets: [LabSetCard] = []
    @Published private(set) var pendingKeys: [LabPendingKey] = []
    @Published private(set) var pendingRuns: [LabPendingRun] = []
    @Published private(set) var notes: [LabNotesGroup] = []
    @Published private(set) var activeKeyBySet: [String: String] = [:]
    @Published private(set) var details: [String: LabRunDetail] = [:]
    @Published private(set) var detailLoading: Set<String> = []
    @Published private(set) var loaded = false
    @Published private(set) var refreshing = false
    @Published private(set) var actionBusy = false
    @Published private(set) var unattendedUpdating = false
    @Published var error: String?
    @Published var unattendedError: String?

    static let rejectedMessage = "The Lab broker did not accept this change."

    private weak var fleet: FleetStore?
    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// Detail keys a visible page shows; they re-fetch when their run changes.
    private var watched: [String: (cardID: String, run: String)] = [:]

    var hasMac: Bool { fleet?.syncHost != nil }

    // MARK: Lifecycle

    /// Called once by the app. Runs its own ~6 s loop (FleetStore.onTick has a
    /// single owner elsewhere).
    func start(fleet: FleetStore) {
        self.fleet = fleet
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    /// Refreshes now. A call during an in-flight refresh waits for it and then
    /// runs once more, so post-action state is never dropped.
    func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    private func performRefresh() async {
        guard let fleet, !fleet.machines.isEmpty else { return }
        let brokers = fleet.machines
        let mac = fleet.syncHost
        refreshing = true
        defer { refreshing = false }

        async let snapshotsAnswer: [LabBrokerSnapshot] = withTaskGroup(of: LabBrokerSnapshot.self) { group in
            for m in brokers { group.addTask { await LabNet.snapshot(m) } }
            var out: [LabBrokerSnapshot] = []
            for await s in group { out.append(s) }
            return out
        }
        async let mirrorAnswer: [LabMirrored] = { if let mac { return await LabNet.mirror(mac) } else { return [] } }()
        async let unattendedAnswer: Bool? = { if let mac { return await LabNet.unattended(mac) } else { return nil } }()
        let snapshots = await snapshotsAnswer
        let mirrored = await mirrorAnswer
        let remoteUnattended = await unattendedAnswer

        if !unattendedUpdating, let remoteUnattended {
            unattended = remoteUnattended
            unattendedError = nil
        }
        guard snapshots.contains(where: \.answered) else {
            if loaded { error = "Lab brokers are temporarily unreachable. Showing the last complete view." }
            loaded = true
            return
        }
        apply(LabAggregator.aggregate(snapshots, mirrored: mirrored, mirrorBroker: mac))
        if error?.hasPrefix("Lab brokers are temporarily") == true { error = nil }
    }

    private func apply(_ a: LabAggregate) {
        let previous = Dictionary(sets.flatMap { card in card.brief.runs.map { (detailKey(card, $0.id), $0.fingerprint) } },
                                  uniquingKeysWith: { x, _ in x })
        sets = a.sets
        pendingKeys = a.pendingKeys
        pendingRuns = a.pendingRuns
        notes = a.notes
        activeKeyBySet = a.activeKeyBySet
        if attention != a.attention { attention = a.attention }
        loaded = true
        // Re-fetch visible details whose run changed, or that are still live.
        for (key, w) in watched {
            guard let card = card(id: w.cardID) else { continue }
            let run = card.brief.runs.first { $0.id == w.run }
            let changed = run.map { previous[key] != nil && previous[key] != $0.fingerprint } ?? false
            if changed || run?.phase.isLive == true { loadDetail(card, run: w.run, force: true) }
        }
    }

    // MARK: Lookups

    func card(id: String) -> LabSetCard? { sets.first { $0.id == id } }
    func pendingKey(id: String) -> LabPendingKey? { pendingKeys.first { $0.id == id } }
    func pendingRun(id: String) -> LabPendingRun? { pendingRuns.first { $0.id == id } }

    /// The set a proposal belongs to (same store, same set id).
    func card(for pending: LabPendingRun) -> LabSetCard? {
        sets.first { $0.storeID == pending.storeID && $0.brief.set.id == pending.proposal.set }
    }

    func pendingRun(in card: LabSetCard, run: String) -> LabPendingRun? {
        pendingRuns.first { $0.storeID == card.storeID && $0.proposal.set == card.brief.set.id && $0.proposal.run == run }
    }

    /// Route terminal actions to the machine that recorded the work, not to the
    /// broker that served the (shared) store.
    func terminalTarget(machineName: String?, fallback: Machine?, session: String?) -> (Machine, SessionInfo)? {
        guard let fleet, let session, !session.isEmpty,
              let m = machineName.flatMap(fleet.machine(named:)) ?? fallback,
              let s = fleet.session(on: m, named: session) else { return nil }
        return (m, s)
    }

    // MARK: Details

    func detailKey(_ card: LabSetCard, _ run: String) -> String { "\(card.id)/\(run)" }
    func detailKey(_ pending: LabPendingRun) -> String { "pending:\(pending.id)" }

    func watch(_ card: LabSetCard, run: String) { watched[detailKey(card, run)] = (card.id, run) }
    func unwatch(_ card: LabSetCard, run: String) { watched[detailKey(card, run)] = nil }

    func loadDetail(_ card: LabSetCard, run: String, force: Bool = false) {
        let key = detailKey(card, run)
        guard !detailLoading.contains(key), force || details[key] == nil else { return }
        detailLoading.insert(key)
        Task {
            let d = await LabNet.runDetail(broker: card.broker, set: card.brief.set.id, run: run,
                                           offline: card.offline, ownerMachine: card.machineName)
            details[key] = d
            detailLoading.remove(key)
        }
    }

    /// A proposal's evidence, readable even before its set appears in a brief.
    func loadDetail(_ pending: LabPendingRun, force: Bool = false) {
        if let card = card(for: pending) { return loadDetail(card, run: pending.proposal.run, force: force) }
        let key = detailKey(pending)
        guard !detailLoading.contains(key), force || details[key] == nil else { return }
        detailLoading.insert(key)
        Task {
            details[key] = await LabNet.runDetail(broker: pending.broker, set: pending.proposal.set, run: pending.proposal.run,
                                                  offline: false, ownerMachine: pending.machineName)
            detailLoading.remove(key)
        }
    }

    func detail(_ pending: LabPendingRun) -> LabRunDetail? {
        card(for: pending).flatMap { details[detailKey($0, pending.proposal.run)] } ?? details[detailKey(pending)]
    }

    /// Lazily fetch one stored artifact (logs as a tail).
    func loadArtifact(_ card: LabSetCard, run: String, file: LabRunFileInfo) {
        let key = detailKey(card, run)
        let loadingKey = key + "#" + file.name
        guard details[key]?.textByName[file.name] == nil, !detailLoading.contains(loadingKey), !card.offline else { return }
        detailLoading.insert(loadingKey)
        let isLog = file.name.hasSuffix(".log") || file.name.hasSuffix("log.txt") || file.name.hasSuffix(".out") || file.name.hasSuffix(".err")
        let tail: Int? = isLog ? LabNet.logTail : (file.size > Int64(LabNet.textCap) ? LabNet.textCap : nil)
        Task {
            let text = await LabNet.fileText(broker: card.broker, set: card.brief.set.id, run: run, name: file.name, tail: tail)
            var d = details[key] ?? LabRunDetail()
            d.textByName[file.name] = text ?? "Could not read \(file.name)."
            details[key] = d
            detailLoading.remove(loadingKey)
        }
    }

    func isLoading(_ key: String) -> Bool { detailLoading.contains(key) }

    // MARK: Human actions

    /// One action at a time; refresh after success. Returns whether it was accepted.
    @discardableResult
    private func act(_ operation: () async -> Bool) async -> Bool {
        guard !actionBusy else { return false }
        actionBusy = true
        error = nil
        let ok = await operation()
        actionBusy = false
        if ok {
            await refresh()
            for (_, w) in watched { if let card = card(id: w.cardID) { loadDetail(card, run: w.run, force: true) } }
        } else {
            error = Self.rejectedMessage
        }
        return ok
    }

    @discardableResult
    func decide(_ item: LabPendingKey, approve: Bool, project: String, note: String = "", policy: String = "") async -> Bool {
        await act { await LabNet.decideKey(item, approve: approve, project: project, note: note, policy: policy) }
    }

    @discardableResult
    func decide(_ pending: LabPendingRun, approve: Bool, note: String) async -> Bool {
        // Data actions may use any broker of the shared store; the owning set's
        // broker is preferred when its brief is visible.
        let broker = card(for: pending)?.broker ?? pending.broker
        return await act {
            await LabNet.decideRun(broker: broker, set: pending.proposal.set, run: pending.proposal.run, approve: approve, note: note)
        }
    }

    @discardableResult
    func setPolicy(_ card: LabSetCard, _ policy: String) async -> Bool { await act { await LabNet.policy(card, policy) } }

    @discardableResult
    func setArchived(_ card: LabSetCard, run: String = "", on: Bool) async -> Bool {
        await act { await LabNet.archive(card, run: run, on: on) }
    }

    @discardableResult
    func markStopped(_ card: LabSetCard, run: String, reason: String) async -> Bool {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1000 else { return false }
        return await act { await LabNet.markStopped(card, run: run, reason: trimmed) }
    }

    @discardableResult
    func revokeKey(_ card: LabSetCard) async -> Bool {
        guard let key = activeKeyBySet[card.id] else { return false }
        return await act { await LabNet.revoke(card, key: key) }
    }

    @discardableResult
    func postSetNote(_ card: LabSetCard, _ text: String) async -> Bool {
        await act { await LabNet.note(card.broker, scope: "set", text: text, set: card.brief.set.id) }
    }

    @discardableResult
    func postRunNote(_ card: LabSetCard, run: String, _ text: String) async -> Bool {
        await act { await LabNet.note(card.broker, scope: "run", text: text, set: card.brief.set.id, run: run) }
    }

    @discardableResult
    func postScopeNote(_ group: LabNotesGroup, scope: String, project: String, _ text: String) async -> Bool {
        await act { await LabNet.note(group.broker, scope: scope, text: text, project: project) }
    }

    /// "Everywhere": once per distinct store, never once per broker.
    @discardableResult
    func postEverywhere(_ text: String) async -> Bool {
        var seen = Set<String>()
        let targets = notes.filter { seen.insert($0.storeID).inserted }
        return await act {
            guard !targets.isEmpty else { return false }
            var ok = true
            for g in targets { ok = await LabNet.note(g.broker, scope: "global", text: text) && ok }
            return ok
        }
    }

    @discardableResult
    func hideSetEvent(_ card: LabSetCard, target: String) async -> Bool {
        await act { await LabNet.hide(card.broker, target: target, set: card.brief.set.id) }
    }

    /// Hide one guidance entry; a merged broadcast hides every visible replica.
    @discardableResult
    func hide(_ entry: LabGuidanceNote) async -> Bool {
        if let card = entry.card { return await hideSetEvent(card, target: entry.note.id) }
        let replicas = entry.replicas.isEmpty
            ? entry.group.map { [LabGuidanceNote.Replica(group: $0, note: entry.note)] } ?? []
            : entry.replicas.filter { !$0.note.hidden }
        return await act {
            guard !replicas.isEmpty else { return false }
            var ok = true
            for r in replicas {
                ok = await LabNet.hide(r.group.broker, target: r.note.id, scope: r.note.scope, project: r.note.project ?? "") && ok
            }
            return ok
        }
    }

    /// Optimistic switch with rollback; the Mac broker owns the state.
    func setUnattended(_ on: Bool) async {
        guard !unattendedUpdating else { return }
        guard let mac = fleet?.syncHost else {
            unattendedError = "The Mac broker is not available."
            return
        }
        let previous = unattended
        unattended = on
        unattendedUpdating = true
        unattendedError = nil
        let ok = await LabNet.setUnattended(mac, on)
        unattendedUpdating = false
        if ok {
            try? await Task.sleep(nanoseconds: 750_000_000)
            await refresh()
        } else {
            unattended = previous
            unattendedError = "The Mac broker could not change Unattended Mode."
        }
    }
}
