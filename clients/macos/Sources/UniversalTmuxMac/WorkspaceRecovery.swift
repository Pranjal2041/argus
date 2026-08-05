import Foundation
import SwiftUI

struct WorkspaceRecoverySnapshot: Decodable {
    let id: String
    let host: String
    let socket: String
    let capturedAt: String
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
    let selected: Bool

    var id: String { name }
    var isReady: Bool { state == "ready" }
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

    private weak var appState: AppState?
    private var checkGeneration = 0
    private let socket = ProcessInfo.processInfo.environment["UT_TMUX_SOCKET"] ?? "ut"
    private static let offeredSnapshotKey = "ut.recovery.lastOfferedSnapshot.v1"

    var readyPanels: [WorkspaceRecoveryPanel] { status?.panels.filter(\.isReady) ?? [] }
    var selectedCount: Int { selected.intersection(Set(readyPanels.map(\.name))).count }
    var hasOffer: Bool { status?.available == true && !readyPanels.isEmpty }

    func bind(_ state: AppState) { appState = state }

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
        checkForRecovery()
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
        Self.runTool(arguments, timeout: 180) { [weak self] output in
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
                self.errorMessage = "The panels were restored, but the broker could not restart: (bootstrap)"
            }
            // The supervisor needs a moment to bind :8722 before the normal
            // discovery pass. A second pass covers slower launchd/tmux startup.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.appState?.refreshAll() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { self.appState?.refreshAll() }
        }
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

    private var panelList: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(panels) { panel in
                    WorkspaceRecoveryRow(
                        panel: panel,
                        isSelected: recovery.selected.contains(panel.name),
                        result: recovery.results[panel.name],
                        isRestoring: recovery.phase == .restoring,
                        scale: uiScale,
                        action: { recovery.toggle(panel.name) }
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
            Text("Checking the previous tmux workspace…")
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
    let scale: Double
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
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
                }
                Spacer(minLength: 10 * scale)
                stateLabel
            }
            .padding(.horizontal, 13 * scale)
            .padding(.vertical, 10 * scale)
            .background(hovering && panel.isReady ? Theme.selection.opacity(0.48) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!panel.isReady || isRestoring || result != nil)
        .onHover { hovering = $0 }
        .help(panel.detail ?? "")
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
        } else if isRestoring && isSelected {
            HStack(spacing: 6 * scale) {
                ProgressView().controlSize(.mini)
                Text("Starting")
            }
            .foregroundStyle(Theme.accent)
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
        default: return "Review needed"
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
