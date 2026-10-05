import AppKit
import Foundation
import ArgusProtocol
import UsageKit

/// The service is a separate launchd-owned process. Opening/closing an app view
/// cannot start a second collector or stop the workspace's collection work.
enum WorkspaceServiceLauncher {
    static let label = "dev.universaltmux.workspace"
    @MainActor static func ensureRunning() throws {
        guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL,
              !CommandLine.arguments.contains("--workspace-worker") else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directory = home.appendingPathComponent("Library/LaunchAgents")
        let file = directory.appendingPathComponent(label + ".plist")
        let logs = home.appendingPathComponent("Library/Logs/Argus")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let build = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "--workspace-worker", "--build=\(build)"],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 15, "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("workspace.log").path,
            "StandardErrorPath": logs.appendingPathComponent("workspace.log").path]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let changed = (try? Data(contentsOf: file)) != data
        if changed { try data.write(to: file, options: .atomic) }
        let domain = "gui/\(getuid())"
        func run(_ args: [String]) throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        if changed { _ = try run(["bootout", domain + "/" + label]) }
        if try run(["print", domain + "/" + label]) != 0 {
            guard try run(["bootstrap", domain, file.path]) == 0 else {
                throw ArgusFailure("service_start_failed", "Workspace background service could not start.")
            }
        }
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains("--workspace-worker") else { return }
        let prefix = "--workspace-endpoint="
        let base = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            ?? "http://127.0.0.1:8722"
        // Collection and credential ownership stay on the local host. An
        // explicit loopback endpoint also permits isolated process-level checks.
        guard let url = URL(string: base), url.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "") else { exit(2) }
        Task { @MainActor in await WorkspaceCollector(base: base).run() }
        dispatchMain()
    }
}

@MainActor
private final class WorkspaceCollector {
    private let app = AppState(runtime: .background)
    private let cc = CommandCenterModel(collector: true)
    private let replica = SharedWorkspaceReplica(directory: nil, transport: sharedWorkspaceRequest)
    private let owner = UUID().uuidString
    private let base: String
    private var leases: [String: ArgusJSON] = [:]
    private var nextDiscovery = Date.distantPast
    private var nextUsage = Date.distantPast
    private var usageTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var usageController: AnyObject?
    private var statusesDirty = false
    private var settingsApplied: ArgusJSON?
    private var dismissalsApplied: ArgusJSON?
    private var usagePresentationDirty = true
    private var journalTask: Task<Void, Never>?
    private var journalPublished: [String: String] = [:]
    private var nextJournal = Date.distantPast
    private var nextWrapped = Date.distantPast
    private var personaTask: Task<Void, Never>?
    private var nextPersona = Date.distantPast

    init(base: String) {
        self.base = base
        app.machines[0].httpBase = base
        app.machines[0].wsBase = base.replacingOccurrences(of: "http://", with: "ws://")
    }

    private func owns(_ name: String) -> Bool {
        Double(leases[name]?["expiresAt"].uint64 ?? 0) / 1000 > Date().timeIntervalSince1970 + 10
    }

