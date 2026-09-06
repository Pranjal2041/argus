import XCTest
import AppKit
import SwiftUI
import ArgusProtocol
@testable import UniversalTmuxMac

@MainActor
final class ArgusControlTests: XCTestCase {
    private var root: URL!
    private var app: AppState!
    private var cc: CommandCenterModel!
    private var weekly: WeeklyProgressController!
    private var service: ArgusControlService!
    private var coordinator: WeeklyProgressCoordinator!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-cli-test-" + UUID().uuidString)
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("weekly"))
        coordinator = WeeklyProgressCoordinator(store: store)
        app = AppState(isolatedForTesting: true); app.notes = []; app.todoBoards = []; app.plannerCommitments = []; app.workflows = []
        app.selection = nil; app.unseen = []; app.backlog = []
        cc = CommandCenterModel(); cc.statuses = [:]
        weekly = WeeklyProgressController(store: store, coordinator: coordinator)
        service = ArgusControlService(coordinator: coordinator, store: store, dataRoot: root.appendingPathComponent("control"))
        try service.bind(state: app, commandCenter: cc, weekly: weekly)
    }
    override func tearDown() async throws {
        service = nil; weekly = nil; coordinator = nil; app = nil; cc = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }
    private func call(_ method: String, _ p: [String: String] = [:], id: String = UUID().uuidString) async -> ArgusResponse {
        await service.handle(ArgusRequest(id: id, method: method, params: p.mapValues(ArgusJSON.string), actor: "test-agent"))
    }
    private func result(_ response: ArgusResponse, file: StaticString = #filePath, line: UInt = #line) throws -> ArgusJSON {
        XCTAssertTrue(response.ok, response.error?.message ?? "", file: file, line: line)
        return try XCTUnwrap(response.result, file: file, line: line)
    }
    func testNotesAreSharedAndOptimisticallyEditedWithoutNavigation() async throws {
        let before = app.workspaceDestination
        let created = try result(await call("notes.create", ["text": "original"]))
        let id = try XCTUnwrap(created["record"]["id"].string), revision = try XCTUnwrap(created["revision"].string)
        XCTAssertEqual(app.notes.first?.text, "original")
        app.updateNoteText(UUID(uuidString: id)!, "human edit")
        let conflict = await call("notes.update", ["id": id, "text": "stale agent edit", "if-revision": revision])
        XCTAssertEqual(conflict.error?.code, "conflict"); XCTAssertEqual(app.notes.first?.text, "human edit")
        let current = try result(await call("notes.get", ["id": id]))
        let updated = try result(await call("notes.update", ["id": id, "text": "reconciled", "if-revision": current["revision"].string!]))
        XCTAssertEqual(updated["record"]["text"].string, "reconciled")
        XCTAssertEqual(app.workspaceDestination, before)
    }
    func testPhoneStyleAdoptionInvalidatesAnExistingCLIRevision() async throws {
        let created = try result(await call("notes.create", ["text": "before"]))
        var remote = app.notes; remote[0].text = "synced edit"
        try app.applyWorkspaceCollection("notes", ArgusJSON.encode(remote))
        let response = await call("notes.complete", ["id": app.notes[0].id.uuidString, "if-revision": created["revision"].string!])
        XCTAssertEqual(response.error?.code, "conflict"); XCTAssertFalse(app.notes[0].done)
    }
    func testDuplicateRequestsSurviveServiceRestartAndRejectDifferentPayload() async throws {
        let first = await call("notes.create", ["text": "only once"], id: "same-request")
        let retry = await call("notes.create", ["text": "only once"], id: "same-request")
        XCTAssertEqual(first.result, retry.result); XCTAssertEqual(app.notes.count, 1)
        let store = WeeklyProgressDiskStore(rootURL: root.appendingPathComponent("weekly"))
        service = ArgusControlService(coordinator: coordinator, store: store, dataRoot: root.appendingPathComponent("control"))
        try service.bind(state: app, commandCenter: cc, weekly: weekly)
        let afterRestart = await call("notes.create", ["text": "only once"], id: "same-request")
        let mismatch = await call("notes.create", ["text": "different"], id: "same-request")
        XCTAssertEqual(afterRestart.result, first.result)
        XCTAssertEqual(mismatch.error?.code, "request_id_reused")
        XCTAssertEqual(app.notes.count, 1)
    }
    func testReservedButUnconfirmedActionIsNeverBlindlyReplayed() throws {
        let url = root.appendingPathComponent("pending.json")
        let request = ArgusRequest(id: "pending", method: "notes.create", params: ["text": .string("x")])
        let journal = try ArgusActionJournal(url: url); try journal.reserve(request)
        let reopened = try ArgusActionJournal(url: url)
        XCTAssertThrowsError(try reopened.replay(request)) { XCTAssertEqual(($0 as? ArgusFailure)?.code, "outcome_unknown") }
    }
    func testArchiveRestoreCannotOverwriteLaterEdits() async throws {
        let note = try result(await call("notes.create", ["text": "retain me"]))
        let id = note["record"]["id"].string!, revision = note["revision"].string!
        let archived = try result(await call("notes.archive", ["id": id, "if-revision": revision]))
        XCTAssertTrue(app.notes.isEmpty)
        let original = try note["record"].decode(Note.self)
        app.notes = [original]
        let rejected = await call("archive.restore", ["id": archived["archive_id"].string!])
        XCTAssertEqual(rejected.error?.code, "conflict")
        app.notes = []
        _ = try result(await call("archive.restore", ["id": archived["archive_id"].string!]))
        XCTAssertEqual(app.notes[0].text, "retain me")
    }
    func testTodosAndPlannerUseSameRevisionAndExplicitCompletionContract() async throws {
        let board = try result(await call("todos.boards.create", ["machine": "cluster-*", "session": "project"]))
        let todo = try result(await call("todos.items.create", ["board": board["record"]["id"].string!, "text": "finish"]))
        let done = try result(await call("todos.items.complete", ["id": todo["record"]["id"].string!, "if-revision": todo["revision"].string!]))
        XCTAssertEqual(done["record"]["done"].bool, true)
        let repeated = try result(await call("todos.items.complete", ["id": todo["record"]["id"].string!, "if-revision": done["revision"].string!]))
        XCTAssertEqual(done["revision"], repeated["revision"])
        let plan = try result(await call("planner.create", ["title": "deliver", "deadline": "2026-09-10", "project": "project"]))
        XCTAssertEqual(plan["record"]["hasExactTime"].bool, false)
        let complete = try result(await call("planner.complete", ["id": plan["record"]["id"].string!, "if-revision": plan["revision"].string!]))
        XCTAssertNotNil(complete["record"]["completedAt"].string)
        let invalid = await call("planner.create", ["title": "x", "deadline": "2026-02-31"])
        XCTAssertEqual(invalid.error?.code, "invalid_arguments")
    }
    func testAgentNavigationDoesNotAcknowledgeHumanAttentionAndNamesAreAmbiguous() async throws {
        app.machines.append(Machine(id: "second", name: "other", isLocal: false, httpBase: "http://127.0.0.1:1", wsBase: "ws://127.0.0.1:1"))
        app.sessionsByMachine = ["local": [SessionInfo(name: "same", state: "waiting", lineageID: "life-1")], "second": [SessionInfo(name: "same", state: "waiting", lineageID: "life-2")]]
        app.unseen.insert("local/same")
        let ambiguous = await call("app.show", ["view": "session", "id": "same"])
        XCTAssertEqual(ambiguous.error?.code, "ambiguous_target")
        _ = try result(await call("app.show", ["view": "session", "id": "local#life-1"]))
        XCTAssertEqual(app.selection?.id, "local/same"); XCTAssertTrue(app.unseen.contains("local/same"))
        XCTAssertEqual(app.sessionsByMachine["local"]?.first?.state, "waiting")
        app.sessionsByMachine["local"] = [SessionInfo(name: "renamed", state: "working", lineageID: "life-1")]
        let renamed = try result(await call("sessions.get", ["id": "local#life-1"]))
        XCTAssertEqual(renamed["name"].string, "renamed")
        XCTAssertEqual(renamed["summary_inferred"], .null)
    }
    func testContextCursorCoversChangesBetweenSnapshotAndSubscription() async throws {
        let context = try result(await call("context"))
        app.addNote()
        let events = try result(await call("events.poll", ["after": context["cursor"].string!, "wait": "0"]))
        XCTAssertTrue(events["events"].array!.contains { $0["type"].string == "notes.changed" })
        let expired = await call("events.poll", ["after": "wrong:0"])
        XCTAssertEqual(expired.error?.code, "cursor_expired")
    }
    func testEventRetentionAndRestartAreExplicit() async throws {
        let url = root.appendingPathComponent("events.json")
        let log = try ArgusEventLog(url: url), old = log.cursor
        log.append("first", actor: "test")
        let reloaded = try ArgusEventLog(url: url)
        XCTAssertEqual(reloaded.cursor, log.cursor)
        let got = try await reloaded.read(after: old, wait: 0)
        XCTAssertEqual(got["events"].array?.count, 1)
        let memory = try ArgusEventLog(url: nil), expired = memory.cursor
        for _ in 0..<1025 { memory.append("change", actor: "test") }
        do { _ = try await memory.read(after: expired, wait: 0); XCTFail("must not silently skip") }
        catch { XCTAssertEqual((error as? ArgusFailure)?.code, "cursor_expired") }
    }
    func testWeeklyProjectsShareUIStoreWithoutChangingSelectedProject() async throws {
        let project = try result(await call("weekly-progress.projects.create", ["document": "{\"name\":\"Research\",\"panels\":[{\"session\":\"project\"}]}"]))
        XCTAssertEqual(weekly.projects.count, 1); XCTAssertNil(weekly.selectedProjectID)
        let listed = try result(await call("weekly-progress.projects.get", ["id": "Research"]))
        XCTAssertEqual(project["record"], listed["record"])
        let invalid = await call("weekly-progress.generate", ["project": "Research", "week": "2026-09-08"])
        XCTAssertEqual(invalid.error?.code, "invalid_arguments") // Never starts a model in tests.
    }
    func testProtocolRejectsUnknownParametersAndUnsupportedVersion() async {
        let invalid = await call("notes.create", ["text": "x", "shell": "anything"])
        XCTAssertEqual(invalid.error?.code, "invalid_arguments")
        var request = ArgusRequest(method: "status"); request.version = 99
        let version = await service.handle(request)
        XCTAssertEqual(version.error?.code, "protocol_mismatch")
        XCTAssertTrue(app.notes.isEmpty)
    }
    func testActualAutomationViewRenders() async throws {
        _ = NSApplication.shared
        _ = try result(await call("notes.create", ["text": "Visual verification fixture"]))
        let view = AutomationActivityView().environmentObject(app).environmentObject(service)
            .frame(width: 900, height: 650).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)
        let png = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/argus-cli-activity-test.png"))
        window.close()
    }
    func testWorkspaceStorageFailureDoesNotBlockNavigation() async throws {
        app.workspaceStorageError = "fixture: unreadable workspace"
        _ = try result(await call("app.show", ["view": "notes"]))
        let rejected = await call("notes.create", ["text": "must not apply"])
        XCTAssertEqual(rejected.error?.code, "storage_failed")
        XCTAssertTrue(app.notes.isEmpty)
    }
    func testConflictReviewViewRendersPreservedCopiesAndEditor() throws {
        _ = NSApplication.shared
        let local = ArgusJSON.array([.object(["id": .string("review-fixture"), "text": .string("Mac edit")])])
        let remote = ArgusJSON.array([.object(["id": .string("review-fixture"), "text": .string("Phone edit")])])
        let conflict = WorkspaceSyncConflict(key: "notes", base: .array([]), local: local, remote: remote, paths: .array([]))
        let view = WorkspaceConflictReview(conflict: conflict).environmentObject(app)
            .frame(width: 960, height: 700).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rendered)
        let png = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/argus-cli-conflict-test.png"))
        window.close()
    }
    func testInterruptedSyncCreatesReviewAndValidatesBeforeClearing() throws {
        let url = root.appendingPathComponent("sync.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = ArgusJSON.array([.object(["id": .string("n"), "text": .string("old")])])
        let saved = ArgusJSON.array([.object(["id": .string("n"), "text": .string("saved")])])
        let current = ArgusJSON.array([.object(["id": .string("n"), "text": .string("new edit")])])
        var snapshot = WorkspaceSync.State(); snapshot.bases["notes"] = before
        snapshot.pending = ["notes": .init(before: before, merged: saved)]
        try ArgusWire.encoder().encode(snapshot).write(to: url)
        let sync = WorkspaceSync(url: url)
        sync.sync(key: "notes", host: "invalid-host", read: { current }, apply: { _ in XCTFail("Must review competing edits") })
        let conflict = try XCTUnwrap(sync.state.conflicts["notes"])
        XCTAssertNil(sync.state.pending?["notes"])
        XCTAssertNotNil(WorkspaceSync(url: url).issues["notes"])
        let revision = try ArgusJSON.encode(conflict).revision
        XCTAssertThrowsError(try sync.resolve(key: "notes", expectedRevision: revision, current: current, merged: saved,
            validate: { _ in throw ArgusFailure("invalid_arguments", "fixture") }, apply: { _ in XCTFail("Invalid document") }))
        XCTAssertNotNil(sync.state.conflicts["notes"])
        try sync.resolve(key: "notes", expectedRevision: revision, current: current, merged: saved, validate: { _ in }, apply: { XCTAssertEqual($0, saved) })
        XCTAssertNil(sync.state.conflicts["notes"])
        XCTAssertEqual(sync.state.bases["notes"], before, "Keep the actual remote baseline, not the interrupted local merge")
    }
    func testExecutableCLIThroughRealSocketMutatesSharedModel() async throws {
        let socket = "/tmp/argus-e2e-" + UUID().uuidString + "/cli.sock"
        let server = ArgusSocketServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: socket).deletingLastPathComponent().path) }
        let service = service!
        try server.start(path: socket) { await service.handle($0) }
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/argus")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let output = try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = ["notes", "create", "--text", "actual CLI", "--json", "--socket", socket, "--request-id", "executable-test"]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ArgusFailure("test_cli_failed", String(data: data, encoding: .utf8) ?? "") }
            return data
        }.value
        let response = try JSONDecoder().decode(ArgusResponse.self, from: output)
        XCTAssertTrue(response.ok); XCTAssertEqual(app.notes.last?.text, "actual CLI")
    }
    func testAllTopLevelNavigationUsesOneExclusiveDestination() async throws {
        for view in WorkspaceDestination.allCases where view != .session {
            let response = await call("app.show", ["view": view.rawValue])
            XCTAssertTrue(response.ok); XCTAssertEqual(app.workspaceDestination, view)
            XCTAssertEqual([app.showNotes, app.showTodos, app.showPlanner, app.showOverview, app.showLab, app.showLedger, app.showWeeklyProgress, app.showArtifacts, app.showWebArtifacts].filter { $0 }.count, 1)
        }
    }
}

