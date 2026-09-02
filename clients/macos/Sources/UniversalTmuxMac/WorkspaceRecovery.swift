import AppKit
import Combine
import Foundation
import SwiftUI

struct WorkspaceRecoverySnapshot: Decodable {
    let id: String
    let host: String
    let socket: String
    let capturedAt: String
}

struct WorkspaceRecoveryCandidate: Decodable, Identifiable, Equatable {
    let id: String
    let host: String
    let capturedAt: String
    let panelCount: Int
    let readyCount: Int
}

struct WorkspaceRecoverySource: Identifiable, Equatable {
    let candidate: WorkspaceRecoveryCandidate
    let originTargetID: String

    var id: String { candidate.id }
}

struct WorkspaceRecoveryTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let route: String?

    var isLocal: Bool { route == nil }
}

struct WorkspaceRecoveryPanel: Decodable, Identifiable {
    let name: String
    let directory: String
    let agent: String
    let sessionId: String?
    let argv: [String]?
    let state: String
    let detail: String?
    let restoreCommand: String?
    let capturedLaunchReviewable: Bool?
    let selected: Bool

    var id: String { name }
    var isReady: Bool { state == "ready" }
    var requiresReview: Bool { state == "unsupported" }
    var canUseCapturedLaunch: Bool { requiresReview && capturedLaunchReviewable == true }
    var permissionLabel: String? {
        let args = argv ?? []
        if args.contains("--yolo") || args.contains("--dangerously-bypass-approvals-and-sandbox") {
            return "YOLO"
        }
        if args.contains("--dangerously-skip-permissions") { return "BYPASS" }
        if let index = args.firstIndex(of: "--permission-mode"), args.indices.contains(index + 1) {
            return args[index + 1].uppercased()
        }
        return nil
    }
}

struct WorkspaceRecoveryStatus: Decodable {
    let available: Bool
    let snapshot: WorkspaceRecoverySnapshot?
    let currentServerId: String?
    let candidates: [WorkspaceRecoveryCandidate]?
    let targetHost: String?
    let readyCount: Int
    let panels: [WorkspaceRecoveryPanel]
    let error: String?
}

struct WorkspaceRestoreResult: Decodable, Identifiable {
    let name: String
    let state: String
    let detail: String?
    let sessionId: String?
    var id: String { name }
}

struct WorkspaceRestoreResponse: Decodable {
    let snapshotId: String
    let results: [WorkspaceRestoreResult]
    let bootstrap: String?
}

private struct RecoveryToolOutput {
    let data: Data
    let stderr: String
    let exitCode: Int32
}