    func run() async {
        cc.bind(app)
        ActivityJournal.shared.nameResolver = { [weak app] id in app?.machines.first { $0.id == id }?.name }
        cc.collectionAllowed = { [weak self] in self?.owns("cc-status") == true }
        cc.collectionGeneration = { [weak self] in self?.leases["cc-status"]?["fence"].uint64 }
        cc.statusesChanged = { [weak self] in self?.statusesDirty = true }
        while !Task.isCancelled {
            do { try await tick() }
            catch { statusesDirty = true; NSLog("[workspace-service] %@", error.localizedDescription) }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func tick() async throws {
        let info = try await sharedWorkspaceRequest(base, "/workspace/info")
        guard info["enabled"].bool == true, let id = info["workspaceID"].string else { return }
        if replica.workspaceID != id { try replica.bind(id) }
        await replica.synchronize(base: base)
        guard replica.loaded, replica.issue == nil else { return }
        for name in ["cc-status", "usage", "journal"] {
            let previousFence = leases[name]?["fence"]
            do {
                leases[name] = try await sharedWorkspaceRequest(base, "/workspace/lease", .object([
                    "name": .string(name), "owner": .string(owner), "ttlSeconds": .number(120)]))
            } catch { leases[name] = nil }
            if name == "cc-status", previousFence != leases[name]?["fence"] { cc.collectionOwnershipChanged(); statusesDirty = false }
        }
        if Date() >= nextDiscovery {
            let base = base
            let found = await Task.detached(priority: .utility) { discoverMachines(base: base) }.value
            for machine in found {
                if let index = app.machines.firstIndex(where: { $0.id == machine.id }) { app.machines[index] = machine }
                else { app.machines.append(machine) }
            }
            nextDiscovery = Date().addingTimeInterval(30)
        }
        if let index = app.machines.firstIndex(where: \.isLocal) {
            app.machines[index].brokerID = info["brokerID"].string ?? ""
            app.machines[index].workspaceID = id; app.machines[index].workspaceEnabled = true
        }
        for machine in app.machines { app.refresh(machine, scope: .all) }
        if owns("journal"), journalTask == nil, Date() >= nextJournal {
            nextJournal = Date().addingTimeInterval(30)
            let brokerID = info["brokerID"].string ?? ""
            journalTask = Task {
                defer { journalTask = nil }
                do { try await collectJournal(brokerID: brokerID) }
                catch { NSLog("[workspace-service] Journal: %@", error.localizedDescription) }
            }
        }
        if owns("cc-status") { cc.collectTick() }
        if owns("journal"), personaTask == nil, Date() >= nextPersona,
           let command = replica.collection("commands").first(where: { $0.data?["kind"].string == "wrapped-persona" }),
           let days = command.data?["days"].uint64,
           let stats = replica.data("journal", "wrapped")?["periods"][String(days)], stats.object != nil {
            nextPersona = Date().addingTimeInterval(300)
            let fence = leases["journal"]?["fence"]
            personaTask = Task {
                defer { personaTask = nil }
                do {
                    let object = try JSONSerialization.jsonObject(with: ArgusWire.encoder().encode(stats)) as? [String: Any] ?? [:]
                    guard let persona = await WrappedPersona.generate(stats: object), owns("journal"), leases["journal"]?["fence"] == fence else { return }
                    let value = try JSONDecoder().decode(ArgusJSON.self, from: JSONEncoder().encode(persona))
                    try await publish("journal", id: "persona-\(days)", data: .object(["kind": .string("persona"), "persona": value]))
                    try await remove(command)
                    nextPersona = .distantPast
                } catch { NSLog("[workspace-service] Wrapped persona: %@", error.localizedDescription) }
            }
        }

        if owns("cc-status") {
            // A correction is removed only after the corrected status is durably
            // published. A newer correction wins compare-and-swap on deletion.
            for record in replica.collection("cc-overrides") {
                guard let ref = reference(record.id), let label = record.data?["label"].string else { continue }
                let actor = record.data?["actor"].string ?? "human"
                let commandID = record.data?["commandID"].string ?? "override-\(record.revision)"
                let previous = cc.statuses[ref.id]?.label ?? replica.data("cc-status", record.id)?["label"].string ?? "idle"
                let note = "[STATUS CORRECTION] A \(actor == "human" ? "human" : "local automation client") changed this session's status from \"\(previous)\" to \"\(label)\". Treat this as a correction, not a permanent lock."
                try await retainFeedback(identity: record.id, commandID: commandID, label: label, actor: actor, note: note)
                cc.setManualLabel(ref: ref, label: label, actor: actor, correctionID: commandID, note: note)
                if let status = cc.statuses[ref.id] {
                    try await publishStatus(record.id, status)
                    try await remove(record)
                }
            }
            for feedback in replica.collection("commands") where feedback.data?["kind"].string == "cc-feedback" {
                guard let data = feedback.data, let identity = data["sessionID"].string,
                      let ref = reference(identity), let id = data["commandID"].string, let label = data["label"].string else { continue }
                // Do not replay old feedback over a newer pending correction.
                if let newer = replica.data("cc-overrides", identity), newer["commandID"].string != id { continue }
                cc.setManualLabel(ref: ref, label: label, actor: data["actor"].string ?? "human", correctionID: id, note: data["note"].string)
                if cc.correctionDelivered(ref: ref, id: id), let status = cc.statuses[ref.id] {
                    try await publishStatus(identity, status)
                    try await remove(feedback)
                }
            }
            if statusesDirty {
                statusesDirty = false
                for (key, status) in cc.statuses {
                    guard let ref = localReference(key), let identity = app.sharedSessionKey(ref) else { continue }
                    try await publishStatus(identity, status)
                }
            }
        }
        if #available(macOS 14.0, *), owns("usage"), usageController == nil {
            usageController = UsageController()
        }
        if #available(macOS 14.0, *), let usage = usageController as? UsageController {
            if owns("usage"), accountTask == nil, let lease = leases["usage"] {
                let call = try await sharedWorkspaceRequest(base, "/workspace/service/usage/take", lease)
                if let id = call["id"].string, call["body"].object != nil {
                    accountTask = Task {
                        defer { accountTask = nil }
                        do {
                            let result = await usage.handleAccountService(try ArgusWire.encoder().encode(call["body"]))
                            guard owns("usage"), leases["usage"]?["fence"] == lease["fence"] else { return }
                            _ = try await sharedWorkspaceRequest(base, "/workspace/service/usage/reply", .object([
                                "id": .string(id), "lease": lease, "body": try JSONDecoder().decode(ArgusJSON.self, from: result)]))
                            if call["body"]["action"].string != "state" { nextUsage = .distantPast }
                        } catch { NSLog("[workspace-service] Account request was not acknowledged.") }
                    }
                }
            }
            if let settings = replica.data("usage-settings", "default"), settings != settingsApplied {
                try usage.applySharedSettings(ArgusWire.encoder().encode(settings)); settingsApplied = settings; usagePresentationDirty = true
            }
            if let dismissals = replica.data("usage-dismissals", "default"), dismissals != dismissalsApplied {
                try usage.applySharedDismissals(ArgusWire.encoder().encode(dismissals)); dismissalsApplied = dismissals; usagePresentationDirty = true
            }
            if owns("usage"), usagePresentationDirty, usageTask == nil {
                try await publish("usage", id: "current", data: JSONDecoder().decode(ArgusJSON.self, from: usage.sharedSnapshot()))
                usagePresentationDirty = false
            }
            let commands = replica.collection("commands").filter { $0.data?["kind"].string == "usage-refresh" }
            if owns("usage"), usageTask == nil, accountTask == nil, Date() >= nextUsage || !commands.isEmpty {
                nextUsage = Date().addingTimeInterval(usage.collectionInterval)
                let fence = leases["usage"]?["fence"]
                usageTask = Task {
                    defer { usageTask = nil }
                    await usage.collectForWorkspace()
                    guard owns("usage"), leases["usage"]?["fence"] == fence else { return }
                    do {
                        let snapshot = try JSONDecoder().decode(ArgusJSON.self, from: usage.sharedSnapshot())
                        try await publish("usage", id: "current", data: snapshot)
                        for command in commands { try await remove(command) }
                    } catch { NSLog("[workspace-service] Usage publication: %@", error.localizedDescription) }
                }
            }
        }
        if owns("cc-status") {
            for command in replica.collection("commands") where command.data?["kind"].string == "cc-refresh" {
                cc.requestRefresh(ref: command.data?["sessionID"].string.flatMap(reference))
                try await remove(command)
            }
        }
    }