final class ArgusSocketTests: XCTestCase {
    func testRealSocketRejectsSecondOwnerAndSurvivesSlowClient() async throws {
        let dir = "/tmp/argus-socket-" + UUID().uuidString
        let path = dir + "/c.sock"
        let server = ArgusSocketServer()
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        try server.start(path: path) { ArgusResponse(id: $0.id, result: .string($0.method)) }
        let second = ArgusSocketServer()
        do {
            try second.start(path: path) { ArgusResponse(id: $0.id, result: .null) }
            XCTFail("Second server stole the socket")
        } catch { XCTAssertEqual((error as? ArgusFailure)?.code, "already_running") }
        let result = try ArgusLocalSocket.call(ArgusRequest(method: "status"), path: path)
        XCTAssertEqual(result.result, .string("status"))
        // A connected client that sends no request must not block another one.
        let slow = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(slow) }
        var address = try ArgusLocalSocket.address(path)
        let connected = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(slow, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let start = Date()
        XCTAssertTrue(try ArgusLocalSocket.call(ArgusRequest(method: "status"), path: path).ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        var metadata = stat(); XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }
    func testNoImplicitLaunchAndUnsafeDirectoryRejected() throws {
        XCTAssertThrowsError(try ArgusLocalSocket.call(ArgusRequest(method: "status"), path: "/tmp/nonexistent-" + UUID().uuidString + "/c.sock")) { XCTAssertEqual(($0 as? ArgusFailure)?.code, "app_not_running") }
        XCTAssertThrowsError(try ArgusLocalSocket.verifyDirectory("/tmp"))
        XCTAssertThrowsError(try ArgusLocalSocket.address(String(repeating: "a", count: 150)))
    }
}

final class WorkspaceMergeTests: XCTestCase {
    private func json(_ raw: String) throws -> ArgusJSON { try JSONDecoder().decode(ArgusJSON.self, from: Data(raw.utf8)) }
    func testIndependentRecordsAndNestedTodoItemsMerge() throws {
        let base = try json("[{\"id\":\"b\",\"items\":[{\"id\":\"x\",\"text\":\"original\"}]}]")
        let local = try json("[{\"id\":\"b\",\"items\":[{\"id\":\"x\",\"text\":\"original\"},{\"id\":\"y\",\"text\":\"new\"}]}]")
        let remote = try json("[{\"id\":\"b\",\"items\":[{\"id\":\"x\",\"text\":\"changed\"}]}]")
        let merged = try WorkspaceMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.array?[0]["items"].array?.count, 2)
        XCTAssertEqual(merged.array?[0]["items"].array?[0]["text"].string, "changed")
    }
    func testCompetingEditsAndDeleteVersusEditConflict() throws {
        let base = try json("[{\"id\":\"n\",\"text\":\"base\"}]")
        let local = try json("[{\"id\":\"n\",\"text\":\"local\"}]")
        let remote = try json("[{\"id\":\"n\",\"text\":\"remote\"}]")
        XCTAssertThrowsError(try WorkspaceMerge.merge(base: base, local: local, remote: remote))
        XCTAssertThrowsError(try WorkspaceMerge.merge(base: base, local: .array([]), remote: remote))
        XCTAssertEqual(try WorkspaceMerge.merge(base: base, local: .array([]), remote: base), .array([]))
    }
}
