import XCTest
@testable import Argus

/// A sync host that behaves like the broker's /userdata/merge: three-way merge
/// of the request against what it stores, 200 with the stored envelope or 409
/// with `current`. Hooks let a test edit the phone while a request is in flight.
@MainActor
final class FakeSyncHost: WorkspaceTransport {
    var stored: [WorkspaceKey: ArgusJSON] = [:]
    var requests: [(key: WorkspaceKey, base: ArgusJSON, data: ArgusJSON)] = []
    var duringFlight: (() -> Void)?
    var failWith: Int?

    nonisolated func merge(key: WorkspaceKey, base: ArgusJSON, data: ArgusJSON) async throws -> WorkspaceMergeReply {
        try await handle(key: key, base: base, data: data)
    }

    private func handle(key: WorkspaceKey, base: ArgusJSON, data: ArgusJSON) async throws -> WorkspaceMergeReply {
        requests.append((key, base, data))
        duringFlight?()
        duringFlight = nil
        if let failWith { return WorkspaceMergeReply(status: failWith, body: .object(["error": .string("boom")])) }
        let current = stored[key] ?? .array([])
        do {
            let merged = try WorkspaceMerge.merge(base: base, local: data, remote: current)
            stored[key] = merged
            return WorkspaceMergeReply(status: 200, body: .object(["updatedAt": .number(1), "data": merged, "mergeVersion": .number(1)]))
        } catch let failure as ArgusFailure {
            return WorkspaceMergeReply(status: 409, body: .object(["error": .string("conflict"), "conflicts": failure.details, "current": current]))
        }
    }
}

@MainActor
final class WorkspaceTests: XCTestCase {
    private func json(_ s: String) throws -> ArgusJSON { try JSONDecoder().decode(ArgusJSON.self, from: Data(s.utf8)) }
    private func bytes(_ v: ArgusJSON) throws -> String { String(decoding: try ArgusWire.encoder().encode(v), as: UTF8.self) }
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // Shaped exactly like the Mac's Codable output (sorted keys, uppercase UUIDs,
    // whole-second ISO-8601 dates, completedAt omitted when nil).
    let macTodos = """
    [{"id":"E97F224B-3B97-4A77-9121-5B7CC6E46ED0","isMisc":true,"items":[],"machine":"","session":""},
     {"id":"0B1F7C1E-2D6A-4C55-9C5E-1D7F3B8B9A10","isMisc":false,"items":[
        {"createdAt":"2026-09-28T09:15:00Z","done":false,"id":"5C1E7D3A-8E2B-4F1C-9A6D-0B2C3D4E5F60","text":"ship it"},
        {"completedAt":"2026-09-29T18:00:07Z","createdAt":"2026-09-28T09:16:30Z","done":true,"id":"6D2F8E4B-9F3C-4A2D-8B7E-1C3D4E5F6071","text":"write tests"}],
      "machine":"babel-s9-20","session":"argus"}]
    """
    let macNotes = """
    [{"createdAt":"2026-09-01T08:00:00Z","done":false,"editedAt":"2026-09-30T21:04:59Z","id":"7E3A9F5C-0A4D-4B3E-9C8F-2D4E5F607182","text":"line one\\nline two"}]
    """
    let macWorkflows = """
    [{"colorHex":"#30A46C","commands":"git pull\\nmake test","folder":"~/src/argus","id":"8F4BA06D-1B5E-4C4F-AD90-3E5F60718293","machine":"babel-*","name":"argus-tests","notes":"nightly"}]
    """

    // MARK: Encoding

    func testMacShapedCollectionsRoundTripExactly() throws {
        for (key, raw) in [(WorkspaceKey.todos, macTodos), (.notes, macNotes), (.workflows, macWorkflows)] {
            let value = try json(raw)
            XCTAssertEqual(try WorkspaceCodec.reencode(key, value), value, key.rawValue)
            XCTAssertNoThrow(try WorkspaceCodec.validate(key, value, strict: true), key.rawValue)
        }
        let boards = try json(macTodos).decode([TodoBoard].self)
        XCTAssertNil(boards[1].items[0].completedAt)
        XCTAssertEqual(boards[1].pending, 1)
        // Field sets, exactly.
        let encoded = WorkspaceCodec.encode(boards)
        func keys(_ v: ArgusJSON) -> Set<String> { Set(v.object.map { Array($0.keys) } ?? []) }
        XCTAssertEqual(keys(encoded[1]), ["id", "machine", "session", "isMisc", "items"])
        XCTAssertEqual(keys(encoded[1]["items"].array![0]), ["id", "text", "done", "createdAt"])
        XCTAssertEqual(keys(encoded[1]["items"].array![1]), ["id", "text", "done", "createdAt", "completedAt"])
        XCTAssertEqual(keys(WorkspaceCodec.encode([WorkspaceWorkflow()])[0]), ["id", "name", "machine", "folder", "commands", "notes", "colorHex"])
        XCTAssertEqual(keys(WorkspaceCodec.encode([WorkspaceNote()])[0]), ["id", "text", "done", "createdAt", "editedAt"])
    }

