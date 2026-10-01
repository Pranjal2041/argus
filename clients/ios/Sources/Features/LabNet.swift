import Foundation

/// Lab HTTP client (cmd/ut-broker /lab/* and /automation/unattended). Reads
/// return nil/empty on any failure; mutations return whether the broker
/// accepted them. Mutations are POSTs with every parameter in the query string.
enum LabNet {
    /// Largest text artifact read into memory.
    static let textCap = 2_000_000
    static let logTail = 16_000

    // MARK: Reads

    static func snapshot(_ broker: Machine) async -> LabBrokerSnapshot {
        async let notesAnswer = get(broker, "lab/notes", as: LabNotesResponse.self)
        async let setsAnswer = get(broker, "lab/sets", as: LabSetsResponse.self)
        async let keysAnswer = get(broker, "lab/keys", as: LabKeysResponse.self)
        async let proposalsAnswer = get(broker, "lab/proposals", as: LabProposalsResponse.self)
        let notes = await notesAnswer
        let metas = (await setsAnswer)?.sets?.compactMap(\.value) ?? []
        // Briefs concurrently, kept in the broker's set order.
        let briefs: [LabBrief] = await withTaskGroup(of: (Int, LabBrief?).self) { group in
            for (i, meta) in metas.enumerated() {
                group.addTask { (i, await get(broker, "lab/brief", ["set": meta.id], as: LabBrief.self)) }
            }
            var found: [(Int, LabBrief)] = []
            for await (i, brief) in group { if let brief { found.append((i, brief)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return LabBrokerSnapshot(
            broker: broker,
            reportedStoreID: notes?.store.flatMap { $0.isEmpty ? nil : $0 },
            briefs: briefs,
            keys: (await keysAnswer)?.keys?.compactMap(\.value) ?? [],
            proposals: (await proposalsAnswer)?.proposals?.compactMap(\.value) ?? [],
            notes: notes.map { $0.notes?.compactMap(\.value) ?? [] })
    }

    static func mirror(_ mac: Machine) async -> [LabMirrored] {
        (await get(mac, "lab/mirror", as: LabMirrorResponse.self))?.mirror?.compactMap(\.value) ?? []
    }

    static func unattended(_ mac: Machine) async -> Bool? {
        (await get(mac, "automation/unattended", as: LabUnattendedState.self))?.enabled
    }

    /// A run's events, stored files, and the small texts every page shows.
    /// Offline (mirrored) cards read events from the Mac's mirror only.
    static func runDetail(broker: Machine, set: String, run: String, offline: Bool, ownerMachine: String) async -> LabRunDetail {
        var q = ["set": set, "run": run]
        if offline { q["machine"] = ownerMachine }
        let events = (await get(broker, "lab/events", q, as: LabEventsResponse.self))?.events?.compactMap(\.value) ?? []
        var detail = LabRunDetail(events: events)
        if offline { return detail }
        detail.files = (await get(broker, "lab/files", ["set": set, "run": run], as: LabFilesResponse.self))?.files?.compactMap(\.value) ?? []
        let names = Set(detail.files.map(\.name))
        var wanted: [(String, Int?)] = ["snapshot/diff.patch", "files/env.txt"].map { ($0, nil) }
        wanted.append(("log.txt", logTail))
        wanted += (detail.envelope?.params ?? []).map { ($0.storedName, nil) }
        let texts = await withTaskGroup(of: (String, String?).self) { group in
            for (name, tail) in wanted where names.contains(name) {
                group.addTask { (name, await fileText(broker: broker, set: set, run: run, name: name, tail: tail)) }
            }
            var out: [String: String] = [:]
            for await (name, text) in group { if let text { out[name] = text } }
            return out
        }
        detail.textByName = texts
        return detail
    }

    /// One stored file as text (lossy UTF-8, capped). `tail` asks the broker
    /// for only the last N bytes, which logs use.
    static func fileText(broker: Machine, set: String, run: String, name: String, tail: Int? = nil) async -> String? {
        var q = ["set": set, "run": run, "name": name]
        if let tail { q["tail"] = String(tail) }
        guard case let (data, response)? = await fetch(URLRequest(url: url(broker, "lab/file", q))), ok(response) else { return nil }
        return String(decoding: data.prefix(textCap), as: UTF8.self)
    }

    // MARK: Mutations

    static func setUnattended(_ mac: Machine, _ enabled: Bool) async -> Bool {
        await post(mac, "automation/unattended", [("enabled", enabled ? "true" : "false")])
    }

    /// Approve or deny an access request. The broker resolves an 8-char prefix;
    /// `policy` (approve only) sets the new set's initial approval policy.
    static func decideKey(_ item: LabPendingKey, approve: Bool, project: String, note: String = "", policy: String = "") async -> Bool {
        await post(item.broker, "lab/decide", [
            ("key", String(item.key.key.prefix(8))), ("approve", approve ? "1" : "0"),
            ("project", project.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("note", note.trimmingCharacters(in: .whitespacesAndNewlines)), ("policy", approve ? policy : ""),
        ])
    }

    static func decideRun(broker: Machine, set: String, run: String, approve: Bool, note: String) async -> Bool {
        await post(broker, "lab/decide-run", [
            ("set", set), ("run", run), ("approve", approve ? "1" : "0"),
            ("note", note.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
    }

    /// scope: global | machine | project | set | run.
    static func note(_ broker: Machine, scope: String, text: String, project: String = "", set: String = "", run: String = "") async -> Bool {
        await post(broker, "lab/note", [
            ("scope", scope), ("text", text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("project", project), ("set", set), ("run", run),
        ])
    }

    /// Hide a set/run event (`set`), or a scope-level note (`scope` + `project`).
    static func hide(_ broker: Machine, target: String, set: String = "", scope: String = "", project: String = "") async -> Bool {
        await post(broker, "lab/hide", [("target", target), ("set", set), ("scope", scope), ("project", project)])
    }

    static func archive(_ card: LabSetCard, run: String = "", on: Bool) async -> Bool {
        await post(card.broker, "lab/archive", [("set", card.brief.set.id), ("run", run), ("on", on ? "1" : "0")])
    }

    static func markStopped(_ card: LabSetCard, run: String, reason: String) async -> Bool {
        await post(card.broker, "lab/mark-stopped", [
            ("set", card.brief.set.id), ("run", run), ("reason", reason.trimmingCharacters(in: .whitespacesAndNewlines)),
        ])
    }

    static func policy(_ card: LabSetCard, _ policy: String) async -> Bool {
        await post(card.broker, "lab/policy", [("set", card.brief.set.id), ("policy", policy)])
    }

    static func revoke(_ card: LabSetCard, key: String) async -> Bool {
        await post(card.broker, "lab/revoke", [("key", String(key.prefix(8)))])
    }

    // MARK: Transport

    private static func get<T: Decodable>(_ m: Machine, _ path: String, _ query: [String: String] = [:], as: T.Type) async -> T? {
        guard case let (data, response)? = await fetch(URLRequest(url: url(m, path, query))), ok(response) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func post(_ m: Machine, _ path: String, _ params: [(String, String)]) async -> Bool {
        var req = URLRequest(url: url(m, path, params.filter { !$0.1.isEmpty }))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        guard case let (_, response)? = await fetch(req) else { return false }
        return ok(response)
    }

    private static func fetch(_ req: URLRequest) async -> (Data, URLResponse)? {
        try? await BrokerHTTP.session.data(for: req)
    }

    private static func ok(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }

    static func url(_ m: Machine, _ path: String, _ query: [String: String]) -> URL {
        url(m, path, query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// Strict form encoding: unlike `URLComponents.queryItems`, "+" and "&" in a
    /// note are escaped, so Go's `Query().Get` returns exactly what was typed.
    static func url(_ m: Machine, _ path: String, _ query: [(String, String)]) -> URL {
        var c = URLComponents(url: m.httpBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.percentEncodedQuery = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        return c.url!
    }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
