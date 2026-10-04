import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: Machine launchers — request a machine that does not exist yet.
//
// A launcher is a local command that provisions a machine which then runs a ut
// broker (a scheduler job, a cloud VM, a container). Argus stays scheduler-
// agnostic: it only runs the command on this Mac and watches ordinary broker
// discovery for the machine it produces. When that machine joins the tailnet it
// is just another entry in every machine picker.
//
// The command may print a line `ARGUS_MACHINE=<name>` naming the machine it
// provisioned (or reused). Otherwise the first NEW machine matching the
// launcher's pattern is taken as the result.

struct MachineLauncher: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Run on this Mac by a login shell (`/bin/zsh -lc`).
    var command: String
    /// Wildcard machine-name pattern (as in Workflows), e.g. "babel-*". Optional
    /// when the command prints ARGUS_MACHINE=<name>.
    var machinePattern: String = ""

    /// CMU Babel: a 3-day, 1-GPU russ-lab job through the bundled Slurm launcher.
    /// Everything is in the editable command (host alias, partition, resources).
    static func babelPreset() -> MachineLauncher {
        MachineLauncher(
            name: "Babel · 3-day GPU job",
            command: "\"$ARGUS_LAUNCHERS/slurm-node\" babel up --partition=russ-lab --qos=russ_lab_qos "
                + "--gres=gpu:1 --cpus-per-task=16 --mem=64G --time=3-00:00:00",
            machinePattern: "babel-*")
    }
}

/// Bundled launcher scripts (Contents/Resources/launchers), exported to launcher
/// commands as $ARGUS_LAUNCHERS.
enum BundledLaunchers {
    static var directory: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("launchers", isDirectory: true) }
    }
}

struct MachineLaunchRun: Identifiable, Equatable {
    enum Phase: Equatable {
        case running                 // the command is still executing
        case waitingForMachine       // command finished; watching discovery
        case ready(machineID: String, machineName: String)
        case failed(String)
        case stopped
    }
    let id = UUID()
    let launcher: MachineLauncher
    let startedAt: Date
    /// Machine ids known when the request started; a pattern match must be new.
    let machinesBefore: Set<String>
    var phase: Phase = .running
    var lastLine = ""
    var announcedMachine: String?
    var commandFinishedAt: Date?

    var isActive: Bool { phase == .running || phase == .waitingForMachine }
}

enum MachineLaunchMatching {
    static let announcementPrefix = "ARGUS_MACHINE="