    private func localReference(_ key: String) -> SessionRef? {
        for machine in app.machines {
            for session in app.sessionsByMachine[machine.id] ?? [] {
                let ref = SessionRef(machineID: machine.id, session: session.name)
                if ref.id == key { return ref }
            }
        }
        return nil
    }

    private func collectJournal(brokerID: String) async throws {
        guard let lease = leases["journal"] else { return }
        guard ActivityJournal.isEnabled else { return }
        let inbox = try await sharedWorkspaceRequest(base, "/journal/peek")
        if let offset = inbox["off"].uint64, offset > 0, let text = inbox["data"].string, !text.isEmpty {
            try await Task.detached(priority: .utility) { try JournalFileStore.ingest(text, directory: ActivityJournal.dirURL) }.value
            _ = try await sharedWorkspaceRequest(base, "/journal/ack?off=\(offset)", .object([:]))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: ActivityJournal.dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var uploaded = 0
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard owns("journal"), leases["journal"]?["fence"] == lease["fence"] else { return }
            let stat = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fingerprint = "\(stat.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(stat.fileSize ?? 0)"
            if journalPublished[file.lastPathComponent] == fingerprint { continue }
            let data = try await Task.detached(priority: .utility) { try Data(contentsOf: file) }.value
            // Never publish a partially appended last line; the next pass includes it.
            let complete = data.lastIndex(of: 0x0a).map { Data(data[...$0]) } ?? Data()
            let hash = try await WorkspaceBlobs.upload(complete, base: base)
            let day = file.deletingPathExtension().lastPathComponent
            try await publish("journal", id: brokerID + "/" + day, data: .object([
                "kind": .string("day"), "day": .string(day), "brokerID": .string(brokerID), "hash": .string(hash),
                "count": .number(Double(complete.filter { $0 == 0x0a }.count)), "byteCount": .number(Double(complete.count))]), expectedLease: lease)
            journalPublished[file.lastPathComponent] = fingerprint
            uploaded += 1
            if uploaded >= 4 { break }
        }
        if Date() >= nextWrapped, owns("journal") {
            nextWrapped = Date().addingTimeInterval(300)
            let stats = try await Task.detached(priority: .utility) { () throws -> ArgusJSON in
                var periods: [String: ArgusJSON] = [:]
                for days in [0, 7, 30, 90, 365] {
                    periods[String(days)] = try JSONDecoder().decode(ArgusJSON.self, from: JSONSerialization.data(withJSONObject: WrappedStats.compute(days: days)))
                }
                return .object(["kind": .string("wrapped"), "periods": .object(periods)])
            }.value
            try await publish("journal", id: "wrapped", data: stats, expectedLease: lease)
        }
    }
    private func reference(_ identity: String) -> SessionRef? {
        for machine in app.machines {
            for session in app.sessionsByMachine[machine.id] ?? [] {
                let ref = SessionRef(machineID: machine.id, session: session.name)
                if app.sharedSessionKey(ref) == identity { return ref }
            }
        }
        return nil
    }
    private func publishStatus(_ identity: String, _ status: AgentStatus) async throws {
        var fields: [String: ArgusJSON] = ["label": .string(status.label), "summary": .string(status.oneLiner),
            "updatedAt": .number(floor(status.updatedAt.timeIntervalSince1970 * 1000))]
        if let look = status.lookAtThis { fields["lookAtThis"] = .string(look) }
        try await publish("cc-status", id: identity, data: .object(fields))
    }
    private func retainFeedback(identity: String, commandID: String, label: String, actor: String, note: String) async throws {
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "collection", value: "commands"), URLQueryItem(name: "id", value: "cc-feedback/" + identity)]
        let current = try await sharedWorkspaceRequest(base, "/workspace/record" + (query.string ?? ""))
        if current["deleted"].bool != true, current["data"]["commandID"].string == commandID { return }
        _ = try await sharedWorkspaceRequest(base, "/workspace/mutate", .object([
            "mutationID": .string(UUID().uuidString), "collection": .string("commands"), "id": .string("cc-feedback/" + identity),
            "baseRevision": current["revision"], "lease": leases["cc-status"] ?? .null,
            "data": .object(["kind": .string("cc-feedback"), "sessionID": .string(identity), "commandID": .string(commandID),
                              "label": .string(label), "actor": .string(actor), "note": .string(note)])]))
    }
    private func publish(_ collection: String, id: String, data: ArgusJSON, expectedLease: ArgusJSON? = nil) async throws {
        guard owns(collection), let lease = expectedLease ?? leases[collection], lease["fence"] == leases[collection]?["fence"] else { throw ArgusFailure("lease_lost", "The collector no longer owns this publication.") }
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "collection", value: collection), URLQueryItem(name: "id", value: id)]
        let current = try await sharedWorkspaceRequest(base, "/workspace/record" + (query.string ?? ""))
        if current["data"] == data && current["deleted"].bool != true { return }
        _ = try await sharedWorkspaceRequest(base, "/workspace/mutate", .object([
            "mutationID": .string(UUID().uuidString), "collection": .string(collection), "id": .string(id),
            "baseRevision": current["revision"], "data": data, "lease": lease]))
    }
    private func remove(_ record: SharedWorkspaceRecord) async throws {
        _ = try await sharedWorkspaceRequest(base, "/workspace/mutate", .object([
            "mutationID": .string(UUID().uuidString), "collection": .string(record.collection), "id": .string(record.id),
            "baseRevision": .number(Double(record.revision)), "delete": .bool(true)]))
    }
}
