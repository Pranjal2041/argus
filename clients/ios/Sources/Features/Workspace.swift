import SwiftUI
import UIKit

// Notes, Todo Maps and Workflows: local-first collections synced with the Mac.
//
// Sync contract (shared with the Mac's WorkspaceSync and Android's syncUserData):
// each collection keeps the last copy both sides agreed on (the baseline) and
// sends `{"base": baseline, "data": local}` to the sync host's /userdata/merge,
// which three-way merges by record id. On 200 the reply is the authoritative
// copy; edits made while the request was in flight are rebased onto it with the
// same WorkspaceMerge the Mac and broker use, and the result plus the new
// baseline are saved together. A 409 (or a rebase conflict) preserves both copies
// for review instead of letting either side win. Nothing syncs without a Mac.

struct WorkspaceMergeReply {
    let status: Int
    let body: ArgusJSON
}

/// How a merge request reaches the sync host. Injectable so the sync engine can
/// be exercised without a live broker.
protocol WorkspaceTransport {
    func merge(key: WorkspaceKey, base: ArgusJSON, data: ArgusJSON) async throws -> WorkspaceMergeReply
}

struct BrokerWorkspaceTransport: WorkspaceTransport {
    let host: URL
    func merge(key: WorkspaceKey, base: ArgusJSON, data: ArgusJSON) async throws -> WorkspaceMergeReply {
        let body = try ArgusWire.encoder().encode(ArgusJSON.object(["base": base, "data": data]))
        let (bytes, response) = try await BrokerHTTP.raw("POST", host, "userdata/merge",
                                                         query: [.init(name: "key", value: key.rawValue)],
                                                         body: body, contentType: "application/json", timeout: 10)
        return WorkspaceMergeReply(status: response.statusCode,
                                   body: (try? JSONDecoder().decode(ArgusJSON.self, from: bytes)) ?? .null)
    }
}

/// Both copies of a collection that could not be merged automatically.
struct WorkspaceConflict: Codable, Equatable {
    var base: ArgusJSON
    var local: ArgusJSON
    var remote: ArgusJSON
    var paths: ArgusJSON = .null
}

/// One collection's durable state. A single file, so the local copy, its sync
/// baseline and any pending review always change together (atomic write).
struct WorkspaceKeyFile: Codable {
    var local: ArgusJSON
    var base: ArgusJSON?
    var conflict: WorkspaceConflict?
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let conflictMessage = "Concurrent edits need review; both copies are preserved."
    static let syncInterval: UInt64 = 6_000_000_000
    static let noteDebounce: UInt64 = 1_000_000_000
    static let failureBackoff: TimeInterval = 30

    @Published private(set) var workflows: [WorkspaceWorkflow] = []
    @Published private(set) var todos: [TodoBoard] = []
    @Published private(set) var notes: [WorkspaceNote] = []
    @Published private(set) var conflicts: [WorkspaceKey: WorkspaceConflict] = [:]
    @Published private(set) var issues: [WorkspaceKey: String] = [:]
    @Published private(set) var lastSynced: [WorkspaceKey: Date] = [:]
    @Published private(set) var syncing: Set<WorkspaceKey> = []
    /// A workflow run that failed after its terminal opened.
    @Published var runError: String?

    /// The Misc board is shown even before one exists and is only stored once a
    /// task is added to it, so a phone that hasn't synced yet doesn't create a
    /// second Misc board next to the Mac's.
    let placeholderMiscID = WorkspaceID.new()

