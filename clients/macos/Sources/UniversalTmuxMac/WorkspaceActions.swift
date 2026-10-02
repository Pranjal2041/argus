import Foundation
import ArgusProtocol

enum WorkspaceActionOrigin: Equatable { case human, agent(String) }

/// Common presentation boundary. Selecting a target and activating the macOS app
/// are deliberately separate actions. No global keyboard/mouse events are used.
enum WorkspaceDestination: String, CaseIterable {
    case commandCenter = "command-center", session, notes, todos, planner
    case weeklyProgress = "weekly-progress", artifacts, webArtifacts = "web-artifacts", lab, ledger, usage
}

extension AppState {
    var workspaceDestination: WorkspaceDestination {
        if showUsage { return .usage }
        if showWebArtifacts { return .webArtifacts }
        if showArtifacts { return .artifacts }
        if showWeeklyProgress { return .weeklyProgress }
        if showPlanner { return .planner }
        if showLab { return .lab }
        if showLedger { return .ledger }
        if showNotes { return .notes }
        if showTodos { return .todos }
        return showOverview ? .commandCenter : .session
    }

    func navigate(to destination: WorkspaceDestination, session ref: SessionRef? = nil,
                  origin: WorkspaceActionOrigin = .human) throws {
        if destination == .session {
            guard let ref,
                  (sessionsByMachine[ref.machineID] ?? []).contains(where: { $0.name == ref.session }) else {
                throw ArgusFailure("not_found", "The requested session is not in the current app snapshot.")
            }
        }
        let previous = navigationOrigin; navigationOrigin = origin
        defer { navigationOrigin = previous }
        if destination == .session { selection = ref }
        showOverview = destination == .commandCenter
        showNotes = destination == .notes; showTodos = destination == .todos
        showPlanner = destination == .planner; showWeeklyProgress = destination == .weeklyProgress
        showArtifacts = destination == .artifacts; showWebArtifacts = destination == .webArtifacts
        showLab = destination == .lab; showLedger = destination == .ledger
        showUsage = destination == .usage
        renderDocument = nil
        navigationRevision &+= 1
    }

    func updateTodoText(_ boardID: UUID, _ itemID: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bi = todoBoards.firstIndex(where: { $0.id == boardID }),
              let ii = todoBoards[bi].items.firstIndex(where: { $0.id == itemID }) else { return }
        todoBoards[bi].items[ii].text = text
    }
}

struct ArgusStoredRequest: Codable {
    var fingerprint: String
    var method: String
    var actor: String
    var date: Date
    var response: ArgusResponse?
}

struct ArgusArchivedRecord: Codable {
    var id = UUID()
    var kind: String
    var record: ArgusJSON
    var parentID: String?
    var date = Date()
    var restored = false
}

/// This is an action receipt/archive, NOT another notes database. A durable
/// reservation precedes every action. A crash in the acknowledgement window is
/// reported as uncertain rather than blindly replaying a possibly accepted action.
@MainActor
final class ArgusActionJournal {
    struct State: Codable {
        var requests: [String: ArgusStoredRequest] = [:]
        var archives: [ArgusArchivedRecord] = []
    }
    private(set) var state: State
    private let url: URL?
    init(url: URL?) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(State.self, from: ArgusWire.readFile(url, limit: 32 * 1024 * 1024))
        } else { state = State() }
    }
    func replay(_ request: ArgusRequest) throws -> ArgusResponse? {
        guard let entry = state.requests[request.id] else { return nil }
        guard entry.fingerprint == request.fingerprint else {
            throw ArgusFailure("request_id_reused", "This request ID was already used with different arguments or attribution.")
        }
        guard let response = entry.response else {
            throw ArgusFailure("outcome_unknown", "This request was accepted but has no durable completion receipt. Inspect the target (or Weekly Progress jobs); it will not be executed twice.")
        }
        return response
    }
    func reserve(_ request: ArgusRequest) throws {
        guard state.requests.count < 10_000 else { throw ArgusFailure("journal_full", "The 10,000-action receipt limit was reached. Existing receipts are retained; no action was executed.") }
        var next = state
        next.requests[request.id] = ArgusStoredRequest(fingerprint: request.fingerprint, method: request.method, actor: request.actor, date: Date())
        try save(next)
    }
    func finish(_ request: ArgusRequest, _ response: ArgusResponse) throws {
        var next = state; next.requests[request.id]?.response = response; try save(next)
    }
    func archive(kind: String, record: ArgusJSON, parentID: String? = nil) throws -> UUID {
        var next = state
        let entry = ArgusArchivedRecord(kind: kind, record: record, parentID: parentID)
        next.archives.append(entry); try save(next); return entry.id
    }
    func markRestored(_ id: UUID) throws {
        var next = state
        if let i = next.archives.firstIndex(where: { $0.id == id }) { next.archives[i].restored = true }
        try save(next)
    }
    private func save(_ next: State) throws {
        let bytes = try ArgusWire.encoder().encode(next)
        guard bytes.count <= 32 * 1024 * 1024 else { throw ArgusFailure("journal_full", "The action journal is full. No further mutation will be accepted.") }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        state = next
    }
}

@MainActor
final class ArgusEventLog {
    struct State: Codable {
        var epoch = UUID().uuidString
        var sequence: UInt64 = 0
        var events: [ArgusJSON] = []
    }
    private var state: State
    private let url: URL?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var persistenceError: String?
    var cursor: String { "\(state.epoch):\(state.sequence)" }
    init(url: URL?) throws {
        self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: ArgusWire.readFile(url, limit: 2 * 1024 * 1024))
        } else { state = State() }
    }
    func append(_ type: String, actor: String, entity: String? = nil) {
        state.sequence += 1
        state.events.append(.object(["cursor": .string(cursor), "type": .string(type), "actor": .string(actor),
                                     "entity": entity.map(ArgusJSON.string) ?? .null,
                                     "at": .string(ISO8601DateFormatter().string(from: Date()))]))
        state.events = Array(state.events.suffix(1024))
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try ArgusWire.encoder().encode(state).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                persistenceError = nil
            } catch { persistenceError = error.localizedDescription }
        }
        let ready = waiters.values; waiters.removeAll(); for waiter in ready { waiter.resume() }
    }
    func read(after cursor: String, wait: Int) async throws -> ArgusJSON {
        let sequence = try validate(cursor)
        if sequence == state.sequence && wait > 0 {
            guard waiters.count < 8 else { throw ArgusFailure("too_many_subscribers", "At most eight event subscribers may wait at once.") }
            let id = UUID()
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                    self?.waiters.removeValue(forKey: id)?.resume()
                }
            }
        }
        _ = try validate(cursor) // A slow reader must not silently skip evicted events.
        let count = Int(state.sequence - sequence)
        return .object(["events": .array(Array(state.events.suffix(count))), "cursor": .string(self.cursor),
                        "durable": .bool(persistenceError == nil)])
    }
    private func validate(_ cursor: String) throws -> UInt64 {
        let parts = cursor.split(separator: ":")
        guard parts.count == 2, parts[0] == state.epoch, let n = UInt64(parts[1]), n <= state.sequence,
              state.sequence - n <= UInt64(state.events.count) else {
            throw ArgusFailure("cursor_expired", "The event cursor is invalid or outside retained history. Read argus context again and watch from its cursor.")
        }
        return n
    }
}
