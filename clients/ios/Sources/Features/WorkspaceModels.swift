import Foundation

// Notes, Todo Maps and Workflows: user-global collections synced through the Mac
// broker's /userdata/merge. The record shapes are the Mac's Codable models
// (clients/macos/Sources/UniversalTmuxMac/Model.swift) and Android's UserData.kt,
// field for field: ids are canonical (uppercase) UUID strings and dates are
// ISO-8601 with whole seconds and "Z". Encoding goes through ArgusJSON /
// ArgusWire, the same encoder the Mac uses, so the phone's bytes are the Mac's.

enum WorkspaceKey: String, CaseIterable, Codable, Identifiable {
    case workflows, todos, notes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .workflows: return "Workflows"
        case .todos: return "Todo Maps"
        case .notes: return "Notes"
        }
    }
}

enum WorkspaceClock {
    /// Now, truncated to whole seconds: what the wire format can represent, so
    /// an in-memory value always equals its own encode/decode round-trip.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }
}

enum WorkspaceID {
    static func new() -> String { UUID().uuidString }   // Foundation emits canonical uppercase
}

struct WorkspaceWorkflow: Identifiable, Codable, Hashable {
    var id: String = WorkspaceID.new()
    var name = ""
    var machine = ""      // wildcard pattern: "babel-*", "this mac", an exact name
    var folder = ""       // working directory, "~" forms expanded by the shell
    var commands = ""     // one command per line
    var notes = ""
    var colorHex = ""     // "" = default accent
}

struct TodoItem: Identifiable, Codable, Hashable {
    var id: String = WorkspaceID.new()
    var text = ""
    var done = false
    var createdAt = WorkspaceClock.now()
    var completedAt: Date?   // synthesized encoding omits nil (never `null`), like the Mac
}

struct TodoBoard: Identifiable, Codable, Hashable {
    var id: String = WorkspaceID.new()
    var machine = ""
    var session = ""
    var isMisc = false
    var items: [TodoItem] = []
    var pending: Int { items.lazy.filter { !$0.done }.count }
}

struct WorkspaceNote: Identifiable, Codable, Hashable {
    var id: String
    var text: String
    var done: Bool
    var createdAt: Date
    var editedAt: Date   // last content edit: drives grouping and sort

    init(id: String = WorkspaceID.new(), text: String = "", done: Bool = false,
         createdAt: Date = WorkspaceClock.now(), editedAt: Date? = nil) {
        self.id = id; self.text = text; self.done = done
        self.createdAt = createdAt; self.editedAt = editedAt ?? createdAt
    }

    // Decode-tolerant exactly like the Mac's Note: notes written before `editedAt`
    // existed fall back to `createdAt`. The id is required (validated as a UUID).
    enum CodingKeys: String, CodingKey { case id, text, done, createdAt, editedAt }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? WorkspaceClock.now()
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt) ?? createdAt
    }
}

// MARK: Codec + validation

enum WorkspaceCodec {
    static func encode<T: Encodable>(_ value: T) -> ArgusJSON {
        // Encoding plain structs of strings/bools/dates cannot fail.
        (try? ArgusJSON.encode(value)) ?? .array([])
    }

    /// Checks a collection before it may replace local data or a sync baseline.
    /// Every record needs a unique UUID id (todo item ids unique across boards)
    /// and must decode as the model. `strict` (for hand-edited review documents)
    /// also requires canonical ids and that the document re-encodes to itself, so
    /// unknown fields or non-canonical values are rejected instead of being
    /// silently dropped.
    static func validate(_ key: WorkspaceKey, _ value: ArgusJSON, strict: Bool) throws {
        guard let rows = value.array else { throw failure("Workspace data must be a JSON array of records.") }
        var ids = Set<String>(), itemIDs = Set<String>()
        func check(_ record: ArgusJSON, _ seen: inout Set<String>) throws {
            guard let raw = record["id"].string, let id = UUID(uuidString: raw) else {
                throw failure("Every record needs an \"id\" that is a UUID.")
            }
            if strict, raw != id.uuidString { throw failure("Record id \(raw) must be an uppercase UUID.") }
            guard seen.insert(id.uuidString).inserted else { throw failure("Duplicate record id \(raw).") }
        }
        for row in rows {
            try check(row, &ids)
            if key == .todos {
                guard let items = row["items"].array else { throw failure("Every todo board needs an \"items\" array.") }
                for item in items { try check(item, &itemIDs) }
            }
        }
        let canonical: ArgusJSON
        do { canonical = try reencode(key, value) } catch {
            throw failure("Records don't match the \(key.rawValue) format: \(error.localizedDescription)")
        }
        if strict, canonical != value {
            throw failure("The document has unsupported fields or invalid values. Both copies are kept.")
        }
    }

    /// Decode as the model and encode again (the representation the Mac stores).
    static func reencode(_ key: WorkspaceKey, _ value: ArgusJSON) throws -> ArgusJSON {
        switch key {
        case .workflows: return encode(try value.decode([WorkspaceWorkflow].self))
        case .todos: return encode(try value.decode([TodoBoard].self))
        case .notes: return encode(try value.decode([WorkspaceNote].self))
        }
    }