    func testNewRecordsUseUppercaseIDsAndWholeSecondUTCDates() throws {
        var item = TodoItem(text: "x")
        item.done = true
        item.completedAt = WorkspaceClock.now()
        let text = try bytes(WorkspaceCodec.encode([TodoBoard(items: [item, TodoItem(text: "y")])]))
        let date = try NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#)
        let value = try json(text)
        for record in [value[0], value[0]["items"].array![0], value[0]["items"].array![1]] {
            let id = try XCTUnwrap(record["id"].string)
            XCTAssertEqual(id, id.uppercased())
            XCTAssertNotNil(UUID(uuidString: id))
        }
        for d in [value[0]["items"].array![0]["createdAt"].string!, value[0]["items"].array![0]["completedAt"].string!] {
            XCTAssertEqual(date.numberOfMatches(in: d, range: NSRange(d.startIndex..., in: d)), 1, d)
        }
        XCTAssertFalse(text.contains("null"), "completedAt must be omitted, never null: \(text)")
        // A fresh value equals its own round-trip (no hidden sub-second precision).
        let note = WorkspaceNote(text: "n")
        XCTAssertEqual(try WorkspaceCodec.encode([note]).decode([WorkspaceNote].self), [note])
    }

    func testStrictValidationRejectsLossyDocuments() throws {
        let extra = try json(#"[{"id":"7E3A9F5C-0A4D-4B3E-9C8F-2D4E5F607182","text":"a","done":false,"createdAt":"2026-09-01T08:00:00Z","editedAt":"2026-09-01T08:00:00Z","pinned":true}]"#)
        XCTAssertThrowsError(try WorkspaceCodec.validate(.notes, extra, strict: true))
        XCTAssertNoThrow(try WorkspaceCodec.validate(.notes, extra, strict: false))   // the Mac drops unknown fields too
        let lower = try json(#"[{"id":"7e3a9f5c-0a4d-4b3e-9c8f-2d4e5f607182","text":"a","done":false,"createdAt":"2026-09-01T08:00:00Z","editedAt":"2026-09-01T08:00:00Z"}]"#)
        XCTAssertThrowsError(try WorkspaceCodec.validate(.notes, lower, strict: true))
        let nullCompleted = try json(#"[{"id":"E97F224B-3B97-4A77-9121-5B7CC6E46ED0","isMisc":true,"machine":"","session":"","items":[{"id":"5C1E7D3A-8E2B-4F1C-9A6D-0B2C3D4E5F60","text":"t","done":false,"createdAt":"2026-09-28T09:15:00Z","completedAt":null}]}]"#)
        XCTAssertThrowsError(try WorkspaceCodec.validate(.todos, nullCompleted, strict: true))
        let dupItems = try json(#"[{"id":"E97F224B-3B97-4A77-9121-5B7CC6E46ED0","isMisc":true,"machine":"","session":"","items":[{"id":"5C1E7D3A-8E2B-4F1C-9A6D-0B2C3D4E5F60","text":"t","done":false,"createdAt":"2026-09-28T09:15:00Z"}]},{"id":"0B1F7C1E-2D6A-4C55-9C5E-1D7F3B8B9A10","isMisc":false,"machine":"m","session":"s","items":[{"id":"5C1E7D3A-8E2B-4F1C-9A6D-0B2C3D4E5F60","text":"t","done":false,"createdAt":"2026-09-28T09:15:00Z"}]}]"#)
        XCTAssertThrowsError(try WorkspaceCodec.validate(.todos, dupItems, strict: false))
        let fractional = try json(#"[{"id":"7E3A9F5C-0A4D-4B3E-9C8F-2D4E5F607182","text":"a","done":false,"createdAt":"2026-09-01T08:00:00.5Z","editedAt":"2026-09-01T08:00:00Z"}]"#)
        XCTAssertThrowsError(try WorkspaceCodec.validate(.notes, fractional, strict: true), "sub-second dates are not the wire shape")
        XCTAssertThrowsError(try WorkspaceCodec.validate(.workflows, .object([:]), strict: false))
    }

    func testNotesWithoutEditedAtFallBackToCreatedAt() throws {
        let notes = try json(#"[{"id":"7E3A9F5C-0A4D-4B3E-9C8F-2D4E5F607182","text":"old","done":false,"createdAt":"2026-01-02T03:04:05Z"}]"#)
            .decode([WorkspaceNote].self)
        XCTAssertEqual(notes[0].editedAt, notes[0].createdAt)
    }

    // MARK: Sync engine

    func testSyncSendsBaseAndDataThenPersistsBaselineWithLocalCopy() async throws {
        let dir = tempDir()
        let host = FakeSyncHost()
        host.stored[.workflows] = try json(macWorkflows)
        let store = WorkspaceStore(directory: dir)
        var wf = WorkspaceWorkflow()
        wf.name = "phone"; wf.machine = "this mac"
        store.saveWorkflow(wf)

        await store.sync(.workflows, via: host)
        XCTAssertEqual(host.requests.first?.base, .array([]))
        XCTAssertEqual(host.requests.first?.data, WorkspaceCodec.encode([wf]))
        XCTAssertEqual(Set(store.workflows.map(\.name)), ["phone", "argus-tests"])
        XCTAssertEqual(store.bases[.workflows], host.stored[.workflows])
        XCTAssertNil(store.issues[.workflows])

        // Local copy and baseline survive a relaunch together.
        let reloaded = WorkspaceStore(directory: dir)
        XCTAssertEqual(reloaded.read(.workflows), store.read(.workflows))
        XCTAssertEqual(reloaded.bases[.workflows], store.bases[.workflows])

        // The next sync is a no-op merge against that baseline.
        await reloaded.sync(.workflows, via: host)
        XCTAssertEqual(host.requests.last?.base, host.stored[.workflows])
        XCTAssertEqual(reloaded.read(.workflows), host.stored[.workflows])
    }

    func testEditsMadeDuringFlightAreRebasedNotLost() async throws {
        let host = FakeSyncHost()
        let macNote = WorkspaceNote(text: "from mac")
        host.stored[.notes] = WorkspaceCodec.encode([macNote])
        let store = WorkspaceStore(directory: nil)
        let first = store.addNote(text: "first")
        var second = ""
        host.duringFlight = { second = store.addNote(text: "typed while syncing") }

        await store.sync(.notes, via: host)
        XCTAssertEqual(Set(store.notes.map(\.id)), [first, second, macNote.id])
        // Baseline is what the host confirmed, which does not include the in-flight note yet.
        XCTAssertEqual(Set(store.bases[.notes]?.array?.compactMap { $0["id"].string } ?? []), [first, macNote.id])

        await store.sync(.notes, via: host)
        XCTAssertEqual(Set(host.stored[.notes]?.array?.compactMap { $0["id"].string } ?? []), [first, second, macNote.id])
        XCTAssertEqual(store.bases[.notes], host.stored[.notes])
    }

    func testRebaseConflictDuringFlightPreservesBothCopies() async throws {
        let host = FakeSyncHost()
        let store = WorkspaceStore(directory: nil)
        let id = store.addNote(text: "v1")
        await store.sync(.notes, via: host)
        // The Mac edits the same note while the phone's next request is in flight
        // and the phone edits it again before the reply lands.
        store.toggleNote(id)
        host.duringFlight = {
            var remote = try! host.stored[.notes]!.decode([WorkspaceNote].self)
            remote[0].text = "mac text"
            host.stored[.notes] = WorkspaceCodec.encode(remote)
            store.updateNoteText(id, "phone text")
        }
        await store.sync(.notes, via: host)
        let conflict = try XCTUnwrap(store.conflicts[.notes])
        XCTAssertEqual(store.banner(for: .notes), WorkspaceStore.conflictMessage)
        XCTAssertEqual(conflict.local, store.read(.notes))
        XCTAssertEqual(store.notes.first?.text, "phone text", "local edits are never overwritten")
        XCTAssertEqual(conflict.remote, host.stored[.notes])
    }

    func testConflictReviewCommitsWithRemoteBaselineAndResyncs() async throws {
        let dir = tempDir()
        let host = FakeSyncHost()
        let store = WorkspaceStore(directory: dir)
        let id = store.addNote(text: "shared")
        await store.sync(.notes, via: host)

        // Both sides change the same field: the host refuses with 409 + current.
        var remote = try host.stored[.notes]!.decode([WorkspaceNote].self)
        remote[0].text = "mac edit"
        host.stored[.notes] = WorkspaceCodec.encode(remote)
        store.updateNoteText(id, "phone edit")
        await store.sync(.notes, via: host)
        let conflict = try XCTUnwrap(store.conflicts[.notes])
        XCTAssertEqual(conflict.remote, host.stored[.notes])
        XCTAssertEqual(conflict.paths.array?.compactMap(\.string), ["/\(id)/text"])

        // Under review nothing is sent, but the preserved phone copy tracks new edits.
        let sent = host.requests.count
        store.addNote(text: "another")
        await store.sync(.notes, via: host)
        XCTAssertEqual(host.requests.count, sent)
        XCTAssertEqual(store.conflicts[.notes]?.local, store.read(.notes))
        XCTAssertNotNil(WorkspaceStore(directory: dir).conflicts[.notes], "the review survives a relaunch")

        // Invalid documents are rejected and change nothing.
        XCTAssertThrowsError(try store.resolveConflict(.notes, document: "not json"))
        XCTAssertThrowsError(try store.resolveConflict(.notes, document: #"[{"id":"nope"}]"#))
        XCTAssertNotNil(store.conflicts[.notes])

        // Start from the phone copy, take the Mac's wording for the shared note.
        var resolved = try store.conflicts[.notes]!.local.decode([WorkspaceNote].self)
        if let i = resolved.firstIndex(where: { $0.id == id }) { resolved[i].text = "mac edit" }
        try store.resolveConflict(.notes, document: WorkspaceCodec.pretty(WorkspaceCodec.encode(resolved)))
        XCTAssertNil(store.conflicts[.notes])
        XCTAssertEqual(store.bases[.notes], conflict.remote)
        XCTAssertEqual(Set(store.notes.map(\.text)), ["mac edit", "another"])

        await store.sync(.notes, via: host)
        XCTAssertNil(store.conflicts[.notes])
        XCTAssertEqual(store.read(.notes), host.stored[.notes])
        XCTAssertEqual(Set(store.notes.map(\.text)), ["mac edit", "another"])
    }

    func testFailuresKeepLocalEditsAndBackOff() async throws {
        let host = FakeSyncHost()
        host.failWith = 500
        let store = WorkspaceStore(directory: nil)
        store.addNote(text: "keep me")
        await store.sync(.notes, via: host)
        XCTAssertNotNil(store.issues[.notes])
        XCTAssertNil(store.conflicts[.notes])
        XCTAssertEqual(store.notes.map(\.text), ["keep me"])
        await store.sync(.notes, via: host)
        XCTAssertEqual(host.requests.count, 1, "backs off after a failure")
        host.failWith = nil
        store.retry(.notes)   // explicit retry clears the backoff
        await store.sync(.notes, via: host)
        XCTAssertNil(store.issues[.notes])
        XCTAssertEqual(store.read(.notes), host.stored[.notes])
    }

    // MARK: Todo Maps

    func testMiscBoardIsShownFirstAndCreatedOnlyWhenUsed() {
        let store = WorkspaceStore(directory: nil)
        XCTAssertTrue(store.todos.isEmpty)
        let shown = store.displayBoards(showFinished: false)
        XCTAssertEqual(shown.map(\.isMisc), [true])
        store.addTodo(shown[0].id, "  buy milk ")
        XCTAssertEqual(store.todos.count, 1)
        XCTAssertEqual(store.todos[0].isMisc, true)
        XCTAssertEqual(store.todos[0].items.map(\.text), ["buy milk"])
        store.deleteBoard(store.todos[0].id)
        XCTAssertEqual(store.todos.count, 1, "Misc can't be deleted")

        let id = store.ensureBoard(machine: " babel-1 ", session: "argus")
        XCTAssertEqual(store.ensureBoard(machine: "babel-1", session: "argus "), id, "dedupes by machine + session")
        let item = store.todos.first { $0.id == id }!
        store.addTodo(item.id, "a")
        let itemID = store.todos.first { $0.id == id }!.items[0].id
        store.toggleTodo(id!, itemID)
        XCTAssertNotNil(store.todos.first { $0.id == id }!.items[0].completedAt)
        store.toggleTodo(id!, itemID)
        XCTAssertNil(store.todos.first { $0.id == id }!.items[0].completedAt)
        store.editTodo(id!, itemID, text: " renamed ")
        XCTAssertEqual(store.todos.first { $0.id == id }!.items[0].text, "renamed")
    }

    func testBoardAndItemOrdering() {
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = t0.addingTimeInterval(60), t2 = t0.addingTimeInterval(120)
        let items = [
            TodoItem(id: "D", text: "done early", done: true, createdAt: t0, completedAt: t1),
            TodoItem(id: "P2", text: "pending new", createdAt: t1),
            TodoItem(id: "D2", text: "done late", done: true, createdAt: t0, completedAt: t2),
            TodoItem(id: "P1", text: "pending old", createdAt: t0),
        ]
        XCTAssertEqual(WorkspaceRules.sortedItems(items).map(\.id), ["P1", "P2", "D2", "D"])

        let finished = TodoBoard(id: "F", machine: "m", session: "aaa", items: [TodoItem(text: "x", done: true)])
        let boards = [
            TodoBoard(id: "B", machine: "m", session: "beta", items: [TodoItem(text: "x")]),
            TodoBoard(id: "A", machine: "m", session: "alpha"),
            TodoBoard(id: "L", machine: "m", session: "zulu"),
            finished,
            TodoBoard(id: "M", isMisc: true),
        ]
        let live: (TodoBoard) -> Bool = { $0.id == "L" }
        XCTAssertEqual(WorkspaceRules.orderBoards(boards, showFinished: false, isLive: live).map(\.id), ["M", "L", "A", "B"])
        XCTAssertEqual(WorkspaceRules.orderBoards(boards, showFinished: true, isLive: live).map(\.id), ["M", "L", "F", "A", "B"])
    }

    func testBoardMachineMatching() {
        let mac = machine("hub:mac", "Lawrences-MacBook-Pro", os: "darwin")
        let babel = machine("babel", "ut-babel-s9-20.tailnet.ts.net", os: "linux")
        XCTAssertTrue(WorkspaceRules.boardMachine("this mac", matches: mac, syncHostID: mac.id))
        XCTAssertTrue(WorkspaceRules.boardMachine("Local", matches: mac, syncHostID: mac.id))
        XCTAssertFalse(WorkspaceRules.boardMachine("this mac", matches: babel, syncHostID: mac.id))
        XCTAssertTrue(WorkspaceRules.boardMachine("babel-s9-20", matches: babel, syncHostID: mac.id))
        XCTAssertFalse(WorkspaceRules.boardMachine("babel-s9-2", matches: babel, syncHostID: mac.id))
        XCTAssertEqual(WorkspaceRules.machineLabel(for: mac, syncHostID: mac.id), "this mac")
        XCTAssertEqual(WorkspaceRules.machineLabel(for: babel, syncHostID: mac.id), babel.name)
    }

    // MARK: Workflows

    private func machine(_ id: String, _ name: String, os: String) -> Machine {
        Machine(id: id, name: name, os: os, httpBase: URL(string: "http://h:8722")!, wsBase: URL(string: "ws://h:8722")!)
    }

    func testMachinePatternResolution() {
        let ms = [machine("1", "babel-s9-20", os: "linux"), machine("2", "Babel-S9-21", os: "linux"),
                  machine("3", "studio", os: "darwin"), machine("4", "laptop", os: "darwin"), machine("5", "a.b", os: "linux")]
        func names(_ p: String) -> [String] { WorkspaceRules.machines(matching: p, in: ms).map(\.name) }
        XCTAssertEqual(names("babel-*"), ["babel-s9-20", "Babel-S9-21"])
        XCTAssertEqual(names("BABEL-S9-20"), ["babel-s9-20"])
        XCTAssertEqual(names("babel"), [], "full match, not substring")
        XCTAssertEqual(names("*-21"), ["Babel-S9-21"])
        XCTAssertEqual(names(" this mac "), ["studio", "laptop"])
        XCTAssertEqual(names("MAC"), ["studio", "laptop"])
        XCTAssertEqual(names("local"), ["studio", "laptop"])
        XCTAssertEqual(names("a?b"), [], "regex metacharacters are literal")
        XCTAssertEqual(names("a.b"), ["a.b"])
        XCTAssertEqual(names("axb"), [])
        XCTAssertEqual(names(""), [])
    }

    func testCdQuotingAndWorkflowLines() {
        XCTAssertEqual(WorkspaceRules.cdCommand("~"), "cd ~")
        XCTAssertEqual(WorkspaceRules.cdCommand("~/src/my app"), "cd ~/src/my app")
        XCTAssertEqual(WorkspaceRules.cdCommand("/tmp/my dir"), "cd '/tmp/my dir'")
        XCTAssertEqual(WorkspaceRules.cdCommand("/tmp/it's"), #"cd '/tmp/it'\''s'"#)
        XCTAssertEqual(WorkspaceRules.cdCommand("~user/x"), "cd '~user/x'")
        var wf = WorkspaceWorkflow()
        wf.folder = "  ~/scratch "
        wf.commands = "git pull\n\n   \n  make test  \n"
        XCTAssertEqual(WorkspaceRules.workflowLines(wf), ["cd ~/scratch", "git pull", "make test"])
        wf.folder = ""
        XCTAssertEqual(WorkspaceRules.workflowLines(wf), ["git pull", "make test"])
    }

    // MARK: Notes

    func testNoteGroupingByEditedAt() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1   // Sunday-first locale: buckets must still start weeks on Monday
        let iso = ISO8601DateFormatter()
        func d(_ s: String) -> Date { iso.date(from: s)! }
        let now = d("2026-09-17T12:00:00Z")   // a Thursday
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-17T00:00:01Z"), now: now, calendar: cal), .today)
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-16T23:59:59Z"), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-14T08:00:00Z"), now: now, calendar: cal), .thisWeek)    // Monday
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-13T08:00:00Z"), now: now, calendar: cal), .thisMonth)   // Sunday before
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-08-31T08:00:00Z"), now: now, calendar: cal), .earlier)
        // Monday: yesterday (Sunday) is still "Yesterday", not this week.
        let monday = d("2026-09-14T09:00:00Z")
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-13T09:00:00Z"), now: monday, calendar: cal), .yesterday)
        XCTAssertEqual(WorkspaceRules.bucket(of: d("2026-09-12T09:00:00Z"), now: monday, calendar: cal), .thisMonth)

        let notes = [
            WorkspaceNote(id: "A", text: "a", createdAt: d("2026-09-01T00:00:00Z"), editedAt: d("2026-09-17T08:00:00Z")),
            WorkspaceNote(id: "B", text: "b", createdAt: d("2026-09-17T09:00:00Z")),
            WorkspaceNote(id: "C", text: "c", createdAt: d("2026-07-01T00:00:00Z")),
            WorkspaceNote(id: "D", text: "d", createdAt: d("2026-09-15T00:00:00Z")),
        ]
        let groups = WorkspaceRules.groupedNotes(notes, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.0), [.today, .thisWeek, .earlier])
        XCTAssertEqual(groups[0].1.map(\.id), ["B", "A"], "newest edit first")
    }

    func testNoteEditsMoveEditedAtOnlyOnTextChange() async {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let host = FakeSyncHost()
        host.stored[.notes] = WorkspaceCodec.encode([WorkspaceNote(text: "x", createdAt: old)])
        let store = WorkspaceStore(directory: nil)
        await store.sync(.notes, via: host)
        let id = store.notes[0].id
        store.updateNoteText(id, "x")
        XCTAssertEqual(store.notes[0].editedAt, old)
        store.toggleNote(id)
        XCTAssertEqual(store.notes[0].editedAt, old)
        XCTAssertTrue(store.notes[0].done)
        store.updateNoteText(id, "y")
        XCTAssertGreaterThan(store.notes[0].editedAt, old)
    }
}

private extension ArgusJSON {
    subscript(_ index: Int) -> ArgusJSON { array.flatMap { index < $0.count ? $0[index] : nil } ?? .null }
}
