import Foundation
import CryptoKit

/// Versioned, transport-independent messages. Neither side evaluates shell/code.
public enum ArgusJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([ArgusJSON]), object([String: ArgusJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([ArgusJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ArgusJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [ArgusJSON]? { if case .array(let v) = self { return v }; return nil }
    public var object: [String: ArgusJSON]? { if case .object(let v) = self { return v }; return nil }
    public subscript(_ key: String) -> ArgusJSON { object?[key] ?? .null }
    public static func encode<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: ArgusWire.encoder().encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: ArgusWire.encoder().encode(self))
    }
    public var revision: String {
        // Content-addressed revision, shared with UI/phone edits; never a CLI-only counter.
        let data = (try? ArgusWire.encoder().encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ArgusWire {
    public static let version = 1
    public static let maxRequestBytes = 1_048_576
    public static let maxResponseBytes = 4_194_304
    public static func readFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ArgusFailure("store_too_large", "Local control store exceeded its bounded size: \(url.lastPathComponent)") }
        return data
    }
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

public struct ArgusRequest: Codable, Sendable {
    public var version: Int = ArgusWire.version
    public var id: String
    public var method: String
    public var params: [String: ArgusJSON]
    /// Attribution only, NOT authentication or an agent security boundary.
    public var actor: String
    public init(id: String = UUID().uuidString, method: String, params: [String: ArgusJSON] = [:], actor: String = "cli") {
        self.id = id; self.method = method; self.params = params; self.actor = actor
    }
    public var fingerprint: String { ArgusJSON.object(["method": .string(method), "params": .object(params), "actor": .string(actor)]).revision }
}

public struct ArgusFailure: Error, Codable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let details: ArgusJSON
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, details: ArgusJSON = .null) {
        self.code = code; self.message = message; self.details = details
    }
}

public struct ArgusResponse: Codable, Sendable {
    public var version = ArgusWire.version
    public let id: String
    public let ok: Bool
    public let result: ArgusJSON?
    public let error: ArgusFailure?
    public init(id: String, result: ArgusJSON) { self.id = id; ok = true; self.result = result; error = nil }
    public init(id: String, error: ArgusFailure) { self.id = id; ok = false; result = nil; self.error = error }
}

public struct ArgusCommand: Codable, Sendable {
    public let name: String
    public let summary: String
    public let positional: [String]
    public let required: [String]
    public let options: [String]
    public let flags: [String]
    public let mutation: Bool
    public init(_ name: String, _ summary: String, positional: [String] = [], required: [String] = [], options: [String] = [], flags: [String] = [], mutation: Bool = false) {
        self.name = name; self.summary = summary; self.positional = positional; self.required = required
        self.options = options; self.flags = flags; self.mutation = mutation
    }
    public static let all: [Self] = [
        .init("status", "App version, local transport, connection health and sync state"),
        .init("doctor", "Read-only local integration diagnostics; never requests OS permissions"),
        .init("capabilities", "Versioned command schemas and limits"),
        .init("context", "Bounded cached briefing; no model calls", options: ["limit"]),
        .init("events.poll", "Replay changes after a cursor; bounded long poll", required: ["after"], options: ["after", "wait"]),
        .init("activity.list", "CLI action audit; no note bodies or credentials", options: ["limit"]),
        .init("sync.conflicts", "Review preserved concurrent workspace edits"),
        .init("sync.resolve", "Submit a reviewed record array; newer changes still conflict", positional: ["key"], required: ["key", "document", "if-revision"], options: ["document", "if-revision"], mutation: true),
        .init("app.state", "Current Argus view and selected session"),
        .init("app.show", "Show an Argus view/session without activating the app", positional: ["view", "id"], required: ["view"], mutation: true),
        .init("app.activate", "Explicitly bring Argus to the foreground", mutation: true),
        .init("sessions.list", "Cached sessions across machines, including stable lifetime IDs", options: ["query", "machine", "limit", "offset"], flags: ["all"]),
        .init("sessions.get", "Resolve one session; ambiguous aliases are errors", positional: ["id"], required: ["id"]),
        .init("command-center.list", "Observed terminal state plus separately identified model summaries", options: ["query", "limit", "offset"], flags: ["needs-attention", "all"]),
        .init("command-center.get", "Get one Command Center card", positional: ["id"], required: ["id"]),
        .init("command-center.refresh", "Schedule a bounded summary refresh", positional: ["id"], mutation: true),
        .init("command-center.correct", "Attributed status correction, not a human acknowledgement", positional: ["id"], required: ["id", "label", "if-revision"], options: ["label", "if-revision"], mutation: true),
        .init("command-center.backlog", "Explicitly move a session into/out of backlog", positional: ["id"], required: ["id", "state"], options: ["state"], mutation: true),
        .init("notes.list", "Notes with revisions", options: ["query", "limit", "offset"]),
        .init("notes.get", "Get a note and its revision", positional: ["id"], required: ["id"]),
        .init("notes.create", "Create a note", required: ["text"], options: ["text"], mutation: true),
        .init("notes.update", "Edit a note only if its revision still matches", positional: ["id"], required: ["id", "text", "if-revision"], options: ["text", "if-revision"], mutation: true),
        .init("notes.complete", "Set a note complete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("notes.reopen", "Set a note incomplete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("notes.archive", "Remove a note with a recoverable copy", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("todos.boards.list", "Todo Maps and pending counts", options: ["query", "limit", "offset"]),
        .init("todos.boards.get", "Get a Todo Map", positional: ["id"], required: ["id"]),
        .init("todos.boards.create", "Create a board for a machine/session label", required: ["machine", "session"], options: ["machine", "session"], mutation: true),
        .init("todos.items.list", "List items across boards or in one board", options: ["board", "query", "limit", "offset"], flags: ["pending"]),
        .init("todos.items.get", "Get an item, parent board and revision", positional: ["id"], required: ["id"]),
        .init("todos.items.create", "Add a todo to a stable board ID", required: ["board", "text"], options: ["board", "text"], mutation: true),
        .init("todos.items.update", "Edit todo text", positional: ["id"], required: ["id", "text", "if-revision"], options: ["text", "if-revision"], mutation: true),
        .init("todos.items.complete", "Set todo complete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("todos.items.reopen", "Set todo incomplete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("todos.items.archive", "Remove todo with a recoverable copy", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("planner.list", "Dated commitments", options: ["query", "limit", "offset"], flags: ["pending"]),
        .init("planner.get", "Get commitment and revision", positional: ["id"], required: ["id"]),
        .init("planner.create", "Create a dated commitment", required: ["title", "deadline"], options: ["title", "project", "deadline"], mutation: true),
        .init("planner.update", "Edit commitment fields", positional: ["id"], required: ["id", "if-revision"], options: ["title", "project", "deadline", "if-revision"], mutation: true),
        .init("planner.complete", "Set commitment complete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("planner.reopen", "Set commitment incomplete", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("planner.archive", "Remove commitment with a recoverable copy", positional: ["id"], required: ["id", "if-revision"], options: ["if-revision"], mutation: true),
        .init("archive.list", "Recoverable CLI deletions", options: ["limit", "offset"]),
        .init("archive.restore", "Restore only if the original ID is still absent", positional: ["id"], required: ["id"], mutation: true),
        .init("weekly-progress.projects.list", "Weekly Progress project definitions", options: ["query", "limit", "offset"]),
        .init("weekly-progress.projects.get", "Get project and revision", positional: ["id"], required: ["id"]),
        .init("weekly-progress.projects.create", "Create project from JSON definition", required: ["document"], options: ["document"], mutation: true),
        .init("weekly-progress.projects.update", "Update project with optimistic concurrency", positional: ["id"], required: ["id", "document", "if-revision"], options: ["document", "if-revision"], mutation: true),
        .init("weekly-progress.list", "Saved report generations", options: ["project", "limit", "offset"]),
        .init("weekly-progress.get", "Generation manifest and local report/deck paths", positional: ["id"], required: ["id"]),
        .init("weekly-progress.generate", "Start an app-owned durable report job", required: ["project", "week"], options: ["project", "week"], mutation: true),
        .init("weekly-progress.resume", "Explicitly resume an interrupted/failed report", positional: ["id"], required: ["id"], mutation: true),
        .init("jobs.list", "Durable Weekly Progress jobs", options: ["limit", "offset"]),
        .init("jobs.get", "Job state; interrupted is distinct from complete", positional: ["id"], required: ["id"]),
    ]
    public func validate(_ params: [String: ArgusJSON]) throws {
        let allowed = Set(positional + options + flags)
        for (key, value) in params {
            guard allowed.contains(key) else { throw ArgusFailure("invalid_arguments", "Unknown option --\(key) for \(name).") }
            guard flags.contains(key) ? value.bool != nil : value.string != nil else {
                throw ArgusFailure("invalid_arguments", "--\(key) has the wrong type.")
            }
        }
        for key in required where params[key]?.string?.isEmpty != false {
            throw ArgusFailure("invalid_arguments", "\(name) requires --\(key).")
        }
    }
}
