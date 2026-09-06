import AppKit
import Combine
import Foundation
import ArgusProtocol

/// The CLI is a second interface to these existing models, not another owner of
/// workspace data. The main actor serializes short actions with UI and sync edits.
@MainActor
final class ArgusControlService: ObservableObject {
    private let coordinator: WeeklyProgressCoordinator
    private let store: WeeklyProgressDiskStore
    private let server = ArgusSocketServer()
    private var app: AppState?
    private var commandCenter: CommandCenterModel?
    private var weekly: WeeklyProgressController?
    private weak var lab: LabModel?
    private var journal: ArgusActionJournal?
    private var events: ArgusEventLog?
    private var subscriptions: Set<AnyCancellable> = []
    private var fingerprints: [String: String] = [:]
    private var observationQueued = false
    private(set) var startupError: String?
    private var socketPath = ArgusLocalSocket.defaultPath
    private let dataRoot: URL?
    private var observing = false
    private var lastCCRefresh = Date.distantPast

    init(coordinator: WeeklyProgressCoordinator, store: WeeklyProgressDiskStore = WeeklyProgressDiskStore(),
         dataRoot: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Argus/local-control")) {
        self.coordinator = coordinator; self.store = store; self.dataRoot = dataRoot
    }

    func bind(state: AppState, commandCenter: CommandCenterModel, weekly: WeeklyProgressController, lab: LabModel? = nil) throws {
        guard app == nil else { return }
        let journal = try ArgusActionJournal(url: dataRoot?.appendingPathComponent("receipts.json"))
        let events = try ArgusEventLog(url: dataRoot?.appendingPathComponent("events.json"))
        self.app = state; self.commandCenter = commandCenter; self.weekly = weekly
        self.lab = lab
        self.journal = journal; self.events = events
        for publisher in [state.objectWillChange.eraseToAnyPublisher(), commandCenter.objectWillChange.eraseToAnyPublisher(), weekly.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.queueObservation() }.store(in: &subscriptions)
        }
        lab?.objectWillChange.sink { [weak self] _ in self?.queueObservation() }.store(in: &subscriptions)
        observeChanges(actor: "app")
        events.append("app.started", actor: "app")
    }
    func start(state: AppState, commandCenter: CommandCenterModel, weekly: WeeklyProgressController, lab: LabModel? = nil) {
        guard !observing else { return }
        do {
            try bind(state: state, commandCenter: commandCenter, weekly: weekly, lab: lab)
            try server.start(path: socketPath) { [weak self] request in
                guard let self else { return ArgusResponse(id: request.id, error: ArgusFailure("app_stopping", "Argus is stopping.")) }
                return await self.handle(request)
            }
            observing = true; startupError = nil
        } catch { startupError = error.localizedDescription; NSLog("[argus-cli] start failed: %@", error.localizedDescription) }
    }
    private func queueObservation() {
        guard !observationQueued else { return }; observationQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.observationQueued = false
            self?.observeChanges(actor: "ui-or-sync")
        }
    }
    private func observeChanges(actor: String) {
        guard let app, let commandCenter, let weekly, let events else { return }
        let values: [String: ArgusJSON] = [
            "notes.changed": (try? .encode(app.notes)) ?? .null,
            "todos.changed": (try? .encode(app.todoBoards)) ?? .null,
            "planner.changed": (try? .encode(app.plannerCommitments)) ?? .null,
            "sessions.changed": .array(sessionRows(includeAll: true, includeFreshness: false)),
            "command-center.changed": (try? .encode(commandCenter.statuses)) ?? .null,
            "app.navigation": appState(),
            "lab.attention_changed": .array(labAttention()),
            "sync.changed": syncSummary(),
            "weekly-progress.changed": .object(["projects": (try? .encode(weekly.projects)) ?? .null,
                "generations": (try? .encode(weekly.generations.map(\.manifest))) ?? .null,
                "active": weekly.operationGenerationID.map { .string($0.uuidString) } ?? .null]),
        ]
        for key in values.keys.sorted() {
            let fingerprint = values[key]!.revision
            if let old = fingerprints[key], old != fingerprint { events.append(key, actor: actor) }
            fingerprints[key] = fingerprint
        }
    }

    func handle(_ request: ArgusRequest) async -> ArgusResponse {
        var reserved = false
        var applied = false
        do {
            guard request.version == ArgusWire.version else { throw ArgusFailure("protocol_mismatch", "Use the CLI bundled with this Argus app.") }
            guard !request.id.isEmpty, request.id.utf8.count <= 160, !request.actor.isEmpty, request.actor.utf8.count <= 160 else {
                throw ArgusFailure("invalid_arguments", "Request ID and actor must contain 1–160 UTF-8 bytes.")
            }
            guard let spec = ArgusCommand.all.first(where: { $0.name == request.method }) else { throw ArgusFailure("unknown_command", "This app does not support \(request.method).") }
            try spec.validate(request.params)
            guard let journal, app != nil, events != nil else { throw ArgusFailure("not_ready", "Argus local control has not initialized.") }
            if spec.mutation {
                if let replay = try journal.replay(request) { return replay }
                if isWorkspaceMutation(request.method), let error = app?.workspaceStorageError { throw ArgusFailure("storage_failed", error) }
                try journal.reserve(request); reserved = true
            }
            observeChanges(actor: "ui-or-sync")
            let result = try await perform(request)
            applied = reserved
            if reserved && isWorkspaceMutation(request.method) { try app?.flushWorkspace() }
            let response = ArgusResponse(id: request.id, result: result)
            if reserved {
                objectWillChange.send()
                try journal.finish(request, response)
                events?.append("action.completed", actor: request.actor, entity: request.method)
                observeChanges(actor: request.actor)
            }
            return response
        } catch {
            if applied {
                return ArgusResponse(id: request.id, error: ArgusFailure("outcome_unknown", "The action ran, but its durable state/receipt could not be confirmed. Inspect the target; this request ID will not be executed again."))
            }
            let failure = (error as? ArgusFailure) ?? ArgusFailure("action_failed", error.localizedDescription)
            let response = ArgusResponse(id: request.id, error: failure)
            if reserved { try? journal?.finish(request, response) }
            return response
        }
    }

    private func isWorkspaceMutation(_ method: String) -> Bool {
        ["notes.", "todos.", "planner.", "archive."].contains { method.hasPrefix($0) } || method == "sync.resolve"
    }

    private func perform(_ r: ArgusRequest) async throws -> ArgusJSON {
        let p = r.params, method = r.method
        guard let app, let cc = commandCenter, let weekly, let events, let journal else { throw ArgusFailure("not_ready", "App is not ready.") }
        // Scope attribution only across synchronous mutations; never hold an actor
        // marker across an await where a human action could interleave.
        if method.hasPrefix("notes.") || method.hasPrefix("todos.") || method.hasPrefix("planner.") || method.hasPrefix("archive.") {
            let previous = ActivityJournal.shared.actionActor
            if !AppState.isRunningTests { ActivityJournal.shared.actionActor = r.actor }
            defer { if !AppState.isRunningTests { ActivityJournal.shared.actionActor = previous } }
            return try workspaceCommand(r)
        }
        switch method {
        case "sync.conflicts": return .array(try app.workspaceSync.state.conflicts.values.sorted { $0.key < $1.key }.map { try record($0) })
        case "sync.resolve":
            let key = try text(p, "key")
            let resolution = try JSONDecoder().decode(ArgusJSON.self, from: Data(text(p, "document").utf8))
            try app.workspaceSync.resolve(key: key, expectedRevision: text(p, "if-revision"), current: app.workspaceCollections()[key] ?? .null, merged: resolution,
                validate: { try app.applyWorkspaceCollection(key, $0, validateOnly: true) }) {
                try app.applyWorkspaceCollection(key, $0)
            }
            app.syncUserData(); return syncSummary()
        case "status", "doctor":
            return .object(["app": .string("Argus"), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "protocol_version": .number(Double(ArgusWire.version)), "transport": .string("unix-domain-socket"),
                "socket": .string(socketPath), "same_os_user_only": .bool(true), "actor_is_authentication": .bool(false),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"),
                "machines": .array(machineRows()), "event_persistence_error": events.persistenceError.map(ArgusJSON.string) ?? .null,
                "sync": syncSummary(), "permission_requests": .array([])])
        case "capabilities":
            return .object(["commands": try .encode(ArgusCommand.all), "protocol_version": .number(1),
                "views": .array(WorkspaceDestination.allCases.map { .string($0.rawValue) }),
                "limits": .object(["request_bytes": .number(Double(ArgusWire.maxRequestBytes)), "response_bytes": .number(Double(ArgusWire.maxResponseBytes)), "page_size": .number(200), "event_retention": .number(1024), "event_waiters": .number(8)]),
                "cancellation": .string("not supported by the current Weekly Progress execution backend"),
                "sensitive_actions": .string("not exposed; existing credential approval boundaries are unchanged")])
        case "context":
            let limit = try int(p, "limit", default: 20, range: 1...100)
            // Snapshot and its cursor are captured in the same main-actor turn.
            let rows = sessionRows(includeAll: false)
            let attention = rows.filter { $0["needs_attention"].bool == true }
            let notes = app.notes.sorted { $0.editedAt > $1.editedAt }.prefix(limit).map { n in
                ArgusJSON.object(["id": .string(n.id.uuidString), "preview": .string(String(n.text.prefix(200))), "done": .bool(n.done), "revision": .string(((try? ArgusJSON.encode(n)) ?? .null).revision)])
            }
            return .object(["cursor": .string(events.cursor), "observed_at": .string(ISO8601DateFormatter().string(from: Date())),
                "source": .string("cached_app_state"), "app": appState(), "machines": .array(machineRows()),
                "attention": .array(Array(attention.prefix(limit))), "attention_total": .number(Double(attention.count)),
                "lab_attention": .array(Array(labAttention().prefix(limit))), "lab_loaded": .bool(lab?.loadedOnce ?? false),
                "notes": .array(notes), "notes_total": .number(Double(app.notes.count)),
                "todos_pending": try page(todoRows().filter { $0["record"]["done"].bool == false }, ["limit": .string(String(limit))]),
                "planner_pending": try page(app.plannerCommitments.filter { !$0.isCompleted }.sorted { PlannerCommitment.chronologicallyBefore($0, $1) }.map { try record($0) }, ["limit": .string(String(limit))]),
                "weekly_progress": .object(["active_job_id": weekly.operationGenerationID.map { .string($0.uuidString) } ?? .null, "project_count": .number(Double(weekly.projects.count))]),
                "sync": syncSummary()])
        case "events.poll": return try await events.read(after: text(p, "after"), wait: int(p, "wait", default: 0, range: 0...25))
        case "activity.list":
            return try page(journal.state.requests.map { id, entry -> ArgusJSON in
                .object(["request_id": .string(id), "method": .string(entry.method), "actor": .string(entry.actor),
                    "at": .string(ISO8601DateFormatter().string(from: entry.date)), "state": .string(entry.response == nil ? "uncertain" : (entry.response!.ok ? "completed" : "failed"))])
            }.sorted { ($0["at"].string ?? "") > ($1["at"].string ?? "") }, p)
        case "app.state": return appState()
        case "app.show":
            guard let view = WorkspaceDestination(rawValue: try text(p, "view")) else { throw ArgusFailure("invalid_arguments", "Unknown view. See argus capabilities.") }
            let ref = view == .session ? try resolveSession(text(p, "id")) : nil
            if view != .session && p["id"] != nil { throw ArgusFailure("invalid_arguments", "Only app show session accepts an ID.") }
            try app.navigate(to: view, session: ref, origin: .agent(r.actor))
            return appState()
        case "app.activate":
            if !AppState.isRunningTests { NSApp.activate(ignoringOtherApps: true) }
            return .object(["activation_requested": .bool(true)])
        case "sessions.list", "command-center.list":
            var rows = sessionRows(includeAll: p["all"]?.bool == true)
            if let machine = p["machine"]?.string { rows = rows.filter { $0["machine_id"].string == machine || $0["machine_name"].string == machine } }
            if p["needs-attention"]?.bool == true { rows = rows.filter { $0["needs_attention"].bool == true } }
            var result = try page(filter(rows, p), p).object!
            if method == "command-center.list" { result["lab_attention"] = .array(labAttention()); result["lab_loaded"] = .bool(lab?.loadedOnce ?? false) }
            return .object(result)
        case "sessions.get", "command-center.get":
            let ref = try resolveSession(text(p, "id"))
            return sessionRows(includeAll: true).first { $0["alias"].string == ref.id }!
        case "command-center.refresh":
            let ref = try p["id"]?.string.map(resolveSession)
            guard Date().timeIntervalSince(lastCCRefresh) >= 5 else { throw ArgusFailure("rate_limited", "A refresh was just scheduled. Read cached status or wait for an event.") }
            cc.requestRefresh(ref: ref); lastCCRefresh = Date()
            return .object(["scheduled": .bool(true), "completed": .bool(false)])
        case "command-center.correct":
            let ref = try resolveSession(text(p, "id")), label = try text(p, "label")
            guard ["needs-decision", "stuck", "drifting", "working", "look", "milestone", "idle"].contains(label) else { throw ArgusFailure("invalid_arguments", "Unknown Command Center label.") }
            try checkRevision((try? ArgusJSON.encode(cc.statuses[ref.id])) ?? .null, p)
            cc.setManualLabel(ref: ref, label: label, actor: "cli:" + r.actor)
            return sessionRows(includeAll: true).first { $0["alias"].string == ref.id }!
        case "command-center.backlog":
            let ref = try resolveSession(text(p, "id")), desired = try text(p, "state")
            guard ["on", "off"].contains(desired) else { throw ArgusFailure("invalid_arguments", "--state must be on or off.") }
            app.setBacklog(ref, included: desired == "on")
            return sessionRows(includeAll: true).first { $0["alias"].string == ref.id }!
        case "weekly-progress.projects.list": return try page(filter(weekly.projects.map { try record($0) }, p), p)
        case "weekly-progress.projects.get": return try record(resolveProject(text(p, "id")))
        case "weekly-progress.projects.create", "weekly-progress.projects.update":
            let raw = try text(p, "document")
            guard let fields = try JSONDecoder().decode(ArgusJSON.self, from: Data(raw.utf8)).object,
                  Set(fields.keys).isSubset(of: ["name", "panels", "workspaceRoots"]) else { throw ArgusFailure("invalid_arguments", "Project document accepts name, panels, and workspaceRoots.") }
            var project: WeeklyProgressProject
            if method.hasSuffix("update") { project = try resolveProject(text(p, "id")); try checkRevision(.encode(project), p) }
            else { project = WeeklyProgressProject(name: "", panels: []) }
            if let name = fields["name"] { project.name = try name.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let panels = fields["panels"] { project.panels = try panels.decode([WeeklyProgressPanelSelector].self) }
            if let roots = fields["workspaceRoots"] { project.workspaceRoots = try roots.decode([String].self) }
            try weekly.saveProject(project, selectAfterSaving: false)
            return try record(weekly.projects.first { $0.id == project.id }!)
        case "weekly-progress.list", "jobs.list":
            let project = try p["project"]?.string.map(resolveProject)
            let snapshot = await coordinator.snapshot()
            let generations = await loadGenerations()
            return try page(generations.filter { project == nil || $0.manifest.project.id == project!.id }.map { try generationRow($0, active: snapshot.operation?.generationID) }, p)
        case "weekly-progress.get", "jobs.get":
            let id = try uuid(text(p, "id")); let snapshot = await coordinator.snapshot()
            guard let generation = await loadGenerations().first(where: { $0.manifest.id == id }) else { throw ArgusFailure("not_found", "No Weekly Progress generation has this ID.") }
            return try generationRow(generation, active: snapshot.operation?.generationID)
        case "weekly-progress.generate":
            let project = try resolveProject(text(p, "project")), raw = try text(p, "week")
            let date = try parseDeadline(raw)
            guard !date.exact else { throw ArgusFailure("invalid_arguments", "--week must be YYYY-MM-DD, a Monday in the Mac's local timezone.") }
            let week = WeeklyProgressWeek(start: date.date)
            guard week.storageKey == raw else { throw ArgusFailure("invalid_arguments", "--week must name the Monday beginning the week.") }
            let generation = try await coordinator.start(projectID: project.id, week: week, requestID: r.id)
            return try generationRow(generation, active: generation.manifest.id)
        case "weekly-progress.resume":
            let generation = try await coordinator.resume(generationID: uuid(text(p, "id")), requestID: r.id)
            return try generationRow(generation, active: (await coordinator.snapshot()).operation?.generationID)
        default: throw ArgusFailure("unknown_command", "Command has no app action.")
        }
    }

    private func workspaceCommand(_ r: ArgusRequest) throws -> ArgusJSON {
        let app = app!, journal = journal!, p = r.params, method = r.method
        let id = p["id"]?.string
        if method == "notes.list" { return try page(filter(app.notes.sorted { $0.editedAt > $1.editedAt }.map { try record($0) }, p), p) }
        if method == "notes.create" {
            let content = try text(p, "text", allowEmpty: true)
            let id = app.addNote(text: content)
            return try saved(app.notes.first { $0.id == id }!)
        }
        if method.hasPrefix("notes.") {
            guard let note = app.notes.first(where: { $0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame }) else { throw notFound("note") }
            if method == "notes.get" { return try record(note) }
            try checkRevision(.encode(note), p)
            switch method {
            case "notes.update": app.updateNoteText(note.id, try text(p, "text", allowEmpty: true))
            case "notes.complete", "notes.reopen": app.setNoteCompleted(note.id, completed: method.hasSuffix("complete"))
            case "notes.archive":
                let archiveID = try journal.archive(kind: "note", record: .encode(note)); app.deleteNote(note.id)
                return .object(["archive_id": .string(archiveID.uuidString), "saved_locally": .bool(true)])
            default: throw notFound("command")
            }
            return try saved(app.notes.first { $0.id == note.id }!)
        }
        if method == "todos.boards.list" { return try page(filter(app.todoBoards.map { try record($0) }, p), p) }
        if method == "todos.boards.get" { return try record(board(id ?? "")) }
        if method == "todos.boards.create" {
            let machine = try text(p, "machine"), session = try text(p, "session")
            app.ensureBoard(machine: machine, session: session)
            guard let board = app.todoBoards.first(where: { $0.machine == machine.trimmingCharacters(in: .whitespaces) && $0.session == session.trimmingCharacters(in: .whitespaces) }) else { throw notFound("board") }
            return try saved(board)
        }
        if method == "todos.items.list" {
            var rows = todoRows()
            if let boardID = p["board"]?.string { let b = try board(boardID); rows = rows.filter { $0["board_id"].string == b.id.uuidString } }
            if p["pending"]?.bool == true { rows = rows.filter { $0["record"]["done"].bool == false } }
            return try page(filter(rows, p), p)
        }
        if method == "todos.items.create" {
            let b = try board(text(p, "board")), content = try text(p, "text")
            app.addTodo(b.id, content)
            let created = app.todoBoards.first { $0.id == b.id }!.items.last!
            return try saved(created, extra: ["board_id": .string(b.id.uuidString)])
        }
        if method.hasPrefix("todos.items.") {
            guard let b = app.todoBoards.first(where: { $0.items.contains { $0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame } }),
                  let item = b.items.first(where: { $0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame }) else { throw notFound("todo") }
            if method == "todos.items.get" { return try record(item, extra: ["board_id": .string(b.id.uuidString)]) }
            try checkRevision(.encode(item), p)
            switch method {
            case "todos.items.update": app.updateTodoText(b.id, item.id, text: try text(p, "text"))
            case "todos.items.complete", "todos.items.reopen": app.setTodoCompleted(b.id, item.id, completed: method.hasSuffix("complete"))
            case "todos.items.archive":
                let archiveID = try journal.archive(kind: "todo", record: .encode(item), parentID: b.id.uuidString)
                app.deleteTodo(b.id, item.id); return .object(["archive_id": .string(archiveID.uuidString), "saved_locally": .bool(true)])
            default: throw notFound("command")
            }
            let updated = app.todoBoards.first { $0.id == b.id }!.items.first { $0.id == item.id }!
            return try saved(updated, extra: ["board_id": .string(b.id.uuidString)])
        }
        if method == "planner.list" {
            let items = app.plannerCommitments.filter { p["pending"]?.bool != true || !$0.isCompleted }.sorted { PlannerCommitment.chronologicallyBefore($0, $1) }
            return try page(filter(items.map { try record($0) }, p), p)
        }
        if method == "planner.create" {
            let deadline = try parseDeadline(text(p, "deadline"))
            guard let id = app.addPlannerCommitment(title: try text(p, "title"), project: p["project"]?.string ?? "", deadline: deadline.date, hasExactTime: deadline.exact) else { throw ArgusFailure("invalid_arguments", "A title is required.") }
            return try saved(app.plannerCommitments.first { $0.id == id }!)
        }
        if method.hasPrefix("planner.") {
            guard let item = app.plannerCommitments.first(where: { $0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame }) else { throw notFound("commitment") }
            if method == "planner.get" { return try record(item) }
            try checkRevision(.encode(item), p)
            switch method {
            case "planner.update":
                let deadline = try p["deadline"]?.string.map(parseDeadline) ?? (item.deadline, item.hasExactTime)
                app.updatePlannerCommitment(item.id, title: p["title"]?.string ?? item.title, project: p["project"]?.string ?? item.project, deadline: deadline.0, hasExactTime: deadline.1)
            case "planner.complete", "planner.reopen": app.setPlannerCompleted(item.id, completed: method.hasSuffix("complete"))
            case "planner.archive":
                let archiveID = try journal.archive(kind: "planner", record: .encode(item)); app.deletePlannerCommitment(item.id)
                return .object(["archive_id": .string(archiveID.uuidString), "saved_locally": .bool(true)])
            default: throw notFound("command")
            }
            return try saved(app.plannerCommitments.first { $0.id == item.id }!)
        }
        if method == "archive.list" { return try page(journal.state.archives.filter { !$0.restored }.reversed().map { try .encode($0) }, p) }
        if method == "archive.restore" {
            guard let entry = journal.state.archives.first(where: { $0.id.uuidString.caseInsensitiveCompare(id ?? "") == .orderedSame }), !entry.restored else { throw notFound("archive entry") }
            switch entry.kind {
            case "note":
                let note = try entry.record.decode(Note.self)
                guard !app.notes.contains(where: { $0.id == note.id }) else { throw restoreConflict }
                app.notes.append(note)
            case "todo":
                let item = try entry.record.decode(TodoItem.self)
                guard !app.todoBoards.contains(where: { $0.items.contains { $0.id == item.id } }),
                      let i = app.todoBoards.firstIndex(where: { $0.id.uuidString == entry.parentID }) else { throw restoreConflict }
                app.todoBoards[i].items.append(item)
            case "planner":
                let item = try entry.record.decode(PlannerCommitment.self)
                guard !app.plannerCommitments.contains(where: { $0.id == item.id }) else { throw restoreConflict }
                app.plannerCommitments.append(item)
            default: throw notFound("archive kind")
            }
            try journal.markRestored(entry.id)
            return .object(["restored": .bool(true), "record": entry.record, "saved_locally": .bool(true)])
        }
        throw notFound("command")
    }

    private func appState() -> ArgusJSON {
        guard let app else { return .null }
        let selected = sessionRows(includeAll: true).first { $0["alias"].string == app.selection?.id }
        return .object(["view": .string(app.workspaceDestination.rawValue), "selected_session_id": selected?["id"] ?? .null,
                        "selection_alias": app.selection.map { .string($0.id) } ?? .null,
                        "active": .bool(!AppState.isRunningTests && NSApp.isActive)])
    }
    private func labAttention() -> [ArgusJSON] {
        (lab?.attentionItems ?? []).map { item in .object(["id": .string(item.id), "kind": .string(item.kind.rawValue),
            "reference": .string(item.reference), "project": .string(item.project), "machine": .string(item.machineName),
            "summary": .string(item.summary), "created": .string(item.created), "requires_human_approval": .bool(true)]) }
    }
    private func machineRows() -> [ArgusJSON] {
        guard let app else { return [] }
        return app.machines.map { m in .object(["id": .string(m.id), "name": .string(m.name), "local": .bool(m.isLocal),
            "status": .string(app.statusByMachine[m.id]?.rawValue ?? "checking"),
            "issue": app.refreshIssueByMachine[m.id].map(ArgusJSON.string) ?? .null]) }
    }
    private func sessionRows(includeAll: Bool, includeFreshness: Bool = true) -> [ArgusJSON] {
        guard let app, let cc = commandCenter else { return [] }
        return app.machines.flatMap { m in (app.sessionsByMachine[m.id] ?? []).compactMap { s -> ArgusJSON? in
            let ref = SessionRef(machineID: m.id, session: s.name)
            if !includeAll && (s.agent || s.hidden || app.hiddenSessions.contains(ref.id)) { return nil }
            let summary = (try? ArgusJSON.encode(cc.statuses[ref.id])) ?? .null
            let section = ccSection(state: s.state, status: cc.statuses[ref.id])
            let observed = (s.agent || s.hidden) ? app.fullSnapshotAt[m.id] : app.foregroundSnapshotAt[m.id]
            let observedValue: ArgusJSON
            if includeFreshness, let observed { observedValue = .string(ISO8601DateFormatter().string(from: observed)) }
            else { observedValue = .null }
            return .object(["id": .string(s.lineageID.map { m.id + "#" + $0 } ?? "alias:" + ref.id), "alias": .string(ref.id),
                "identity_kind": .string(s.lineageID == nil ? "name_alias_legacy_broker" : "session_lifetime"),
                "name": .string(s.name), "machine_id": .string(m.id), "machine_name": .string(m.name),
                "connection": .string(app.statusByMachine[m.id]?.rawValue ?? "checking"),
                "path": .string(app.resolveBase(for: ref)), "state_observed": .string(s.state),
                "state_observed_at": observedValue,
                "summary_inferred": summary, "summary_revision": .string(summary.revision),
                "needs_attention": .bool(section == 0 && !app.backlog.contains(ref.id)),
                "backlog": .bool(app.backlog.contains(ref.id)), "hidden": .bool(s.hidden || app.hiddenSessions.contains(ref.id)), "agent": .bool(s.agent)])
        }}
    }
    private func resolveSession(_ id: String) throws -> SessionRef {
        let rows = sessionRows(includeAll: true)
        let exact = rows.filter { $0["id"].string == id || $0["alias"].string == id }
        let matches = exact.isEmpty ? rows.filter { $0["name"].string == id } : exact
        guard matches.count == 1, let row = matches.first else {
            if matches.isEmpty { throw notFound("session") }
            throw ArgusFailure("ambiguous_target", "More than one session matches; use its ID.", details: .array(matches))
        }
        return SessionRef(machineID: row["machine_id"].string!, session: row["name"].string!)
    }
    private func resolveProject(_ id: String) throws -> WeeklyProgressProject {
        let all = weekly!.projects
        let exact = all.filter { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
        let matches = exact.isEmpty ? all.filter { $0.name.caseInsensitiveCompare(id) == .orderedSame } : exact
        guard matches.count == 1 else {
            if matches.isEmpty { throw notFound("project") }
            throw ArgusFailure("ambiguous_target", "More than one project matches; use a project ID.", details: try .encode(matches))
        }; return matches[0]
    }
    private func board(_ id: String) throws -> TodoBoard {
        let matches = app!.todoBoards.filter { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame || (id == "misc" && $0.isMisc) }
        guard matches.count == 1 else { throw notFound("board") }; return matches[0]
    }
    private func todoRows() -> [ArgusJSON] {
        app!.todoBoards.flatMap { board in board.items.compactMap { try? record($0, extra: ["board_id": .string(board.id.uuidString)]) } }
    }
    private func record<T: Encodable>(_ value: T, extra: [String: ArgusJSON] = [:]) throws -> ArgusJSON {
        let record = try ArgusJSON.encode(value)
        return .object(extra.merging(["record": record, "revision": .string(record.revision)]) { _, new in new })
    }
    private func saved<T: Encodable>(_ value: T, extra: [String: ArgusJSON] = [:]) throws -> ArgusJSON {
        try record(value, extra: extra.merging(["saved_locally": .bool(true), "sync": syncSummary()]) { _, new in new })
    }
    private func syncSummary() -> ArgusJSON {
        guard let app else { return .null }
        return .object(["collections": app.workspaceSync.summary(current: app.workspaceCollections()),
                        "storage_error": app.workspaceStorageError.map(ArgusJSON.string) ?? .null])
    }

    var recentActivity: [(id: String, entry: ArgusStoredRequest)] {
        (journal?.state.requests.map { (id: $0.key, entry: $0.value) } ?? [])
            .sorted { $0.entry.date > $1.entry.date }.prefix(100).map { $0 }
    }
    private func checkRevision(_ value: ArgusJSON, _ p: [String: ArgusJSON]) throws {
        guard try text(p, "if-revision") == value.revision else {
            throw ArgusFailure("conflict", "This record changed since it was read. Read it again and reconcile before editing.", details: .object(["current": value, "revision": .string(value.revision)]))
        }
    }
    private func text(_ p: [String: ArgusJSON], _ key: String, allowEmpty: Bool = false) throws -> String {
        guard let value = p[key]?.string, value.utf8.count <= 131_072,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArgusFailure("invalid_arguments", "--\(key) must be \(allowEmpty ? "a" : "a nonempty") string of at most 128 KiB.")
        }; return value
    }
    private func int(_ p: [String: ArgusJSON], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = p[key]?.string else { return fallback }
        guard let n = Int(raw), range.contains(n) else { throw ArgusFailure("invalid_arguments", "--\(key) must be in \(range).") }; return n
    }
    private func page(_ values: [ArgusJSON], _ p: [String: ArgusJSON]) throws -> ArgusJSON {
        let limit = try int(p, "limit", default: 50, range: 1...200), offset = try int(p, "offset", default: 0, range: 0...Int.max)
        return .object(["items": .array(Array(values.dropFirst(min(offset, values.count)).prefix(limit))), "total": .number(Double(values.count)),
            "next_offset": offset < values.count && values.count - offset > limit ? .string(String(offset + limit)) : .null])
    }
    private func filter(_ rows: [ArgusJSON], _ p: [String: ArgusJSON]) -> [ArgusJSON] {
        guard let query = p["query"]?.string, !query.isEmpty else { return rows }
        return rows.filter { row in
            guard let bytes = try? ArgusWire.encoder().encode(row), let text = String(data: bytes, encoding: .utf8) else { return false }
            return text.localizedCaseInsensitiveContains(query)
        }
    }
    private func parseDeadline(_ value: String) throws -> (date: Date, exact: Bool) {
        if value.count == 10 {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
            if let date = f.date(from: value), f.string(from: date) == value { return (date, false) }
        } else if let date = ISO8601DateFormatter().date(from: value) { return (date, true) }
        throw ArgusFailure("invalid_arguments", "Date must be YYYY-MM-DD (Mac local end-of-day) or an ISO-8601 timestamp with timezone.")
    }
    private func uuid(_ value: String) throws -> UUID { guard let id = UUID(uuidString: value) else { throw ArgusFailure("invalid_arguments", "Expected a UUID.") }; return id }
    private func notFound(_ kind: String) -> ArgusFailure { ArgusFailure("not_found", "No \(kind) matches this ID in the app.") }
    private var restoreConflict: ArgusFailure { ArgusFailure("conflict", "Cannot restore: the original ID already exists, or the parent board is missing. No current data was overwritten.") }
    private func loadGenerations() async -> [WeeklyProgressGeneration] {
        let store = store
        return await Task.detached(priority: .utility) { store.allGenerations().sorted { $0.manifest.createdAt > $1.manifest.createdAt } }.value
    }
    private func generationRow(_ generation: WeeklyProgressGeneration, active: UUID?) throws -> ArgusJSON {
        let manifest = generation.manifest
        let state = manifest.stage == .complete ? "complete" : (active == manifest.id ? "running" : (manifest.stage == .failed ? "failed" : "interrupted"))
        return .object(["id": .string(manifest.id.uuidString), "state": .string(state), "manifest": try .encode(manifest),
            "directory": .string(generation.directory.path), "machine": .string("local"),
            "outputs": .object(manifest.outputs.mapValues { .string(generation.directory.appendingPathComponent($0).standardizedFileURL.path) }),
            "cancel_supported": .bool(false)])
    }
}