    /// The machine a line of launcher output announces, if any.
    static func announcedMachine(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(announcementPrefix) else { return nil }
        let name = trimmed.dropFirst(announcementPrefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Resolve a request against the current machine list. An announced name
    /// matches a machine's display name or host, allowing a domain suffix
    /// (`node7` ↔ `node7.cluster.example`), and may be a machine that already
    /// existed (a reused allocation). Without an announcement only a machine that
    /// appeared after the request and matches the pattern counts.
    static func resolve(announced: String?, pattern: String, before: Set<String>,
                        machines: [Machine]) -> Machine? {
        let remote = machines.filter { !$0.isLocal }
        if let announced = announced?.lowercased(), !announced.isEmpty {
            func same(_ value: String) -> Bool {
                let v = value.lowercased()
                return v == announced || v.hasPrefix(announced + ".") || announced.hasPrefix(v + ".")
            }
            return remote.first { same($0.name) || same($0.host) }
        }
        guard let re = AppState.wildcard(pattern) else { return nil }
        return remote.first { m in
            !before.contains(m.id) && (AppState.matches(re, m.name) || AppState.matches(re, m.host))
        }
    }
}

@MainActor
final class MachineLauncherStore: ObservableObject {
    private static let defaultsKey = "ut.machineLaunchers.v1"
    /// How long to watch discovery after the command exits before giving up.
    static let machineWaitLimit: TimeInterval = 10 * 60

    @Published var launchers: [MachineLauncher] = MachineLauncherStore.load() {
        didSet { Self.save(launchers) }
    }
    @Published private(set) var runs: [MachineLaunchRun] = []
    /// Bumped when a run becomes ready, so an open picker can select the machine.
    @Published private(set) var lastReady: (runID: UUID, machineID: String)?

    private weak var state: AppState?
    private var machinesSub: AnyCancellable?
    private var processes: [UUID: Process] = [:]
    private var discoveryTimer: Timer?
    /// Asks for an immediate merge-only broker discovery; replaced in tests.
    var discover: () -> Void = {}
    /// Where $ARGUS_LAUNCHERS points; replaced in tests.
    var launcherDirectory: URL? = BundledLaunchers.directory

    func attach(_ s: AppState) {
        guard state !== s else { return }
        state = s
        discover = { [weak s] in s?.discoverNewBrokers() }
        machinesSub = s.$machines.sink { [weak self] machines in
            Task { @MainActor in self?.machinesChanged(machines) }
        }
    }

    var activeRuns: [MachineLaunchRun] { runs.filter(\.isActive) }

    // MARK: Editing

    func add() {
        launchers.append(MachineLauncher(name: "New launcher", command: "", machinePattern: ""))
    }
    func addBabelPreset() { launchers.append(.babelPreset()) }
    var hasBabelPreset: Bool { launchers.contains { $0.command.contains("slurm-node\" babel") } }
    func delete(_ l: MachineLauncher) { launchers.removeAll { $0.id == l.id } }

    // MARK: Requests

    func request(_ launcher: MachineLauncher) {
        let command = launcher.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        if let active = runs.first(where: { $0.launcher.id == launcher.id && $0.isActive }) {
            _ = active   // one outstanding request per launcher; its status is already shown
            return
        }
        let before = Set(state?.machines.map(\.id) ?? [])
        let run = MachineLaunchRun(launcher: launcher, startedAt: Date(), machinesBefore: before)
        runs.insert(run, at: 0)
        if runs.count > 8 { runs.removeLast(runs.count - 8) }
        ActivityJournal.shared.log("machineLaunch", ["launcher": launcher.name])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        if let dir = launcherDirectory { environment["ARGUS_LAUNCHERS"] = dir.path }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let runID = run.id
        let buffer = OutputLineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let complete = buffer.append(data)
            guard !complete.isEmpty else { return }
            Task { @MainActor [weak self] in self?.received(complete, for: runID) }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let tail = buffer.finish(pipe.fileHandleForReading.readDataToEndOfFile())
            let status = p.terminationStatus
            let reason = p.terminationReason
            Task { @MainActor [weak self] in
                self?.received(tail, for: runID)
                self?.commandExited(runID, status: status, reason: reason)
            }
        }
        do {
            try process.run()
            processes[runID] = process
        } catch {
            update(runID) { $0.phase = .failed("Could not start the command: \(error.localizedDescription)") }
        }
    }

    /// Stop the local command (and stop waiting). What the command already
    /// provisioned keeps running; a machine that appears later still shows up.
    func stop(_ run: MachineLaunchRun) {
        processes[run.id]?.terminate()
        update(run.id) { if $0.isActive { $0.phase = .stopped } }
    }

    func dismiss(_ run: MachineLaunchRun) {
        guard !run.isActive else { return }
        runs.removeAll { $0.id == run.id }
    }

    // MARK: Progress

    private func received(_ lines: [String], for id: UUID) {
        guard !lines.isEmpty else { return }
        update(id) { run in
            for line in lines {
                if let name = MachineLaunchMatching.announcedMachine(in: line) {
                    run.announcedMachine = name
                } else {
                    run.lastLine = line
                }
            }
        }
        if let machines = state?.machines { machinesChanged(machines) }
    }

    private func commandExited(_ id: UUID, status: Int32, reason: Process.TerminationReason) {
        processes[id] = nil
        guard let run = runs.first(where: { $0.id == id }), run.phase == .running else { return }
        if reason == .exit && status == 0 {
            let canWatch = run.announcedMachine != nil
                || !run.launcher.machinePattern.trimmingCharacters(in: .whitespaces).isEmpty
            update(id) {
                $0.commandFinishedAt = Date()
                $0.phase = canWatch ? .waitingForMachine
                    : .failed("The command finished but named no machine. Set a machine pattern or print ARGUS_MACHINE=<name>.")
            }
            discover()
            if let machines = state?.machines { machinesChanged(machines) }
            scheduleDiscovery()
        } else {
            let detail = run.lastLine.isEmpty ? "exit status \(status)" : run.lastLine
            update(id) { $0.phase = .failed(detail) }
            notify(title: "\(run.launcher.name) failed", body: detail, id: id)
        }
    }

    private func machinesChanged(_ machines: [Machine]) {
        for run in runs where run.phase == .waitingForMachine || run.phase == .running {
            guard let m = MachineLaunchMatching.resolve(
                announced: run.announcedMachine, pattern: run.launcher.machinePattern,
                before: run.machinesBefore, machines: machines) else { continue }
            // A machine can be listed before its broker answers; the picker only
            // offers it once it is reachable, so wait for the same.
            guard state?.statusByMachine[m.id]?.permitsInteraction ?? false else { continue }
            update(run.id) { $0.phase = .ready(machineID: m.id, machineName: m.name) }
            lastReady = (run.id, m.id)
            notify(title: "\(m.name) is ready", body: "From \(run.launcher.name). It is now in the machine list.", id: run.id)
        }
        if runs.allSatisfy({ $0.phase != .waitingForMachine }) { discoveryTimer?.invalidate(); discoveryTimer = nil }
    }

    /// Discovery normally picks up new brokers every ~12s; while a request is
    /// waiting, also refresh the reachability of candidates and enforce the limit.
    private func scheduleDiscovery() {
        guard discoveryTimer == nil else { return }
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.discover()
                let now = Date()
                for run in self.runs where run.phase == .waitingForMachine {
                    if let done = run.commandFinishedAt, now.timeIntervalSince(done) > Self.machineWaitLimit {
                        self.update(run.id) { $0.phase = .failed("No matching machine appeared within 10 minutes.") }
                    }
                }
                if let machines = self.state?.machines { self.machinesChanged(machines) }
            }
        }
    }

    private func update(_ id: UUID, _ body: (inout MachineLaunchRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        body(&runs[i])
    }

    private func notify(title: String, body: String, id: UUID) {
        guard NotifyPrefs.enabled, !AppState.isRunningTests else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ut.machineLaunch." + id.uuidString, content: c, trigger: nil))
    }

    // MARK: Persistence (this Mac only: the commands run here)

    private static func load() -> [MachineLauncher] {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey),
              let l = try? JSONDecoder().decode([MachineLauncher].self, from: d) else { return [] }
        return l
    }
    private static func save(_ l: [MachineLauncher]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }
}