    private(set) var bases: [WorkspaceKey: ArgusJSON] = [:]
    private var failedUntil: [WorkspaceKey: Date] = [:]
    private var resyncAfterFlight: Set<WorkspaceKey> = []
    private var scheduled: [WorkspaceKey: Task<Void, Never>] = [:]
    private let directory: URL?
    private weak var fleet: FleetStore?
    private weak var router: AppRouter?
    private var loop: Task<Void, Never>?
    private var active = true
    private var observers: [NSObjectProtocol] = []
    var makeTransport: (Machine) -> WorkspaceTransport = { BrokerWorkspaceTransport(host: $0.httpBase) }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Workspace", isDirectory: true)
    }

    /// `directory` nil keeps everything in memory (tests).
    init(directory: URL? = WorkspaceStore.defaultDirectory) {
        self.directory = directory
        for key in WorkspaceKey.allCases { load(key) }
    }

    // MARK: Lifecycle

    func start(fleet: FleetStore, router: AppRouter) {
        guard loop == nil else { return }
        self.fleet = fleet
        self.router = router
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.active = true; self?.syncAll() }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.active = false; self?.flushInBackground() }
            },
        ]
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.active == true { self?.syncAll() }
                try? await Task.sleep(nanoseconds: Self.syncInterval)
            }
        }
    }

    /// Kick off a sync of every collection (no-op without a reachable Mac).
    func syncAll() {
        for key in WorkspaceKey.allCases { Task { await self.sync(key) } }
    }

    /// Let pending edits (e.g. a debounced note) reach the Mac as the app leaves.
    private func flushInBackground() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "workspace-sync")
        Task {
            for key in WorkspaceKey.allCases { scheduled[key]?.cancel(); await sync(key) }
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: Sync engine

    /// The phone's copy of a collection, in the Mac's encoding.
    func read(_ key: WorkspaceKey) -> ArgusJSON {
        switch key {
        case .workflows: return WorkspaceCodec.encode(workflows)
        case .todos: return WorkspaceCodec.encode(todos)
        case .notes: return WorkspaceCodec.encode(notes)
        }
    }

    var hasSyncHost: Bool { fleet?.syncHost != nil }

    /// Banner text for a collection: a pending review wins over a transient error.
    func banner(for key: WorkspaceKey) -> String? {
        conflicts[key] != nil ? Self.conflictMessage : issues[key]
    }

    func sync(_ key: WorkspaceKey) async {
        guard let fleet, let host = fleet.syncHost, fleet.reachable.contains(host.id) else { return }
        await sync(key, via: makeTransport(host))
    }

    func sync(_ key: WorkspaceKey, via transport: WorkspaceTransport) async {
        if var conflict = conflicts[key] {
            // Under review: keep the preserved phone copy current; send nothing.
            let current = read(key)
            if conflict.local != current {
                conflict.local = current
                conflicts[key] = conflict
                try? persist(key)
            }
            return
        }
        guard !syncing.contains(key) else { resyncAfterFlight.insert(key); return }
        guard failedUntil[key, default: .distantPast] <= Date() else { return }
        let base = bases[key] ?? .array([])
        let sent = read(key)
        syncing.insert(key)
        defer {
            syncing.remove(key)
            if resyncAfterFlight.remove(key) != nil { scheduleSync(key) }
        }
        do {
            let reply = try await transport.merge(key: key, base: base, data: sent)
            if reply.status == 409, reply.body["current"].array != nil {
                try recordConflict(key, base: base, remote: reply.body["current"], paths: reply.body["conflicts"])
                return
            }
            guard reply.status == 200, reply.body["data"].array != nil else {
                let detail = reply.body["message"].string ?? reply.body["error"].string
                throw ArgusFailure("sync_failed", "Your Mac answered HTTP \(reply.status)\(detail.map { " (\($0))" } ?? ""). Local edits are kept.")
            }
            let remote = reply.body["data"]
            try WorkspaceCodec.validate(key, remote, strict: false)
            let merged: ArgusJSON
            do {
                // Rebase whatever changed locally while the request was in flight.
                merged = try WorkspaceMerge.merge(base: sent, local: read(key), remote: remote)
            } catch let failure as ArgusFailure where failure.code == "conflict" {
                try recordConflict(key, base: sent, remote: remote, paths: failure.details)
                return
            }
            try commit(key, local: merged, base: remote)
            issues[key] = nil
            failedUntil[key] = nil
            lastSynced[key] = Date()
        } catch {
            issues[key] = (error as? ArgusFailure)?.message
                ?? "Couldn't sync with your Mac: \(error.localizedDescription). Local edits are kept."
            failedUntil[key] = Date().addingTimeInterval(Self.failureBackoff)
        }
    }

    /// Save a reviewed resolution: it becomes the local copy, and the reviewed
    /// Mac copy becomes the baseline, so the next sync is an ordinary three-way
    /// merge against anything the Mac changed since.
    func resolveConflict(_ key: WorkspaceKey, document: String) throws {
        guard let conflict = conflicts[key] else { throw WorkspaceCodec.failure("There is nothing left to review.") }
        guard let value = try? JSONDecoder().decode(ArgusJSON.self, from: Data(document.utf8)) else {
            throw WorkspaceCodec.failure("That isn't valid JSON.")
        }
        try WorkspaceCodec.validate(key, value, strict: true)
        let current = read(key)
        guard current == conflict.local else {
            conflicts[key]?.local = current
            try? persist(key)
            throw WorkspaceCodec.failure("The phone copy changed during review. Review it again.")
        }
        try commit(key, local: value, base: conflict.remote, clearConflict: true)
        issues[key] = nil
        failedUntil[key] = nil
        scheduleSync(key)
    }

    func retry(_ key: WorkspaceKey) {
        failedUntil[key] = nil
        scheduleSync(key)
    }

    private func recordConflict(_ key: WorkspaceKey, base: ArgusJSON, remote: ArgusJSON, paths: ArgusJSON) throws {
        conflicts[key] = WorkspaceConflict(base: base, local: read(key), remote: remote, paths: paths)
        issues[key] = nil
        try persist(key)
    }

    /// Persist the new local copy and baseline first, then adopt them in memory.
    private func commit(_ key: WorkspaceKey, local: ArgusJSON, base: ArgusJSON, clearConflict: Bool = false) throws {
        let (json, adopt) = try decoded(key, local)
        try write(key, WorkspaceKeyFile(local: json, base: base, conflict: clearConflict ? nil : conflicts[key]))
        if json != read(key) { adopt() }
        bases[key] = base
        if clearConflict { conflicts[key] = nil }
    }

    private func decoded(_ key: WorkspaceKey, _ value: ArgusJSON) throws -> (ArgusJSON, () -> Void) {
        switch key {
        case .workflows:
            let v = try value.decode([WorkspaceWorkflow].self)
            return (WorkspaceCodec.encode(v), { self.workflows = v })
        case .todos:
            let v = try value.decode([TodoBoard].self)
            return (WorkspaceCodec.encode(v), { self.todos = v })
        case .notes:
            let v = try value.decode([WorkspaceNote].self)
            return (WorkspaceCodec.encode(v), { self.notes = v })
        }
    }

    /// Sync soon: `delay` coalesces bursts (note typing). Only the wait is
    /// cancellable; a request, once sent, always completes.
    private func scheduleSync(_ key: WorkspaceKey, delay: UInt64 = 0) {
        scheduled[key]?.cancel()
        scheduled[key] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            Task { await self?.sync(key) }
        }
    }

    // MARK: Persistence

    private func fileURL(_ key: WorkspaceKey) -> URL? { directory?.appendingPathComponent(key.rawValue + ".json") }

    private func load(_ key: WorkspaceKey) {
        guard let url = fileURL(key), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(WorkspaceKeyFile.self, from: Data(contentsOf: url))
            let (_, adopt) = try decoded(key, file.local)
            adopt()
            bases[key] = file.base
            conflicts[key] = file.conflict
        } catch {
            // Set the unreadable copy aside (never delete it) and start with no
            // baseline: the first sync can then only add the Mac's records.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            issues[key] = "\(key.title) saved on this iPhone couldn't be read (kept as \(aside.lastPathComponent)); refilling from your Mac."
        }
    }

    private func persist(_ key: WorkspaceKey) throws {
        try write(key, WorkspaceKeyFile(local: read(key), base: bases[key], conflict: conflicts[key]))
    }

    private func write(_ key: WorkspaceKey, _ file: WorkspaceKeyFile) throws {
        guard let directory, let url = fileURL(key) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ArgusWire.encoder().encode(file).write(to: url, options: .atomic)
    }

    /// Save a local edit, then sync (debounced for typing).
    private func changed(_ key: WorkspaceKey, debounce: Bool = false) {
        do { try persist(key) } catch {
            issues[key] = "Couldn't save \(key.title) on this iPhone: \(error.localizedDescription)"
        }
        scheduleSync(key, delay: debounce ? Self.noteDebounce : 0)
    }

    // MARK: Notes

    @discardableResult
    func addNote(text: String = "") -> String {
        let note = WorkspaceNote(text: text)
        notes.append(note)
        changed(.notes, debounce: true)
        return note.id
    }

    /// `editedAt` moves only when the text actually changes.
    func updateNoteText(_ id: String, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        notes[i].editedAt = WorkspaceClock.now()
        changed(.notes, debounce: true)
    }

    func toggleNote(_ id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].done.toggle()
        changed(.notes)
    }

    func deleteNote(_ id: String) {
        guard notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        changed(.notes)
    }

    // MARK: Todo Maps

    /// Boards in display order (Misc first, then live sessions, then by name);
    /// boards with only finished tasks are hidden unless `showFinished`.
    func displayBoards(showFinished: Bool) -> [TodoBoard] {
        var boards = todos
        if !boards.contains(where: \.isMisc) { boards.append(TodoBoard(id: placeholderMiscID, isMisc: true)) }
        return WorkspaceRules.orderBoards(boards, showFinished: showFinished) { self.liveSession(for: $0) != nil }
    }

    /// The running session a board points at, if any.
    func liveSession(for board: TodoBoard) -> (Machine, SessionInfo)? {
        guard !board.isMisc, let fleet else { return nil }
        let hostID = fleet.syncHost?.id
        for m in fleet.machines where WorkspaceRules.boardMachine(board.machine, matches: m, syncHostID: hostID) {
            if let s = fleet.session(on: m, named: board.session) { return (m, s) }
        }
        return nil
    }

    /// Creates the board for machine + session unless one exists; returns its id.
    @discardableResult
    func ensureBoard(machine: String, session: String) -> String? {
        let m = machine.trimmingCharacters(in: .whitespaces), s = session.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let existing = todos.first(where: { !$0.isMisc && $0.machine == m && $0.session == s }) { return existing.id }
        let board = TodoBoard(machine: m, session: s)
        todos.append(board)
        changed(.todos)
        return board.id
    }

    func addTodo(_ boardID: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = todos.firstIndex(where: { $0.id == boardID }) {
            todos[i].items.append(TodoItem(text: t))
        } else if boardID == placeholderMiscID {
            todos.append(TodoBoard(id: placeholderMiscID, isMisc: true, items: [TodoItem(text: t)]))
        } else { return }
        changed(.todos)
    }

    func toggleTodo(_ boardID: String, _ itemID: String) {
        guard let (b, i) = itemIndex(boardID, itemID) else { return }
        todos[b].items[i].done.toggle()
        todos[b].items[i].completedAt = todos[b].items[i].done ? WorkspaceClock.now() : nil
        changed(.todos)
    }

    func editTodo(_ boardID: String, _ itemID: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let (b, i) = itemIndex(boardID, itemID), todos[b].items[i].text != t else { return }
        todos[b].items[i].text = t
        changed(.todos)
    }

    func deleteTodo(_ boardID: String, _ itemID: String) {
        guard let (b, _) = itemIndex(boardID, itemID) else { return }
        todos[b].items.removeAll { $0.id == itemID }
        changed(.todos)
    }

    func clearCompleted(_ boardID: String) {
        guard let b = todos.firstIndex(where: { $0.id == boardID }), todos[b].items.contains(where: \.done) else { return }
        todos[b].items.removeAll(where: \.done)
        changed(.todos)
    }

    /// The Misc board is permanent.
    func deleteBoard(_ boardID: String) {
        guard todos.contains(where: { $0.id == boardID && !$0.isMisc }) else { return }
        todos.removeAll { $0.id == boardID && !$0.isMisc }
        changed(.todos)
    }

    private func itemIndex(_ boardID: String, _ itemID: String) -> (Int, Int)? {
        guard let b = todos.firstIndex(where: { $0.id == boardID }),
              let i = todos[b].items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return (b, i)
    }

    // MARK: Workflows

    func saveWorkflow(_ wf: WorkspaceWorkflow) {
        if let i = workflows.firstIndex(where: { $0.id == wf.id }) {
            guard workflows[i] != wf else { return }
            workflows[i] = wf
        } else {
            workflows.append(wf)
        }
        changed(.workflows)
    }

    func deleteWorkflow(_ id: String) {
        guard workflows.contains(where: { $0.id == id }) else { return }
        workflows.removeAll { $0.id == id }
        changed(.workflows)
    }

    /// Reachable machines a workflow's pattern selects.
    func machines(for wf: WorkspaceWorkflow) -> [Machine] {
        guard let fleet else { return [] }
        return WorkspaceRules.machines(matching: wf.machine, in: fleet.machines.filter { fleet.reachable.contains($0.id) })
    }

    /// Suggestions for a workflow's machine field, in the Mac's vocabulary.
    var machineSuggestions: [String] {
        guard let fleet else { return ["this mac"] }
        var out = ["this mac"]
        for m in fleet.machines where m.id != fleet.syncHost?.id && !out.contains(m.name) { out.append(m.name) }
        return out
    }

    /// Open the workflow's session on `m`, creating it and typing its folder and
    /// commands if it isn't running yet. Throws only before the terminal opens;
    /// later failures land in `runError`.
    func run(_ wf: WorkspaceWorkflow, on m: Machine) async throws {
        guard let fleet, let router else { return }
        if let existing = fleet.session(on: m, named: wf.name) {
            router.openTerminal(m, existing)
            return
        }
        do { try await fleet.createSession(on: m, name: wf.name) } catch {
            throw WorkspaceCodec.failure("Couldn't create session “\(wf.name)” on \(m.name): \(error.localizedDescription)")
        }
        let session = fleet.session(on: m, named: wf.name) ?? SessionInfo(name: wf.name)
        router.openTerminal(m, session)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let the shell come up
        for (n, line) in WorkspaceRules.workflowLines(wf).enumerated() {
            if n > 0 { try? await Task.sleep(nanoseconds: 250_000_000) }
            do { try await fleet.send(line, to: session, on: m) } catch {
                runError = "“\(wf.name)” stopped at “\(line)”: \(error.localizedDescription)"
                return
            }
        }
    }
}