    static func pretty(_ value: ArgusJSON) -> String {
        guard let data = try? ArgusWire.encoder(pretty: true).encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func failure(_ message: String) -> ArgusFailure { ArgusFailure("invalid_arguments", message) }
}

// MARK: Pure rules shared by the views and the tests

enum WorkspaceRules {
    static let macAliases: Set<String> = ["this mac", "mac", "local"]
    static let swatches = ["", "#E5484D", "#F5A623", "#30A46C", "#3B82F6", "#8B5CF6", "#EC4899"]

    static func isMacAlias(_ s: String) -> Bool { macAliases.contains(s.trimmingCharacters(in: .whitespaces).lowercased()) }

    /// Machines a workflow pattern selects. "this mac" / "mac" / "local" mean the
    /// darwin machines; anything else is a case-insensitive full match where `*`
    /// is any run of characters (the Mac's `machinesMatching`).
    static func machines(matching pattern: String, in machines: [Machine]) -> [Machine] {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return [] }
        if isMacAlias(p) { return machines.filter { $0.os == "darwin" } }
        let rx = "^" + NSRegularExpression.escapedPattern(for: p).replacingOccurrences(of: "\\*", with: ".*") + "$"
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return [] }
        return machines.filter { re.firstMatch(in: $0.name, range: NSRange($0.name.startIndex..., in: $0.name)) != nil }
    }

    /// A `cd` line: a leading `~` stays unquoted so the shell expands it; anything
    /// else is single-quoted so spaces and quotes survive.
    static func cdCommand(_ folder: String) -> String {
        if folder == "~" || folder.hasPrefix("~/") { return "cd " + folder }
        return "cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The lines a workflow types into its fresh session.
    static func workflowLines(_ wf: WorkspaceWorkflow) -> [String] {
        var lines: [String] = []
        let folder = wf.folder.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { lines.append(cdCommand(folder)) }
        lines += wf.commands.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines
    }

    /// Whether a todo board's machine string names this machine. Boards created
    /// on the Mac name its own machine "this mac"; that resolves to the sync host.
    static func boardMachine(_ boardMachine: String, matches m: Machine, syncHostID: String?) -> Bool {
        let b = boardMachine.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return false }
        if isMacAlias(b) { return m.id == syncHostID }
        if m.name == b { return true }
        let want = FleetStore.normalizedHost(b)
        return !want.isEmpty && FleetStore.normalizedHost(m.name) == want
    }

    /// The machine string written into a board or workflow for `m`, chosen so the
    /// Mac resolves it too: the sync host is "this mac" there.
    static func machineLabel(for m: Machine, syncHostID: String?) -> String {
        m.id == syncHostID ? "this mac" : m.name
    }

    /// Every Misc board first, then session boards: live ones first, then by
    /// session and machine name. Boards whose tasks are all finished are hidden
    /// unless `showFinished` (empty boards always show).
    static func orderBoards(_ boards: [TodoBoard], showFinished: Bool, isLive: (TodoBoard) -> Bool) -> [TodoBoard] {
        let misc = boards.filter(\.isMisc).sorted { $0.id < $1.id }
        let rest = boards.filter { !$0.isMisc && (showFinished || $0.items.isEmpty || $0.pending > 0) }
            .map { (board: $0, live: isLive($0)) }
            .sorted { a, b in
                if a.live != b.live { return a.live }
                let an = a.board.session.lowercased(), bn = b.board.session.lowercased()
                if an != bn { return an < bn }
                let am = a.board.machine.lowercased(), bm = b.board.machine.lowercased()
                return am != bm ? am < bm : a.board.id < b.board.id
            }
        return misc + rest.map(\.board)
    }

    /// Pending first (oldest first), then finished (most recently finished first).
    static func sortedItems(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { a, b in
            if a.done != b.done { return !a.done }
            if a.done {
                let ad = a.completedAt ?? a.createdAt, bd = b.completedAt ?? b.createdAt
                if ad != bd { return ad > bd }
            } else if a.createdAt != b.createdAt {
                return a.createdAt < b.createdAt
            }
            return a.id < b.id
        }
    }

    enum NoteBucket: Int, CaseIterable, Identifiable {
        case today, yesterday, thisWeek, thisMonth, earlier
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "Earlier this week"
            case .thisMonth: return "This month"
            case .earlier: return "Earlier"
            }
        }
    }

    /// Android's buckets: weeks start on Monday regardless of locale.
    static func bucket(of date: Date, now: Date, calendar: Calendar = .current) -> NoteBucket {
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        if day >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day >= yesterday { return .yesterday }
        let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7   // weekday: Sunday = 1
        if let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: today), day >= monday { return .thisWeek }
        if calendar.isDate(day, equalTo: today, toGranularity: .month) { return .thisMonth }
        return .earlier
    }

    /// Notes grouped by bucket, newest edit first, empty buckets omitted.
    static func groupedNotes(_ notes: [WorkspaceNote], now: Date, calendar: Calendar = .current) -> [(NoteBucket, [WorkspaceNote])] {
        let byBucket = Dictionary(grouping: notes) { bucket(of: $0.editedAt, now: now, calendar: calendar) }
        return NoteBucket.allCases.compactMap { b in
            guard let ns = byBucket[b], !ns.isEmpty else { return nil }
            return (b, ns.sorted { $0.editedAt != $1.editedAt ? $0.editedAt > $1.editedAt : $0.id < $1.id })
        }
    }
}