/// Splits streamed command output into complete, non-empty lines. The pipe's
/// readability and termination handlers run on different queues, so the partial
/// line they share is guarded.
final class OutputLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        // Carriage returns redraw a status line in place; treat them as breaks.
        pending += (String(data: data, encoding: .utf8) ?? "").replacingOccurrences(of: "\r", with: "\n")
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        return Self.clean(lines)
    }

    func finish(_ data: Data) -> [String] {
        var lines = append(data)
        lock.lock(); defer { lock.unlock() }
        lines += Self.clean([pending])
        pending = ""
        return lines
    }

    private static func clean(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

func openArgusSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

// MARK: Views

/// Status of outstanding and recent requests, shown under a machine picker.
struct MachineLaunchRunsView: View {
    @ObservedObject var store: MachineLauncherStore

    var body: some View {
        if !store.runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.runs) { run in row(run) }
            }
        }
    }

    @ViewBuilder private func row(_ run: MachineLaunchRun) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch run.phase {
            case .running, .waitingForMachine:
                ProgressView().controlSize(.small)
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.running)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.waiting)
            case .stopped:
                Image(systemName: "stop.circle").foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(run.launcher.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(detail(run)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if run.isActive {
                Button("Stop") { store.stop(run) }.controlSize(.small)
                    .help("Stop the local command. Anything it already requested keeps running.")
            } else {
                Button { store.dismiss(run) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
    }

    private func detail(_ run: MachineLaunchRun) -> String {
        switch run.phase {
        case .running: return run.lastLine.isEmpty ? "Starting…" : run.lastLine
        case .waitingForMachine:
            return "Waiting for \(run.announcedMachine ?? "the machine") to join Argus…"
        case .ready(_, let name): return "\(name) is ready and in the machine list."
        case .failed(let why): return why
        case .stopped: return "Stopped. A machine it already requested still appears when it starts."
        }
    }
}

/// Settings editor for launchers.
struct MachineLaunchersSettingsSection: View {
    @ObservedObject var store: MachineLauncherStore

    var body: some View {
        Section {
            ForEach($store.launchers) { $l in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Name", text: $l.name)
                        Button(role: .destructive) { store.delete(l) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    TextField("Command (runs on this Mac)", text: $l.command)
                        .font(.system(.body, design: .monospaced))
                    TextField("Machine pattern (optional), e.g. babel-*", text: $l.machinePattern)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.vertical, 2)
            }
            HStack {
                Button("Add launcher") { store.add() }
                if !store.hasBabelPreset {
                    Button("Add Babel preset") { store.addBabelPreset() }
                        .help("CMU Babel: a 3-day, 1-GPU russ-lab job. Edit the command for another partition or size.")
                }
            }
        } header: {
            Text("Machine launchers")
        } footer: {
            Text("A launcher requests a machine that does not exist yet, e.g. a cluster job or a cloud VM that runs `ut`. Its command runs on this Mac in a login shell. When the new machine's broker joins your tailnet it appears in every machine list. Print `ARGUS_MACHINE=<name>` to name the machine, or set a pattern and Argus takes the first new match. `$ARGUS_LAUNCHERS/slurm-node <ssh-host> [sbatch options]` puts a Slurm compute node into Argus (needs `ut` on the cluster). Request one from the machine menu of the New session sheet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