@MainActor
final class WorkspaceRecoveryController: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, restoring, finished
    }

    @Published var status: WorkspaceRecoveryStatus?
    @Published var selected: Set<String> = []
    @Published var results: [String: WorkspaceRestoreResult] = [:]
    @Published var phase: Phase = .idle
    @Published var showSheet = false
    @Published var errorMessage: String?
    @Published var targets: [WorkspaceRecoveryTarget] = [
        WorkspaceRecoveryTarget(id: "local", name: "this mac", host: "this mac", route: nil)
    ]
    @Published var selectedTargetID = "local"
    @Published var selectedSourceID = ""
    @Published var targetIssues: [String: String] = [:]
    @Published var reviewedRestoreName: String?
    @Published private(set) var sources: [WorkspaceRecoverySource] = []

    private weak var appState: AppState?
    private var machineObservation: AnyCancellable?
    private var checkGeneration = 0
    private var statusByTarget: [String: WorkspaceRecoveryStatus] = [:]
    private let socket = ProcessInfo.processInfo.environment["UT_TMUX_SOCKET"] ?? "ut"
    private static let offeredSnapshotKey = "ut.recovery.lastOfferedSnapshot.v1"

    var readyPanels: [WorkspaceRecoveryPanel] { status?.panels.filter(\.isReady) ?? [] }
    var selectedCount: Int { selected.intersection(Set(readyPanels.map(\.name))).count }
    var hasOffer: Bool { status?.available == true && !readyPanels.isEmpty }
    var selectedTarget: WorkspaceRecoveryTarget {
        targets.first(where: { $0.id == selectedTargetID }) ?? Self.localTarget
    }
    var sourceCandidates: [WorkspaceRecoveryCandidate] {
        if !sources.isEmpty { return sources.map(\.candidate) }
        if let candidates = status?.candidates, !candidates.isEmpty { return candidates }
        guard let snapshot = status?.snapshot else { return [] }
        return [WorkspaceRecoveryCandidate(
            id: snapshot.id, host: snapshot.host, capturedAt: snapshot.capturedAt,
            panelCount: status?.panels.count ?? 0, readyCount: status?.readyCount ?? 0
        )]
    }

    private static let localTarget = WorkspaceRecoveryTarget(
        id: "local", name: "this mac", host: "this mac", route: nil
    )

    func bind(_ state: AppState) {
        appState = state
        machineObservation = state.$machines
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.showSheet, self.phase != .restoring else { return }
                self.scanTargets()
            }
    }

    func checkForRecovery(offerAutomatically: Bool = false) {
        checkGeneration &+= 1
        let generation = checkGeneration
        phase = .checking
        errorMessage = nil
        Self.runTool(["recovery", "status", "--tmux-socket", socket]) { [weak self] output in
            guard let self, generation == self.checkGeneration else { return }
            guard let decoded = try? JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: output.data) else {
                self.phase = .idle
                // An older installed broker simply has no recovery command yet.
                // Keep startup quiet; manual opening will surface the diagnostic.
                if self.showSheet {
                    self.errorMessage = output.stderr.isEmpty
                        ? "The installed local broker does not support workspace recovery yet."
                        : output.stderr
                }
                return
            }
            self.status = decoded
            self.statusByTarget[Self.localTarget.id] = decoded
            self.sources = Self.recoverySources(
                statusByTarget: self.statusByTarget,
                targets: [Self.localTarget]
            )
            self.selectedTargetID = Self.localTarget.id
            self.selectedSourceID = decoded.snapshot?.id ?? ""
            self.selected = Set(decoded.panels.filter(\.isReady).map(\.name))
            self.results = [:]
            self.phase = .idle
            self.errorMessage = decoded.error
            guard offerAutomatically, decoded.available, let snapshot = decoded.snapshot else { return }
            let defaults = UserDefaults.standard
            if defaults.string(forKey: Self.offeredSnapshotKey) != snapshot.id {
                defaults.set(snapshot.id, forKey: Self.offeredSnapshotKey)
                self.showSheet = true
            }
        }
    }

    func open() {
        showSheet = true
        // The recovery sheet must not inherit a stale discovery snapshot. A
        // scheduler allocation may have just rejoined Tailscale under a new
        // device identity even though its logical Babel hostname is unchanged.
        appState?.refreshAll()
        scanTargets()
    }

    func refresh() {
        guard phase != .restoring else { return }
        appState?.refreshAll()
        scanTargets()
    }

    func selectTarget(_ id: String) {
        guard id != selectedTargetID,
              targetIssues[id] == nil,
              targets.contains(where: { $0.id == id }) else { return }
        selectedTargetID = id
        prepareSelectedSource()
    }

    func selectSource(_ id: String) {
        guard id != selectedSourceID, sourceCandidates.contains(where: { $0.id == id }) else { return }
        selectedSourceID = id
        prepareSelectedSource()
    }

    func toggle(_ name: String) {
        guard readyPanels.contains(where: { $0.name == name }) else { return }
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
    }

    func selectAll() { selected = Set(readyPanels.map(\.name)) }
    func selectNone() { selected.removeAll() }

    func restoreSelected() {
        guard phase != .restoring,
              let snapshot = status?.snapshot,
              selectedCount > 0 else { return }
        phase = .restoring
        reviewedRestoreName = nil
        errorMessage = nil
        results = [:]
        var arguments = [
            "recovery", "restore",
            "--tmux-socket", socket,
            "--snapshot", snapshot.id,
            "--parallel", "3",
        ]
        for name in selected.sorted() {
            arguments += ["--session", name]
        }
        if !selectedTarget.isLocal { arguments += ["--bootstrap=false"] }
        runRecovery(arguments, on: selectedTarget, timeout: 180) { [weak self] output in
            guard let self else { return }
            guard let decoded = try? JSONDecoder().decode(WorkspaceRestoreResponse.self, from: output.data) else {
                self.phase = .finished
                self.errorMessage = output.stderr.isEmpty
                    ? "The restore process ended without a readable result."
                    : output.stderr
                return
            }
            self.results = Dictionary(uniqueKeysWithValues: decoded.results.map { ($0.name, $0) })
            self.phase = .finished
            let failures = decoded.results.filter { $0.state == "failed" }
            if !failures.isEmpty {
                self.errorMessage = "\(failures.count) panel\(failures.count == 1 ? "" : "s") could not be restored. Nothing was overwritten."
            } else if let bootstrap = decoded.bootstrap, bootstrap != "started" {
                self.errorMessage = "The panels were restored, but the broker could not restart: \(bootstrap)"
            }
            // The supervisor needs a moment to bind :8722 before the normal
            // discovery pass. A second pass covers slower launchd/tmux startup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.appState?.refreshAll() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.appState?.refreshAll() }
        }
    }

    func restoreCapturedLaunch(_ panel: WorkspaceRecoveryPanel) {
        guard phase != .restoring,
              panel.canUseCapturedLaunch,
              let snapshot = status?.snapshot else { return }
        phase = .restoring
        reviewedRestoreName = panel.name
        errorMessage = nil
        results.removeValue(forKey: panel.name)
        var arguments = [
            "recovery", "restore",
            "--tmux-socket", socket,
            "--snapshot", snapshot.id,
            "--parallel", "1",
            "--use-captured-launch",
            "--session", panel.name,
        ]
        if !selectedTarget.isLocal { arguments += ["--bootstrap=false"] }
        runRecovery(arguments, on: selectedTarget, timeout: 180) { [weak self] output in
            guard let self else { return }
            self.reviewedRestoreName = nil
            guard let decoded = try? JSONDecoder().decode(WorkspaceRestoreResponse.self, from: output.data) else {
                self.phase = .finished
                self.errorMessage = output.stderr.isEmpty
                    ? "The captured launch ended without a readable result."
                    : output.stderr
                return
            }
            for result in decoded.results { self.results[result.name] = result }
            self.phase = .finished
            if let failure = decoded.results.first(where: { $0.state == "failed" }) {
                self.errorMessage = failure.detail ?? "The captured launch could not be restored."
            } else if let bootstrap = decoded.bootstrap, bootstrap != "started" {
                self.errorMessage = "The panel was restored, but the broker could not restart: \(bootstrap)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.appState?.refreshAll() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.appState?.refreshAll() }
        }
    }

    private func scanTargets() {
        checkGeneration &+= 1
        let generation = checkGeneration
        targets = Self.recoveryTargets(from: appState?.machines ?? [])
        phase = .checking
        status = nil
        selected = []
        errorMessage = nil
        statusByTarget = [:]
        sources = []
        targetIssues = [:]

        let group = DispatchGroup()
        var discovered: [String: WorkspaceRecoveryStatus] = [:]
        var issues: [String: String] = [:]
        for target in targets {
            group.enter()
            runRecovery(["recovery", "status", "--tmux-socket", socket], on: target) { output in
                if let decoded = try? JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: output.data) {
                    discovered[target.id] = decoded
                } else {
                    issues[target.id] = Self.recoveryCapabilityIssue(output)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, generation == self.checkGeneration else { return }
            self.statusByTarget = discovered
            self.targetIssues = issues
            self.sources = Self.recoverySources(statusByTarget: discovered, targets: self.targets)
            let supported = self.targets.filter { issues[$0.id] == nil }
            let chosen = supported.first(where: { discovered[$0.id]?.available == true })
                ?? supported.first(where: { discovered[$0.id]?.snapshot != nil })
                ?? supported.first
                ?? Self.localTarget
            self.selectedTargetID = chosen.id
            if let status = discovered[chosen.id] {
                let sourceID = status.snapshot?.id ?? self.sources.first?.id ?? ""
                self.selectedSourceID = sourceID
                if sourceID.isEmpty || status.snapshot?.id == sourceID {
                    self.apply(status, sourceID: sourceID)
                } else {
                    self.prepareSelectedSource()
                }
            } else {
                self.status = nil
                self.selected = []
                self.phase = .idle
                self.errorMessage = chosen.isLocal
                    ? "The local recovery service is unavailable."
                    : "\(chosen.name) did not return workspace recovery status."
            }
        }
    }

    private func prepareSelectedSource() {
        checkGeneration &+= 1
        let generation = checkGeneration
        phase = .checking
        errorMessage = nil
        let target = selectedTarget
        let snapshotID = selectedSourceID
        guard !snapshotID.isEmpty else {
            if let cached = statusByTarget[target.id] {
                apply(cached)
            } else {
                querySelectedTarget(snapshot: nil, target: target, generation: generation)
            }
            return
        }
        if Self.status(statusByTarget[target.id], canRead: snapshotID) {
            querySelectedTarget(snapshot: snapshotID, target: target, generation: generation)
            return
        }
        guard let source = sources.first(where: { $0.id == snapshotID }),
              let origin = targets.first(where: { $0.id == source.originTargetID }) else {
            phase = .idle
            errorMessage = "The selected recovery source is no longer reachable. Refresh and try again."
            return
        }
        let arguments = [
            "recovery", "transfer",
            "--source", origin.route ?? ".",
            "--target", target.route ?? ".",
            "--snapshot", snapshotID,
            "--tmux-socket", socket,
        ]
        Self.runTool(arguments, timeout: 60) { [weak self] output in
            guard let self, generation == self.checkGeneration else { return }
            guard output.exitCode == 0 else {
                self.phase = .idle
                self.errorMessage = output.stderr.isEmpty
                    ? "The recovery snapshot could not be transferred to \(target.name)."
                    : output.stderr
                return
            }
            self.querySelectedTarget(snapshot: snapshotID, target: target, generation: generation)
        }
    }

    private func querySelectedTarget(
        snapshot: String?,
        target: WorkspaceRecoveryTarget,
        generation: Int
    ) {
        var arguments = ["recovery", "status", "--tmux-socket", socket]
        if let snapshot, !snapshot.isEmpty { arguments += ["--snapshot", snapshot] }
        runRecovery(arguments, on: target) { [weak self] output in
            guard let self, generation == self.checkGeneration else { return }
            guard let decoded = try? JSONDecoder().decode(WorkspaceRecoveryStatus.self, from: output.data) else {
                self.phase = .idle
                self.errorMessage = output.stderr.isEmpty
                    ? "\(target.name) did not return readable workspace recovery status."
                    : output.stderr
                return
            }
            self.statusByTarget[target.id] = decoded
            self.apply(decoded, sourceID: snapshot)
        }
    }

    private func apply(_ decoded: WorkspaceRecoveryStatus, sourceID: String? = nil) {
        status = decoded
        selectedSourceID = sourceID ?? decoded.snapshot?.id ?? ""
        selected = Set(decoded.panels.filter(\.isReady).map(\.name))
        results = [:]
        reviewedRestoreName = nil
        phase = .idle
        errorMessage = decoded.error
    }

    /// The Tailscale device ID is transport identity, not machine identity. A
    /// restarted broker can acquire a suffixed route while /whoami still reports
    /// its stable OS hostname. Keep one destination per logical host and prefer
    /// the newest discovery entry. Recovery support is established by probing
    /// the command, never by matching a cluster or hostname.
    static func recoveryTargets(from machines: [Machine]) -> [WorkspaceRecoveryTarget] {
        var remoteByHost: [String: WorkspaceRecoveryTarget] = [:]
        for machine in machines where !machine.isLocal {
            let host = machine.host.isEmpty ? machine.name : machine.host
            var key = host.lowercased()
            if let dot = key.firstIndex(of: ".") { key = String(key[..<dot]) }
            if key.hasPrefix("ut-") { key.removeFirst(3) }
            remoteByHost[key] = WorkspaceRecoveryTarget(
                id: machine.id,
                name: machine.name,
                host: host,
                route: machine.id
            )
        }
        let remotes = remoteByHost.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return [localTarget] + remotes
    }

    /// Recovery source discovery is a fabric-wide operation. Each successful
    /// target probe contributes every manifest it can actually export; duplicate
    /// manifests from shared stores collapse to one source while retaining a
    /// concrete origin route for transport.
    static func recoverySources(
        statusByTarget: [String: WorkspaceRecoveryStatus],
        targets: [WorkspaceRecoveryTarget]
    ) -> [WorkspaceRecoverySource] {
        struct Choice {
            let source: WorkspaceRecoverySource
            let ownsSnapshot: Bool
            let targetOrder: Int
        }
        var byID: [String: Choice] = [:]
        for (targetOrder, target) in targets.enumerated() {
            guard let status = statusByTarget[target.id] else { continue }
            var candidates = status.candidates ?? []
            if candidates.isEmpty, let snapshot = status.snapshot {
                candidates = [WorkspaceRecoveryCandidate(
                    id: snapshot.id,
                    host: snapshot.host,
                    capturedAt: snapshot.capturedAt,
                    panelCount: status.panels.count,
                    readyCount: status.readyCount
                )]
            }
            let originHost = status.targetHost ?? target.host
            for candidate in candidates where !candidate.id.isEmpty {
                let choice = Choice(
                    source: WorkspaceRecoverySource(candidate: candidate, originTargetID: target.id),
                    ownsSnapshot: canonicalRecoveryHost(originHost) == canonicalRecoveryHost(candidate.host),
                    targetOrder: targetOrder
                )
                if let existing = byID[candidate.id] {
                    if (choice.ownsSnapshot && !existing.ownsSnapshot)
                        || (choice.ownsSnapshot == existing.ownsSnapshot
                            && choice.targetOrder < existing.targetOrder) {
                        byID[candidate.id] = choice
                    }
                } else {
                    byID[candidate.id] = choice
                }
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        func date(_ value: String) -> Date {
            formatter.date(from: value) ?? fallbackFormatter.date(from: value) ?? .distantPast
        }
        return byID.values.map(\.source).sorted {
            let lhsDate = date($0.candidate.capturedAt)
            let rhsDate = date($1.candidate.capturedAt)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.candidate.host.localizedStandardCompare($1.candidate.host) == .orderedAscending
        }
    }

    private static func canonicalRecoveryHost(_ value: String) -> String {
        var key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let dot = key.firstIndex(of: ".") { key = String(key[..<dot]) }
        if key.hasPrefix("ut-") { key.removeFirst(3) }
        return key
    }

    private static func status(_ status: WorkspaceRecoveryStatus?, canRead snapshotID: String) -> Bool {
        guard let status else { return false }
        return status.snapshot?.id == snapshotID
            || (status.candidates ?? []).contains(where: { $0.id == snapshotID })
    }

    private static func recoveryCapabilityIssue(_ output: RecoveryToolOutput) -> String {
        let firstLine = output.stderr.split(whereSeparator: \.isNewline).first
            .map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine, !firstLine.isEmpty {
            return firstLine
        }
        return output.exitCode == 124
            ? "Recovery probe timed out."
            : "This broker does not support workspace recovery."
    }

    private func runRecovery(
        _ arguments: [String],
        on target: WorkspaceRecoveryTarget,
        timeout: TimeInterval = 20,
        completion: @escaping @MainActor (RecoveryToolOutput) -> Void
    ) {
        guard let route = target.route else {
            Self.runTool(arguments, timeout: timeout, completion: completion)
            return
        }
        Self.runTool(
            Self.remoteRecoveryArguments(arguments, target: route),
            timeout: timeout,
            completion: completion
        )
    }

    /// Remote recovery is a broker protocol operation, not a remote shell
    /// command. This avoids assuming POSIX paths or quoting on Windows and keeps
    /// the operation beside the backend instance that owns the live sessions.
    static func remoteRecoveryArguments(_ arguments: [String], target: String) -> [String] {
        let operation = arguments.first == "recovery" ? Array(arguments.dropFirst()) : arguments
        return ["recovery", "remote", "--target", target] + operation
    }

    // Display-only rendering for the explicit captured-launch review. Remote
    // execution never parses this string; it transports structured arguments.
    static func shellQuote(_ value: String) -> String {
        if !value.isEmpty && value.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.alphanumerics.contains(scalar) || "_@%+=:,./-".unicodeScalars.contains(scalar)
        }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func close() {
        showSheet = false
        if phase == .finished {
            checkForRecovery()
        }
    }

    private static func brokerExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            environment["UT_BROKER"].map(URL.init(fileURLWithPath:)),
            home.appendingPathComponent(".universal-tmux/ut-broker"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ut-broker"),
            URL(fileURLWithPath: "/usr/local/bin/ut-broker"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runTool(
        _ arguments: [String],
        timeout: TimeInterval = 20,
        completion: @escaping @MainActor (RecoveryToolOutput) -> Void
    ) {
        guard let executable = brokerExecutable() else {
            Task { @MainActor in
                completion(RecoveryToolOutput(
                    data: Data(),
                    stderr: "The local ut-broker executable was not found.",
                    exitCode: 127
                ))
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ut-recovery-\(UUID().uuidString)", isDirectory: true)
            let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.json")
            let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
            do {
                try FileManager.default.createDirectory(
                    at: temporaryDirectory,
                    withIntermediateDirectories: true
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: temporaryDirectory.path
                )
                _ = FileManager.default.createFile(
                    atPath: stdoutURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
                _ = FileManager.default.createFile(
                    atPath: stderrURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            } catch {
                Task { @MainActor in
                    completion(RecoveryToolOutput(data: Data(), stderr: error.localizedDescription, exitCode: 125))
                }
                return
            }
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            process.executableURL = executable
            process.arguments = arguments
            guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
                  let stderr = try? FileHandle(forWritingTo: stderrURL) else {
                Task { @MainActor in
                    completion(RecoveryToolOutput(
                        data: Data(),
                        stderr: "Could not create workspace-recovery output files.",
                        exitCode: 125
                    ))
                }
                return
            }
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                try? stdout.close()
                try? stderr.close()
                Task { @MainActor in
                    completion(RecoveryToolOutput(data: Data(), stderr: error.localizedDescription, exitCode: 126))
                }
                return
            }
            let timer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
            process.waitUntilExit()
            timer.cancel()
            try? stdout.close()
            try? stderr.close()
            // Files avoid the classic Process/Pipe deadlock when a large
            // workspace manifest fills a pipe while the parent is waiting.
            let outputData = (try? Data(contentsOf: stdoutURL)) ?? Data()
            let errorData = (try? Data(contentsOf: stderrURL)) ?? Data()
            let output = RecoveryToolOutput(
                data: outputData,
                stderr: String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                exitCode: process.terminationStatus
            )
            Task { @MainActor in completion(output) }
        }
    }
}

struct WorkspaceRecoveryView: View {
    @ObservedObject var recovery: WorkspaceRecoveryController
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @State private var panelUnderReview: WorkspaceRecoveryPanel?

    private var snapshot: WorkspaceRecoverySnapshot? { recovery.status?.snapshot }
    private var panels: [WorkspaceRecoveryPanel] { recovery.status?.panels ?? [] }
    private var agentCounts: [(String, Int)] {
        ["claude", "codex", "shell"].compactMap { agent in
            let count = recovery.readyPanels.filter { $0.agent == agent }.count
            return count == 0 ? nil : (agent, count)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if recovery.phase == .checking && recovery.status == nil {
                checking
            } else if let status = recovery.status, status.snapshot != nil {
                summary(status)
                panelList
                footer
            } else {
                emptyState
            }
        }
        .frame(width: 720 * uiScale, height: 620 * uiScale)
        .background(Theme.appBackground)
        .sheet(item: $panelUnderReview) { panel in
            WorkspaceRecoveryReviewView(
                panel: panel,
                scale: uiScale,
                launchCapturedAction: { recovery.restoreCapturedLaunch(panel) }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12 * uiScale) {
            ZStack {
                RoundedRectangle(cornerRadius: 9 * uiScale, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 36 * uiScale, height: 36 * uiScale)
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text("RESTORE WORKSPACE")
                    .font(.system(size: 11 * uiScale, weight: .semibold, design: .monospaced))
                    .tracking(1.25 * uiScale)
                    .foregroundStyle(Theme.textTertiary)
                Text("Pick up where you left off")
                    .font(.system(size: 20 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button(action: recovery.refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30 * uiScale, height: 30 * uiScale)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .disabled(recovery.phase == .restoring)
            .help("Refresh recovery machines and snapshots")
            Button(action: recovery.close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30 * uiScale, height: 30 * uiScale)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 17 * uiScale)
    }

    private func summary(_ status: WorkspaceRecoveryStatus) -> some View {
        VStack(spacing: 13 * uiScale) {
            HStack(spacing: 10 * uiScale) {
                recoveryMenu(
                    title: "FROM",
                    value: sourceName,
                    systemImage: "shippingbox",
                    enabled: recovery.sourceCandidates.count > 1
                ) {
                    ForEach(recovery.sourceCandidates) { candidate in
                        Button {
                            recovery.selectSource(candidate.id)
                        } label: {
                            Label(
                                "\(candidate.host) · \(candidate.panelCount) panel\(candidate.panelCount == 1 ? "" : "s")",
                                systemImage: candidate.id == recovery.selectedSourceID ? "checkmark" : "circle"
                            )
                        }
                    }
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                recoveryMenu(
                    title: "RESTORE TO",
                    value: recovery.selectedTarget.name,
                    systemImage: "desktopcomputer",
                    enabled: recovery.targets.count > 1
                ) {
                    ForEach(recovery.targets) { target in
                        Button {
                            recovery.selectTarget(target.id)
                        } label: {
                            let issue = recovery.targetIssues[target.id]
                            Label(
                                issue == nil ? target.name : "\(target.name) — unavailable",
                                systemImage: target.id == recovery.selectedTargetID ? "checkmark" : "circle"
                            )
                        }
                        .disabled(recovery.targetIssues[target.id] != nil)
                        .help(recovery.targetIssues[target.id] ?? "Restore this machine's captured workspace")
                    }
                }
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
                Text("\(status.readyCount) panel\(status.readyCount == 1 ? "" : "s") ready")
                    .font(.system(size: 14 * uiScale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let snapshot {
                    Text("·") .foregroundStyle(Theme.textTertiary)
                    Text(capturedLabel(snapshot.capturedAt))
                        .font(.system(size: 12 * uiScale))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                ForEach(agentCounts, id: \.0) { item in
                    HStack(spacing: 5 * uiScale) {
                        Circle().fill(agentColor(item.0)).frame(width: 6 * uiScale, height: 6 * uiScale)
                        Text("\(item.1) \(agentTitle(item.0))")
                            .font(.system(size: 11 * uiScale, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            HStack(spacing: 10 * uiScale) {
                Text("\(recovery.selectedCount) selected")
                    .font(.system(size: 11 * uiScale, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Select all", action: recovery.selectAll)
                Button("Select none", action: recovery.selectNone)
            }
            .buttonStyle(RecoveryTextButtonStyle(scale: uiScale))
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 16 * uiScale)
        .padding(.bottom, 12 * uiScale)
    }

    private var sourceName: String {
        recovery.sourceCandidates.first(where: { $0.id == recovery.selectedSourceID })?.host
            ?? snapshot?.host
            ?? "previous workspace"
    }

    private func recoveryMenu<Content: View>(
        title: String,
        value: String,
        systemImage: String,
        enabled: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 9 * uiScale) {
                Image(systemName: systemImage)
                    .font(.system(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1 * uiScale) {
                    Text(title)
                        .font(.system(size: 8.5 * uiScale, weight: .semibold, design: .monospaced))
                        .tracking(0.7 * uiScale)
                        .foregroundStyle(Theme.textTertiary)
                    Text(value)
                        .font(.system(size: 12.5 * uiScale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                if enabled {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8 * uiScale, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 11 * uiScale)
            .frame(height: 43 * uiScale)
            .background(
                RoundedRectangle(cornerRadius: 8 * uiScale, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8 * uiScale, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .allowsHitTesting(enabled)
    }

    private var panelList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(panels) { panel in
                    WorkspaceRecoveryRow(
                        panel: panel,
                        isSelected: recovery.selected.contains(panel.name),
                        result: recovery.results[panel.name],
                        isRestoring: recovery.phase == .restoring,
                        isReviewedRestore: recovery.reviewedRestoreName == panel.name,
                        scale: uiScale,
                        action: { recovery.toggle(panel.name) },
                        reviewAction: { panelUnderReview = panel }
                    )
                }
            }
            .padding(1)
        }
        .background(
            RoundedRectangle(cornerRadius: 10 * uiScale, style: .continuous)
                .fill(Theme.sidebarBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10 * uiScale, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 22 * uiScale)
    }

    private var footer: some View {
        VStack(spacing: 11 * uiScale) {
            if let error = recovery.errorMessage {
                HStack(spacing: 7 * uiScale) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(2)
                    Spacer()
                }
                .font(.system(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(Theme.waiting)
            }
            HStack(spacing: 12 * uiScale) {
                Text("Restores panel names, folders, conversations, and permission modes—not background processes.")
                    .font(.system(size: 10.5 * uiScale))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12 * uiScale)
                Button(recovery.phase == .finished ? "Done" : "Not now") {
                    recovery.close()
                }
                .buttonStyle(RecoverySecondaryButtonStyle(scale: uiScale))
                if recovery.phase != .finished {
                    Button(action: recovery.restoreSelected) {
                        HStack(spacing: 7 * uiScale) {
                            if recovery.phase == .restoring {
                                ProgressView().controlSize(.small).scaleEffect(0.78)
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            Text(recovery.phase == .restoring
                                 ? "Restoring…"
                                 : "Restore \(recovery.selectedCount)")
                        }
                    }
                    .buttonStyle(RecoveryPrimaryButtonStyle(
                        enabled: recovery.selectedCount > 0 && recovery.phase != .restoring,
                        scale: uiScale
                    ))
                    .disabled(recovery.selectedCount == 0 || recovery.phase == .restoring)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 15 * uiScale)
    }

    private var checking: some View {
        VStack(spacing: 12 * uiScale) {
            ProgressView().controlSize(.small)
            Text("Checking available workspace snapshots…")
                .font(.system(size: 13 * uiScale))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12 * uiScale) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30 * uiScale, weight: .light))
                .foregroundStyle(Theme.attached)
            Text("No previous workspace needs restoring")
                .font(.system(size: 16 * uiScale, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(recovery.errorMessage ?? "Your current tmux workspace is already intact.")
                .font(.system(size: 12 * uiScale))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390 * uiScale)
            Button("Done", action: recovery.close)
                .buttonStyle(RecoverySecondaryButtonStyle(scale: uiScale))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func capturedLabel(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return "previous workspace" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "captured " + relative.localizedString(for: date, relativeTo: Date())
    }

    private func agentTitle(_ agent: String) -> String {
        switch agent { case "claude": return "Claude"; case "codex": return "Codex"; default: return "Shell" }
    }

    private func agentColor(_ agent: String) -> Color {
        switch agent { case "claude": return Theme.waiting; case "codex": return Theme.running; default: return Theme.textTertiary }
    }
}

private struct WorkspaceRecoveryRow: View {
    let panel: WorkspaceRecoveryPanel
    let isSelected: Bool
    let result: WorkspaceRestoreResult?
    let isRestoring: Bool
    let isReviewedRestore: Bool
    let scale: Double
    let action: () -> Void
    let reviewAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if panel.isReady {
                Button(action: action) { rowContent }
                    .buttonStyle(.plain)
                    .disabled(isRestoring || result != nil)
            } else {
                rowContent
            }
        }
        .onHover { hovering = $0 }
        .help(panel.detail ?? "")
    }

    private var rowContent: some View {
        HStack(spacing: 12 * scale) {
            selectionMark
            Circle().fill(agentColor).frame(width: 7 * scale, height: 7 * scale)
            VStack(alignment: .leading, spacing: 4 * scale) {
                HStack(spacing: 7 * scale) {
                    Text(panel.name)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(agentTitle)
                        .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                        .tracking(0.35 * scale)
                        .foregroundStyle(agentColor)
                    if let permission = panel.permissionLabel {
                        Text(permission)
                            .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.waiting)
                            .padding(.horizontal, 5 * scale).padding(.vertical, 1.5 * scale)
                            .background(Capsule().fill(Theme.waiting.opacity(0.12)))
                    }
                }
                Text(panel.directory)
                    .font(.system(size: 10.5 * scale, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !panel.isReady, let detail = panel.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5 * scale))
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10 * scale)
            stateLabel
        }
        .padding(.horizontal, 13 * scale)
        .padding(.vertical, 10 * scale)
        .background(hovering && panel.isReady ? Theme.selection.opacity(0.48) : Color.clear)
        .contentShape(Rectangle())
    }

    private var selectionMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                .fill(isSelected && panel.isReady ? Theme.accent : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                        .stroke(panel.isReady ? Theme.accent.opacity(isSelected ? 0 : 0.55) : Theme.border, lineWidth: 1)
                )
            if isSelected && panel.isReady {
                Image(systemName: "checkmark")
                    .font(.system(size: 9 * scale, weight: .bold))
                    .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
            }
        }
        .frame(width: 17 * scale, height: 17 * scale)
    }

    @ViewBuilder private var stateLabel: some View {
        if let result {
            Label(result.state == "failed" ? "Failed" : "Restored",
                  systemImage: result.state == "failed" ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(result.state == "failed" ? Theme.unreachable : Theme.attached)
                .help(result.detail ?? "")
        } else if isRestoring && (isSelected || isReviewedRestore) {
            HStack(spacing: 6 * scale) {
                ProgressView().controlSize(.mini)
                Text("Starting")
            }
            .foregroundStyle(Theme.accent)
        } else if panel.requiresReview {
            Button("Review", action: reviewAction)
                .buttonStyle(RecoverySecondaryButtonStyle(scale: scale))
        } else {
            Text(stateTitle)
                .foregroundStyle(panel.isReady ? Theme.textSecondary : stateColor)
        }
    }

    private var stateTitle: String {
        switch panel.state {
        case "ready": return "Ready"
        case "already-running": return "Already running"
        case "conflict": return "Name conflict"
        case "missing-directory": return "Folder missing"
        case "missing-session": return "History missing"
        case "unsupported": return "Review"
        default: return "Unavailable"
        }
    }

    private var stateColor: Color {
        switch panel.state {
        case "already-running": return Theme.attached
        case "conflict", "missing-directory", "missing-session": return Theme.waiting
        default: return Theme.textTertiary
        }
    }

    private var agentTitle: String {
        switch panel.agent { case "claude": return "CLAUDE"; case "codex": return "CODEX"; default: return "SHELL" }
    }

    private var agentColor: Color {
        switch panel.agent { case "claude": return Theme.waiting; case "codex": return Theme.running; default: return Theme.textTertiary }
    }
}

struct WorkspaceRecoveryReviewView: View {
    let panel: WorkspaceRecoveryPanel
    let scale: Double
    let launchCapturedAction: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            HStack(spacing: 12 * scale) {
                Image(systemName: "exclamationmark.magnifyingglass")
                    .font(.system(size: 20 * scale, weight: .medium))
                    .foregroundStyle(Theme.waiting)
                    .frame(width: 38 * scale, height: 38 * scale)
                    .background(RoundedRectangle(cornerRadius: 9 * scale).fill(Theme.waiting.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("REVIEW RECOVERY")
                        .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                        .tracking(1.0 * scale)
                        .foregroundStyle(Theme.textTertiary)
                    Text(panel.name)
                        .font(.system(size: 19 * scale, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
            }

            reviewSection("WHY ARGUS PAUSED") {
                Text(panel.detail ?? "Argus could not prove that this saved launch can be replayed safely.")
                    .foregroundStyle(Theme.textPrimary)
            }

            reviewSection("CAPTURED STATE") {
                reviewField("Agent", panel.agent.capitalized)
                reviewField("Folder", panel.directory, monospaced: true)
                if let session = panel.sessionId, !session.isEmpty {
                    reviewField("Verified conversation", session, monospaced: true)
                }
            }

            if let argv = panel.argv, !argv.isEmpty {
                reviewSection("CAPTURED LAUNCH") {
                    let command = argv.map(WorkspaceRecoveryController.shellQuote).joined(separator: " ")
                    HStack(alignment: .top, spacing: 10 * scale) {
                        Text(command)
                            .font(.system(size: 11 * scale, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4 * scale)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy captured command")
                    }
                }
            }

            Text(panel.canUseCapturedLaunch
                 ? "Automatic reconstruction was unavailable. You can explicitly launch this exact server-stored argv in the captured folder; Argus will still refuse name conflicts and verify that the agent remains active."
                 : "Nothing was started or overwritten. Correct the saved launch command, or reopen this conversation manually using the verified session above.")
                .font(.system(size: 11 * scale))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(RecoverySecondaryButtonStyle(scale: scale))
                if panel.canUseCapturedLaunch {
                    Button {
                        launchCapturedAction()
                        dismiss()
                    } label: {
                        Label("Launch captured command", systemImage: "play.fill")
                    }
                    .buttonStyle(RecoveryPrimaryButtonStyle(enabled: true, scale: scale))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24 * scale)
        .frame(width: 560 * scale)
        .background(Theme.appBackground)
    }

    private func reviewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            Text(title)
                .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                .tracking(0.8 * scale)
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 8 * scale, content: content)
                .padding(12 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8 * scale).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8 * scale).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func reviewField(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text(label)
                .font(.system(size: 9 * scale, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: 11 * scale, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecoveryTextButtonStyle: ButtonStyle {
    let scale: Double
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11 * scale, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Theme.textPrimary : Theme.accent)
            .padding(.horizontal, 5 * scale).padding(.vertical, 3 * scale)
    }
}

private struct RecoverySecondaryButtonStyle: ButtonStyle {
    let scale: Double
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14 * scale).padding(.vertical, 8 * scale)
            .background(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct RecoveryPrimaryButtonStyle: ButtonStyle {
    let enabled: Bool
    let scale: Double
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * scale, weight: .semibold))
            .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
            .padding(.horizontal, 15 * scale).padding(.vertical, 8 * scale)
            .background(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .fill(enabled ? Theme.accent : Theme.surface)
            )
            .opacity(configuration.isPressed ? 0.8 : (enabled ? 1 : 0.55))
    }
}
