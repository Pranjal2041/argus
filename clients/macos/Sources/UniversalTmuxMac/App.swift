import AppKit
import ObjectiveC
import SwiftUI

struct UniversalTmuxApp: App {
    @StateObject private var state = AppState()
    @StateObject private var terminals = TerminalController()
    @StateObject private var files = FilesModel()   // shared so "Reveal in Files" + the window use one instance
    @StateObject private var dashboards = DashboardsModel()   // shared by the window + terminal ⌘-click
    @StateObject private var notebooks = NotebooksModel()     // open notebooks shown in the main pane
    @StateObject private var wandb = WandbController()        // single persistent-login webview for in-place W&B runs
    @StateObject private var gitPanels = GitPanels()          // read-only git viewer webviews (kept alive per session)
    @StateObject private var ledgerHost = LedgerPanelHost()    // in-app Activity Ledger webview (kept alive)
    @StateObject private var wrappedHost = WrappedPanelHost()  // Argus Wrapped deck/dashboard webview (kept alive)
    @StateObject private var commandCenter = CommandCenterModel()  // experimental: per-agent status overview
    @StateObject private var lab = LabModel()                      // Argus Lab (experiments hub)
    @StateObject private var artifacts = ArtifactStore()           // explicit panel artifact library
    @StateObject private var screenshotArtifacts = ClipboardScreenshotArtifactMonitor()
    @StateObject private var themeStore = ThemeStore()             // selected color theme (default: Argus)
    @AppStorage(ClipboardScreenshotArtifactPrefs.enabledKey)
    private var screenshotArtifactsEnabled = ClipboardScreenshotArtifactPrefs.defaultEnabled

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environmentObject(state)
                .environmentObject(terminals)
                .environmentObject(files)
                .environmentObject(dashboards)
                .environmentObject(notebooks)
                .environmentObject(wandb)
                .environmentObject(gitPanels)
                .environmentObject(ledgerHost)
                .environmentObject(commandCenter)
                .environmentObject(lab)
                .environmentObject(artifacts)
                .environmentObject(themeStore)
                .frame(minWidth: 980, minHeight: 600)
                .preferredColorScheme(themeStore.palette.isLight ? .light : .dark)
                .onAppear {
                    screenshotArtifacts.bind(
                        state: state,
                        notebooks: notebooks,
                        artifacts: artifacts,
                        enabled: screenshotArtifactsEnabled
                    )
                }
                .onChange(of: screenshotArtifactsEnabled) {
                    screenshotArtifacts.setEnabled($0)
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Argus") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { state.showNew = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { NSApplication.shared.sendAction(Selector(("copy:")), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { terminals.pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { NSApplication.shared.sendAction(Selector(("selectAll:")), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") { state.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.control, .command]) // ⌘\ collides with 1Password's global hotkey
                Button("Command Palette…") { state.showPalette = true }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Hidden Panels…") { state.showHiddenPicker = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Session History…") { state.showHistory = true; state.loadHistory() }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Button("Command Center") { state.showOverview.toggle(); if state.showOverview { state.showTodos = false; state.showNotes = false; state.showLedger = false; state.showLab = false; state.showArtifacts = false } }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Workflows…") { state.showWorkflows = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Todo Maps…") { state.showTodos.toggle(); if state.showTodos { state.showOverview = false; state.showNotes = false; state.showLedger = false; state.showLab = false; state.showArtifacts = false } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Notes Hub…") { state.showNotes.toggle(); if state.showNotes { state.showOverview = false; state.showTodos = false; state.showLedger = false; state.showLab = false; state.showArtifacts = false } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Activity Ledger…") { state.showLedger.toggle(); if state.showLedger { state.showOverview = false; state.showTodos = false; state.showNotes = false; state.showLab = false; state.showArtifacts = false } }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Lab…") { state.showLab.toggle(); if state.showLab { state.showOverview = false; state.showTodos = false; state.showNotes = false; state.showLedger = false; state.showArtifacts = false } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Artifacts…") {
                    if state.showArtifacts {
                        state.showArtifacts = false
                    } else {
                        artifacts.openLibrary()
                        state.presentArtifacts()
                    }
                }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Argus Wrapped…") { state.openWindowRequest = "wrapped" }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Theme…") { state.showThemePicker = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Toggle("Unattended Mode — Auto-Approve Lab Requests", isOn: Binding(
                    get: { lab.unattendedMode },
                    set: { lab.setUnattendedMode($0) }
                ))
                .disabled(lab.unattendedModeUpdating)
                Toggle("Keep This Mac Awake While Locked", isOn: $state.keepAwake)
                Divider()
                Button("Refresh Sessions") { state.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Filter Sessions") { state.focusSearch() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Rename Session…") { if let sel = state.selection { state.renameText = sel.session; state.renameTarget = sel } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Kill Session") { if let sel = state.selection { state.killTarget = sel } }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { state.showFind = true; state.findFocusToken &+= 1 }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { _ = terminals.findNext(state.findText) }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { _ = terminals.findPrev(state.findText) }
                    .keyboardShortcut("g", modifiers: [.control, .command])   // ⇧⌘G belongs to the Git panel (feature panels are ⇧⌘-x); shift+Enter in the find bar also works
            }
            CommandMenu("Terminal") {
                // ⇧⌘M renders authoritative rich agent source when available,
                // with the exact styled terminal frame retained as its fallback.
                Button("Render Output…") { RenderLauncher.open(state: state, terminals: terminals) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("W&B Run ⇄ Terminal") { if let sel = state.selection { terminals.toggleWandb(sel) } }
                    .keyboardShortcut("w", modifiers: [.control, .command])
                Button("Git Panel ⇄ Terminal") {
                    if let sel = state.selection, let m = state.machines.first(where: { $0.id == sel.machineID }) {
                        terminals.toggleGit(sel, httpBase: m.httpBase, dir: state.resolveBase(for: sel))
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Increase Font Size") { terminals.adjustFont(1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { terminals.adjustFont(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { terminals.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Scroll to Bottom") { terminals.scrollToBottom() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Clear Buffer") { terminals.clearBuffer() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }

        Window("Port forwards", id: "ports") {
            PortsView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .allowsFullScreen()
        }
        .defaultSize(width: 780, height: 860)
        .windowStyle(.hiddenTitleBar)

        Window("Files", id: "files") {
            FilesView()
                .environmentObject(state)
                .environmentObject(files)
                .preferredColorScheme(.dark)
                .allowsFullScreen()
        }
        .defaultSize(width: 1000, height: 680)
        .windowStyle(.hiddenTitleBar)

        Window("Dashboards", id: "dashboards") {
            DashboardsView()
                .environmentObject(dashboards)
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .allowsFullScreen()
        }
        .defaultSize(width: 1100, height: 760)
        .windowStyle(.hiddenTitleBar)

        Window("Argus Wrapped", id: "wrapped") {
            WrappedWindowView(host: wrappedHost)
                .preferredColorScheme(.dark)
                .allowsFullScreen()
        }
        .defaultSize(width: 980, height: 900)
        .windowStyle(.hiddenTitleBar)


        Settings {
            SettingsView(terminals: terminals, state: state, lab: lab,
                         commandCenter: commandCenter)
        }
    }
}

/// Preferences window (⌘,). Live font-size control for the terminal pane.
struct SettingsView: View {
    @ObservedObject var terminals: TerminalController
    @ObservedObject var state: AppState
    @ObservedObject var lab: LabModel
    @ObservedObject var commandCenter: CommandCenterModel
    @ObservedObject private var capsLockAttention = CapsLockAttentionController.shared
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0
    @AppStorage(CapsLockAttentionPrefs.enabledKey) private var capsLockBlinkEnabled = false
    @AppStorage(CapsLockAttentionPrefs.durationKey) private var capsLockBlinkDuration = CapsLockAttentionPrefs.defaultDuration
    @AppStorage(CapsLockAttentionPrefs.reminderMinutesKey) private var capsLockReminderMinutes = CapsLockAttentionPrefs.defaultReminderMinutes
    @AppStorage(CapsLockAttentionPrefs.completionEnabledKey) private var capsLockCompletionEnabled = false
    @AppStorage(CapsLockAttentionPrefs.completionDurationKey) private var capsLockCompletionDuration = CapsLockAttentionPrefs.defaultCompletionDuration
    @AppStorage(ClipboardScreenshotArtifactPrefs.enabledKey)
    private var screenshotArtifactsEnabled = ClipboardScreenshotArtifactPrefs.defaultEnabled

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Text size")
                    Slider(value: $uiScale, in: 0.8...2.0, step: 0.05)
                    Text("\(Int(uiScale * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Button("Smaller") { uiScale = max(0.8, uiScale - 0.05) }
                    Button("Larger") { uiScale = min(2.0, uiScale + 0.05) }
                    Button("Reset") { uiScale = 1.0 }
                    Spacer()
                }
            } header: {
                Text("Interface")
            } footer: {
                Text("Scales all app interface text — sidebar, headers, and the Ports window (not the terminal).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $terminals.fontSize, in: 8...36, step: 0.5)
                    Text("\(terminals.fontSize, specifier: "%.1f") pt")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Button("Smaller (⌘−)") { terminals.adjustFont(-1) }
                    Button("Larger (⌘=)") { terminals.adjustFont(1) }
                    Button("Reset") { terminals.resetFontSize() }
                    Spacer()
                }
            } header: {
                Text("Terminal")
            }

            TerminalAppearanceSection(terminals: terminals)

            Section {
                Toggle("Show agent sessions", isOn: $state.showAgentSessions)
            } header: {
                Text("Sessions")
            } footer: {
                Text("Agent sessions are started by `ut spawn` (the mesh) as background jobs. They're hidden from the sidebar by default and auto-clean when left idle. Turn this on to see and open them here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Save foreground clipboard screenshots to Artifacts",
                    isOn: $screenshotArtifactsEnabled
                )
            } header: {
                Text("Artifacts")
            } footer: {
                Text("When the main Argus window is in front and a panel is visible, a new clipboard image is saved to that panel. Clipboard changes made while Argus is inactive are ignored permanently. Argus checks only the pasteboard generation during normal operation and uses no keyboard hooks, file watchers, or additional permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Blink Caps Lock light for Needs You", isOn: $capsLockBlinkEnabled)
                if capsLockBlinkEnabled {
                    HStack {
                        Text("Blink duration")
                        Slider(value: $capsLockBlinkDuration, in: 1...60, step: 1)
                        Text("\(Int(capsLockBlinkDuration))s")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    Picker("Repeat while pending", selection: $capsLockReminderMinutes) {
                        Text("Every minute").tag(1.0)
                        Text("Every 2 minutes").tag(2.0)
                        Text("Every 5 minutes").tag(5.0)
                        Text("Every 10 minutes").tag(10.0)
                        Text("Every 15 minutes").tag(15.0)
                        Text("Every 30 minutes").tag(30.0)
                    }
                }
                Toggle("Blink when Working becomes Idle", isOn: $capsLockCompletionEnabled)
                if capsLockCompletionEnabled {
                    HStack {
                        Text("Completion duration")
                        Slider(value: $capsLockCompletionDuration, in: 1...10, step: 1)
                        Text("\(Int(capsLockCompletionDuration))s")
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                HStack {
                    if capsLockAttention.inputAccess == .granted {
                        Button("Test Light") { capsLockAttention.testBlink() }
                    } else {
                        Button(capsLockAttention.inputAccess == .denied
                               ? "Open Input Monitoring…"
                               : "Allow Input Monitoring…") {
                            capsLockAttention.resolveInputAccess()
                        }
                    }
                    Spacer()
                    if capsLockAttention.inputAccess == .denied {
                        Text("Input Monitoring is off")
                            .font(.caption).foregroundStyle(Color.orange)
                    } else if capsLockAttention.inputAccess == .notDetermined {
                        Text("Required once by macOS")
                            .font(.caption).foregroundStyle(Color.orange)
                    } else if let count = capsLockAttention.lastTargetCount {
                        Text(count > 0
                             ? "\(count) Caps Lock light\(count == 1 ? "" : "s") found"
                             : "No Caps Lock LED found")
                            .font(.caption)
                            .foregroundStyle(count > 0 ? Color.secondary : Color.orange)
                    } else {
                        Text("Ready")
                            .font(.caption).foregroundStyle(Color.secondary)
                    }
                }
            } header: {
                Text("Attention")
            } footer: {
                Text("Needs You flashes when a terminal agent or Lab approval requires attention, then repeats while it remains pending. The separate completion signal flashes once when a visible panel moves directly from Working to Idle; hidden, backlogged, and internal agent sessions stay quiet. macOS calls the required hardware permission Input Monitoring, but Argus never registers input callbacks or reads keystrokes—it writes only the light and restores the current Caps Lock state.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Unattended mode", isOn: Binding(
                    get: { lab.unattendedMode },
                    set: { lab.setUnattendedMode($0) }
                ))
                .disabled(lab.unattendedModeUpdating)
                if lab.unattendedModeUpdating {
                    ProgressView().controlSize(.small)
                }
                if let error = lab.unattendedModeError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Automation")
            } footer: {
                Text("Keeps Lab work moving while you're away by automatically approving access-key requests and recorded run proposals. Every automatic decision is labeled in Lab's audit trail. This does not answer terminal questions yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Record activity journal", isOn: $state.journalEnabled)
                Button("Open Journal Folder") {
                    NSWorkspace.shared.open(ActivityJournal.dirURL)
                }
            } header: {
                Text("Activity journal")
            } footer: {
                Text("A local, append-only record of the moments you engage with your fleet: the screen you saw when you typed into a session, what you typed (never anything a terminal treated as secret, like a password), sessions you inspected, plus small markers for statuses, todos, workflows, W&B runs, and git reviews. One JSONL file per day, kept on this Mac only, never uploaded. This is the raw data future weekly reports read from.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep this Mac awake & reachable while locked", isOn: $state.keepAwake)
            } header: {
                Text("Power")
            } footer: {
                Text("Holds a power assertion so the Mac won't idle-sleep. Lock the screen and walk away: the display still turns off, but the system stays awake, so this Mac's sessions, its broker, and the processes inside them keep running and stay reachable from your phone. Works on battery too.\n\nThis stops idle sleep, not lid-close sleep — a closed-lid MacBook on battery still sleeps. Keep the lid open, or use an external display on power.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: capsLockBlinkEnabled) { enabled in
            if enabled { capsLockAttention.resolveInputAccess() }
            capsLockAttention.configurationDidChange()
            if enabled {
                commandCenter.bind(state)
                commandCenter.start()
                commandCenter.refreshAttention()
            }
        }
        .onChange(of: capsLockBlinkDuration) { _ in capsLockAttention.configurationDidChange() }
        .onChange(of: capsLockReminderMinutes) { _ in capsLockAttention.configurationDidChange() }
        .onChange(of: capsLockCompletionEnabled) { enabled in
            if enabled { capsLockAttention.resolveInputAccess() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                capsLockAttention.refreshInputAccess()
            }
        .onAppear {
            capsLockAttention.refreshInputAccess()
            if (capsLockBlinkEnabled || capsLockCompletionEnabled)
                    && capsLockAttention.inputAccess == .notDetermined {
                capsLockAttention.resolveInputAccess()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
        .tint(Theme.accent)
    }
}

/// ⇧⌘B: the backlog of panels you've hidden from the sidebar (right-click →
/// Hide Panel). They keep running; this just restores them to view. Click one to
/// bring it back and jump to it; Restore All clears the backlog.
struct HiddenPanelsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let items = state.hiddenSessionList
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash").foregroundStyle(Theme.textSecondary)
                Text("Hidden Panels").font(.system(size: 15, weight: .semibold))
                if !items.isEmpty {
                    Text("\(items.count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surface))
                }
                Spacer()
                if !items.isEmpty {
                    Button("Restore All") {
                        for it in items { state.unhide(it.ref) }
                        state.showHiddenPicker = false
                    }
                }
                Button("Done") { state.showHiddenPicker = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
                    Text("No hidden panels").foregroundStyle(Theme.textSecondary)
                    Text("Right-click a session → Hide Panel to stash it here.")
                        .font(.caption).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(items) { it in
                            HiddenPanelRow(
                                name: it.info.name,
                                subtitle: it.machineName + " · " + state.folderDisplay(
                                    (it.info.path?.isEmpty == false) ? it.info.path! : "—",
                                    isLocal: state.machine(for: it.ref)?.isLocal ?? false)
                            ) {
                                state.unhide(it.ref)
                                state.selection = it.ref
                                state.showOverview = false
                                state.showArtifacts = false
                                state.showHiddenPicker = false
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 460, height: 430)
        .background(Theme.appBackground)
    }
}

private struct HiddenPanelRow: View {
    let name: String
    let subtitle: String
    let restore: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: restore) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.uturn.backward.circle\(hover ? ".fill" : "")")
                    .foregroundStyle(hover ? Theme.accent : Theme.textTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hover ? Theme.selection.opacity(0.6) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The ⇧⌘Y Session History sheet: every session each broker has recorded (name,
/// node, folders it ran in, with timestamps) — including ones that no longer exist —
/// so you can recover where something was running. Filterable by name/node/folder.
struct SessionHistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @AppStorage("ut.historyHideAgents") private var hideAgents = true

    private var items: [SessionHistoryItem] {
        var base = state.historyItems
        if hideAgents { base = base.filter { !$0.agent } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || $0.node.lowercased().contains(q)
                || $0.folders.contains { $0.path.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.textSecondary)
                Text("Session History").font(.system(size: 15, weight: .semibold))
                if !items.isEmpty {
                    Text("\(items.count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surface))
                }
                Spacer()
                if state.historyLoading {
                    ProgressView().controlSize(.small)
                }
                Button { hideAgents.toggle() } label: {
                    Image(systemName: hideAgents ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(hideAgents ? "Agent sessions hidden — click to show" : "Hide agent sessions")
                Button { state.loadHistory() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Button("Done") { state.showHistory = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            TextField("Filter by name, node, or folder", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
                    Text(state.historyLoading ? "Loading…" : "No history yet").foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(items) { item in
                            SessionHistoryRow(
                                item: item,
                                nodeLabel: state.machineForNode(item.node)?.name ?? item.node,
                                canOpen: state.machineForNode(item.node) != nil,
                                onOpen: { state.openHistoryItem(item) })
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 580, height: 580)
        .background(Theme.appBackground)
    }
}

private struct SessionHistoryRow: View {
    let item: SessionHistoryItem
    var nodeLabel: String = ""   // friendly machine name when the node resolves, else the raw node
    var canOpen: Bool = false
    var onOpen: () -> Void = {}
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(item.alive ? Theme.running : Theme.textTertiary.opacity(0.45)).frame(width: 7, height: 7)
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if item.agent {
                    Text("agent").font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Theme.surface))
                }
                Text(nodeLabel.isEmpty ? item.node : nodeLabel).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                if canOpen {
                    Image(systemName: item.alive ? "arrow.up.forward.app" : "play.circle")
                        .font(.system(size: 11)).foregroundStyle(hover ? Theme.accent : Theme.textTertiary)
                }
                Text(item.alive ? "running" : relativeShort(item.last))
                    .font(.system(size: 11)).foregroundStyle(item.alive ? Theme.running : Theme.textTertiary)
                    .help(absoluteTime(item.last))
            }
            // Folders the session ran in, newest first (it may have cd'd around).
            ForEach(Array(item.folders.reversed().enumerated()), id: \.offset) { _, f in
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    Text(f.path).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Text(relativeShort(f.last)).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        .help(absoluteTime(f.first) + " → " + absoluteTime(f.last))
                }
            }
            if item.folders.isEmpty {
                Text("(no folder recorded)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(canOpen && hover ? Theme.accent.opacity(0.14) : Theme.surface.opacity(0.4)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1)
                .opacity(canOpen && hover ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if canOpen { onOpen() } }
        .help(!canOpen ? "" : item.alive
              ? "Open this session"
              : "Session ended — click to re-create it"
                + (item.folders.last.map { " in \($0.path)" } ?? "") + " and open")
    }
}

/// "Jun 18, 2:05 PM" for a unix-seconds timestamp (history tooltips).
func absoluteTime(_ unixSeconds: Int64) -> String {
    guard unixSeconds > 0 else { return "—" }
    let f = DateFormatter()
    f.dateFormat = "MMM d, h:mm a"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
}

/// A sidebar session row identified by MACHINE + name, not name alone. Two nodes
/// can host sessions with the same name (e.g. both have `scenesmith`); keying the
/// ForEach on the bare `SessionInfo.id` (= name) collapses them to one SwiftUI
/// identity, so only one row renders and its tap/connection binds to the wrong
/// node. This wrapper restores a globally-unique identity (the SessionRef id).
private struct SidebarSession: Identifiable {
    let machineID: String
    let info: SessionInfo
    var id: String { machineID + "/" + info.name }
}

/// The standard macOS About panel, with the Argus tagline as credits (the app
/// icon + name + version come from the bundle).
private func showAbout() {
    let credits = NSAttributedString(
        string: "One watchful eye over every coding agent, on every machine.\n\nReach every claude session across your Mac, clusters, Windows, and phone — terminals, ports, and files — over Tailscale, peer-to-peer. No central server.",
        attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                     .font: NSFont.systemFont(ofSize: 11),
                     .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .applicationName: "Argus",
        .credits: credits,
    ])
    NSApp.activate(ignoringOtherApps: true)
}

/// Wraps RootView so the chrome rebuilds on a theme switch (`.id(themeID)` → every
/// `Theme.X` is re-read) while the theme picker — hosted HERE, outside that `.id` — stays
/// open so you can flip through themes and watch the app recolor. Terminals recolor
/// separately via the `.utThemeChanged` notification (their views are cached, not rebuilt).
struct ThemedRoot: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var themeStore: ThemeStore
    var body: some View {
        RootView()
            .id(themeStore.themeID)
            .sheet(isPresented: $state.showThemePicker) {
                ThemePickerView().environmentObject(themeStore)
            }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var terminals: TerminalController
    @EnvironmentObject var files: FilesModel
    @EnvironmentObject var dashboards: DashboardsModel
    @EnvironmentObject var notebooks: NotebooksModel
    @EnvironmentObject var wandb: WandbController
    @EnvironmentObject var gitPanels: GitPanels
    @EnvironmentObject var ledgerHost: LedgerPanelHost
    @EnvironmentObject var commandCenter: CommandCenterModel
    @EnvironmentObject var lab: LabModel
    @EnvironmentObject var artifacts: ArtifactStore
    @ViewBuilder private var ledgerPane: some View {
        LedgerView(panel: ledgerHost.panel).onAppear { ledgerHost.panel.refresh() }
    }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.openWindow) private var openWindow
    @State private var newName = ""
    @State private var newMachine = "local"
    @State private var newIsNotebook = false
    @State private var newFolder = ""
    @State private var query = ""
    @State private var isFullscreen = false
    @FocusState private var searchFocused: Bool
    @FocusState private var findFocused: Bool
    @FocusState private var newNameFocused: Bool
    @State private var matchCount = 0   // find-bar match counter
    // UI (chrome) font scale — applies to all sidebar/header text, not the terminal.
    @AppStorage("ut.uiScale") private var uiScale: Double = 1.0

    /// Chrome font helper: multiplies the base size by the user's UI text scale.
    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    // Fullscreen has NO traffic lights and no menu bar → zero top chrome, like Warp.
    private var topReserve: CGFloat { isFullscreen ? 0 : 28 } // sidebar: clears traffic lights when windowed
    private var detailTop: CGFloat { isFullscreen ? 0 : 8 }   // detail: no traffic lights above it
    private var hairline: CGFloat { 1 / displayScale }

    var body: some View {
        // Plain HStack instead of NavigationSplitView: the split view silently reserves
        // a toolbar/titlebar-height region at the top of its columns that NO safe-area
        // trick can remove (the source of the fullscreen top band). A manual layout fills
        // the window exactly — each column controls its own top spacing via topReserve.
        HStack(spacing: 0) {
            // Artifacts is a library destination, not a panel detail. Give it the
            // entire window while preserving the user's normal sidebar setting
            // so closing the library restores the workspace exactly as it was.
            if state.columns != .detailOnly && !state.showArtifacts {
                sidebar
                    .frame(width: 272)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Group {
                if state.showArtifacts {
                    ArtifactsView()
                } else if state.showLab {
                    LabCenterView()
                } else if state.showLedger {
                    ledgerPane
                } else if state.showNotes {
                    NotesHubView()
                } else if state.showTodos {
                    TodoCenterView()
                } else if state.showOverview {
                    CommandCenterView()
                } else {
                    detail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea() // fill the entire window; columns space their own top edge
        .overlay {
            if let document = state.renderDocument {
                RenderPanel(document: document)
                    .environmentObject(state)
                    .environmentObject(artifacts)
            }
        }
        .background(WindowAccessor(onFullscreen: { isFullscreen = $0 }))
        .onAppear {
            MainThreadStallMonitor.shared.start()
            ledgerHost.panel.onOpenArtifact = { id in
                guard let record = artifacts.records.first(where: { $0.id == id }) else {
                    artifacts.errorMessage = "That PDF is no longer in the artifact library."
                    artifacts.openLibrary()
                    state.presentArtifacts()
                    return
                }
                artifacts.open(artifact: record)
                state.presentArtifacts()
            }
            AttentionNotifier.shared.attach(state)
            commandCenter.bind(state)
            // Preserve the command center's prior lazy-start behavior unless the
            // hardware alert needs its status model running in the background.
            if CapsLockAttentionPrefs.enabled { commandCenter.start() }
            lab.bind(state)   // app-wide: approval notifications fire with the pane closed
            AttentionNotifier.shared.requestAuthorizationIfNeeded()
            state.refreshAll(); state.startAutoRefresh()
        }
        .onReceive(state.$sessionsByMachine) { _ in commandCenter.refreshAttention() }
        .onReceive(state.$hiddenSessions) { _ in commandCenter.refreshAttention() }
        .onReceive(state.$backlog) { _ in commandCenter.refreshAttention() }
        .onChange(of: state.searchFocusToken) { _ in searchFocused = true }
        .onChange(of: state.selection) { _ in notebooks.activeID = nil }   // selecting a terminal leaves the notebook view
        // When an overlay dismisses, the keyboard goes back to the visible
        // TERMINAL — never stranded on whatever AppKit picks next (the
        // sidebar filter). One central place so every close path is covered.
        // The palette close defers to find/render if it just LAUNCHED one
        // (e.g. "Find in Terminal" from the palette must keep the find field).
        .onChange(of: state.showFind) { open in if !open { terminals.focusTerminal() } }
        .onChange(of: state.showPalette) { open in
            if open {
                // The palette is a real KEY WINDOW (NSPanel), not an overlay:
                // while it is up the main window cannot receive keystrokes, so
                // typing can never leak into the sidebar filter or a terminal.
                PaletteWindow.shared.show(
                    over: NSApp.keyWindow ?? NSApp.mainWindow,
                    onDismiss: { if state.showPalette { state.showPalette = false } }
                ) {
                    // This view is hosted in a detached AppKit panel, so it does not
                    // inherit RootView's environment. Pass every dependency explicitly:
                    // adding a new one now becomes a compile-time requirement instead of
                    // an EnvironmentObject runtime trap when the palette first renders.
                    CommandPalette(machineName: machineName, state: state,
                                   terminals: terminals, lab: lab, artifacts: artifacts)
                }
            } else {
                PaletteWindow.shared.hide()
                if !state.showFind && state.renderDocument == nil { terminals.focusTerminal() }
            }
        }
        .onChange(of: state.openWindowRequest) { id in
            // Palette actions can't reach SwiftUI's openWindow from inside the
            // AppKit panel — they route the request through state instead.
            guard let id else { return }
            openWindow(id: id)
            state.openWindowRequest = nil
        }
        .onChange(of: state.renderDocument) { value in if value == nil { terminals.focusTerminal() } }
        .sheet(isPresented: $state.showNew) { newSessionSheet }
        .sheet(isPresented: $state.showHiddenPicker) { HiddenPanelsView().environmentObject(state) }
        .sheet(isPresented: $state.showHistory) { SessionHistoryView().environmentObject(state) }
        .sheet(isPresented: $state.showWorkflows) { WorkflowsView().environmentObject(state) }
        .alert("Rename session", isPresented: Binding(get: { state.renameTarget != nil }, set: { if !$0 { state.renameTarget = nil } })) {
            TextField("name", text: $state.renameText)
            Button("Rename") {
                if let t = state.renameTarget {
                    let to = state.renameText.trimmingCharacters(in: .whitespaces)
                    if !to.isEmpty, to != t.session {
                        let newRef = SessionRef(machineID: t.machineID, session: to)
                        let wasSel = (state.selection == t)
                        state.renameSession(t, to: to) { ok in
                            guard ok else { return } // failed: leave the live pane as-is; refresh reconciles
                            // Seamless: re-key the SAME live connection to the new name — the broker
                            // kept the session streaming across the rename, so no drop/reconnect.
                            if let url = state.wsURL(for: newRef) {
                                terminals.renameConn(from: t.id, to: newRef.id, url: url)
                            }
                            if wasSel { state.selection = newRef }
                        }
                    }
                }
                state.renameTarget = nil
            }
            Button("Cancel", role: .cancel) { state.renameTarget = nil }
        }
        .confirmationDialog(
            "Kill “\(state.killTarget?.session ?? "")”? This terminates everything running in it.",
            isPresented: Binding(get: { state.killTarget != nil }, set: { if !$0 { state.killTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                if let t = state.killTarget {
                    // Move selection OFF the session first so the detail stops showing it;
                    // otherwise dropping its conn makes updateNSView recreate a doomed pane
                    // (the blank/error terminal seen after a kill). Then drop + kill.
                    if state.selection == t { state.selection = state.neighborSession(excluding: t) }
                    terminals.drop(t.id)
                    state.killSession(t)
                }
                state.killTarget = nil
            }
            Button("Cancel", role: .cancel) { state.killTarget = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            ScrollView {
                // The sidebar is deliberately non-lazy. A real fleet is tens of rows,
                // while SwiftUI's pinned LazyVStack repeatedly entered multi-second
                // anchor-placement passes when broker snapshots and selection changed.
                // A stable VStack is both cheaper at this scale and cannot enter that
                // lazy scroll-anchor reconciliation path.
                VStack(alignment: .leading, spacing: 1) {
                    NeedsAttentionSection(waiting: state.waitingSessions, selection: $state.selection)
                    ForEach(state.machines) { machine in
                        let groups = filteredGroups(machine)
                        VStack(alignment: .leading, spacing: 1) {
                            machineHeader(machine, sessionCount: groups.reduce(0) { $0 + $1.sessions.count })
                            machineBody(machine, groups: groups)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
        .background(
            ZStack {
                VisualEffectView(material: .sidebar, blending: .behindWindow)
                Theme.sidebarBackground.opacity(0.97)
            }
            .ignoresSafeArea()
        )
        .ignoresSafeArea(.container, edges: .top) // column-level: kill the titlebar/notch reserve
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
    }

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            Text("Argus")
                .font(cf(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            if state.waitingCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill").font(cf(8.5))
                    Text("\(state.waitingCount)").font(cf(10.5, .semibold)).monospacedDigit()
                }
                .foregroundStyle(SwiftUI.Color(hex: "#24252F"))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.waiting))
                .help("\(state.waitingCount) session\(state.waitingCount == 1 ? "" : "s") waiting on you")
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if lab.unattendedMode {
                Button { lab.setUnattendedMode(false) } label: {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.waiting)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Unattended Mode is on — Lab requests are auto-approved. Click to turn off.")
                .transition(.scale.combined(with: .opacity))
            }
            // Only takes a slot in the bar when it's ON — otherwise it lives in ⌘P /
            // the View menu / Settings. When on, it's a glanceable indicator + quick off.
            if state.keepAwake {
                Button { state.keepAwake.toggle() } label: {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Keeping this Mac awake & reachable while locked — on. Click to turn off.")
                .transition(.scale.combined(with: .opacity))
            }
            if state.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 24, height: 22)
            } else {
                IconButton(system: "arrow.clockwise", help: "Refresh (⌘R)") { state.refreshAll() }
            }
            IconButton(system: "plus", help: "New session (⌘N)") { openNew() }
            IconButton(system: "cable.connector", help: "Port forwards") { openWindow(id: "ports") }
            IconButton(system: "folder", help: "Files") { openWindow(id: "files") }
            IconButton(system: "rectangle.on.rectangle.angled", help: "Dashboards") { openWindow(id: "dashboards") }
            IconButton(system: "book.closed", help: "Activity Ledger (⇧⌘J)") {
                state.showLedger.toggle()
                if state.showLedger { state.showOverview = false; state.showTodos = false; state.showNotes = false; state.showLab = false; state.showArtifacts = false }
            }
            IconButton(system: "flask", help: "Lab (⇧⌘L)") {
                state.showLab.toggle()
                if state.showLab { state.showOverview = false; state.showTodos = false; state.showNotes = false; state.showLedger = false; state.showArtifacts = false }
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 12)
        .padding(.top, topReserve)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(cf(11))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.textTertiary)
            TextField("Filter sessions", text: $query)
                .textFieldStyle(.plain)
                .font(cf(12))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false; terminals.focusTerminal() }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(searchFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func machineHeader(_ m: Machine, sessionCount: Int) -> some View {
        let status = state.statusByMachine[m.id]
        let reachable = status != nil && status != "unreachable"
        let dotColor: Color = status == nil ? Theme.textTertiary : (reachable ? Theme.attached : Theme.unreachable)
        return HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Image(systemName: m.isLocal ? "laptopcomputer" : "server.rack")
                .font(cf(11))
                .foregroundStyle(Theme.textTertiary)
            Text(m.name.uppercased())
                .font(cf(11, .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if reachable, let rtt = state.rttByMachine[m.id] {
                Text("\(rtt)ms").font(cf(10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            countBadge(sessionCount: sessionCount, reachable: reachable, loading: status == nil)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Theme.sidebarBackground.opacity(0.96))
        .contextMenu {
            Button {
                dashboards.openJupyter(on: m)
                openWindow(id: "dashboards")
            } label: { Label("Open JupyterLab", systemImage: "book.closed") }
            .disabled(!reachable)
        }
    }

    private func countBadge(sessionCount: Int, reachable: Bool, loading: Bool) -> some View {
        return Group {
            if loading {
                Text("…").foregroundStyle(Theme.textTertiary)
            } else if !reachable {
                Text("offline").foregroundStyle(Theme.unreachable)
            } else {
                Text("\(sessionCount)")
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.surface))
            }
        }
        .font(cf(10.5, .medium))
    }

    @ViewBuilder private func machineBody(_ m: Machine, groups: [FolderGroup]) -> some View {
        let nbs = notebooks.forMachine(m.id)
        ForEach(nbs) { nb in notebookRow(nb) }
        if groups.isEmpty {
            if nbs.isEmpty {
                Text(emptyLabel(m))
                    .font(cf(11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 12)
                    .padding(.vertical, 6)
            }
        } else {
            ForEach(groups) { group in
                if group.folder != "—" {
                    folderLabel(state.folderDisplay(group.folder, isLocal: m.isLocal))
                }
                ForEach(group.sessions.map { SidebarSession(machineID: m.id, info: $0) }) { item in
                    let s = item.info
                    let ref = SessionRef(machineID: m.id, session: s.name)
                    SessionRow(
                        session: s,
                        unseen: state.unseen.contains(ref.id),
                        folderText: state.folderDisplay((s.path?.isEmpty == false) ? s.path! : "—", isLocal: m.isLocal),
                        selected: state.selection == ref,
                        onTap: { state.selection = ref; state.showOverview = false; state.showArtifacts = false },
                        onRename: { state.renameText = s.name; state.renameTarget = ref },
                        onKill: { state.killTarget = ref },
                        onCopyName: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(s.name, forType: .string)
                        },
                        onHide: { state.hide(ref) },
                        wandbRuns: terminals.wandbRuns(for: ref),
                        onOpenWandb: { run in state.selection = ref; state.showOverview = false; state.showArtifacts = false; terminals.showWandb(ref, run: run) },
                        onClearWandb: { run in terminals.clearWandb(run, for: ref) },
                        onReveal: (m.isLocal && (s.path?.isEmpty == false))
                            ? { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: s.path ?? "") }
                            : nil,
                        onRevealFiles: (s.path?.isEmpty == false)
                            ? { files.addTab(m, startPath: state.resolveBase(for: ref)); openWindow(id: "files") }
                            : nil,
                        onGit: !state.resolveBase(for: ref).isEmpty
                            ? {
                                state.selection = ref; state.showOverview = false; state.showArtifacts = false
                                if !terminals.isGitShown(ref) {
                                    terminals.toggleGit(ref, httpBase: m.httpBase, dir: state.resolveBase(for: ref))
                                }
                            }
                            : nil
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func notebookRow(_ nb: NotebookSession) -> some View {
        let selected = notebooks.activeID == nb.id
        return HStack(spacing: 7) {
            Image(systemName: "book.closed").font(cf(10))
                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            Text(nb.name).font(cf(12)).lineLimit(1)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            Spacer(minLength: 4)
            Button { notebooks.close(nb.id) } label: {
                Image(systemName: "xmark").font(cf(8.5, .bold)).foregroundStyle(Theme.textTertiary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { notebooks.select(nb.id); state.showArtifacts = false }
    }

    private func folderLabel(_ text: String) -> some View {
        Text(text)
            .font(cf(10.5, .medium))
            .tracking(0.3)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .padding(.top, 9)
            .padding(.bottom, 2)
    }

    private func filteredGroups(_ m: Machine) -> [FolderGroup] {
        state.folderGroups(for: m.id, matching: query)
    }

    private func emptyLabel(_ m: Machine) -> String {
        if state.statusByMachine[m.id] == "unreachable" { return "unreachable" }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "no matches" }
        return "no sessions"
    }

    // MARK: Detail

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader
            if let nb = notebooks.active {
                NotebookPaneView(tab: nb.tab)
                    // Resolve when a notebook becomes active — covers BOTH a restored notebook
                    // (url == nil after relaunch) and a freshly-selected one. resolveIfNeeded
                    // no-ops if it's already loaded/in-flight.
                    .task(id: nb.id) {
                        if let m = state.machines.first(where: { $0.id == nb.machineID }) {
                            notebooks.resolveIfNeeded(nb, on: m)
                        } else if nb.tab.url == nil {
                            nb.tab.status = "\(machineName(nb.machineID)) is offline"
                        }
                    }
            } else if let ref = state.selection {
                if terminals.isGitShown(ref) {
                    // Git panel in place of the terminal. Default = the read-only VIEWER
                    // (webview: status/diffs/history/blame, fed from the broker's /git/*).
                    // The "lazygit" button switches to the lazygit TERMINAL for write ops.
                    if terminals.isGitTerminal(ref) {
                        if let g = terminals.gitRef(for: ref) {
                            VStack(spacing: 0) {
                                HStack {
                                    Button { terminals.closeLazygitTerminal(ref) } label: {
                                        Label("Back to git viewer", systemImage: "chevron.left")
                                            .font(cf(11, .medium))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                }
                                .padding(.horizontal, Theme.contentInset).padding(.vertical, 4)
                                TerminalHostView(controller: terminals, ref: g, url: state.wsURL(for: g))
                                    .padding(EdgeInsets(top: 0, leading: Theme.contentInset, bottom: 8, trailing: Theme.contentInset))
                            }
                        } else {
                            VStack(spacing: 10) {
                                if let err = terminals.gitError[ref.id] {
                                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Theme.textTertiary)
                                    Text(err).font(cf(12)).foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                                } else {
                                    ProgressView().controlSize(.small)
                                    Text("starting lazygit…").font(cf(12)).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if let m = state.machines.first(where: { $0.id == ref.machineID }),
                              case let dir = state.resolveBase(for: ref), !dir.isEmpty {
                        GitPaneView(panel: gitPanels.panel(
                            for: ref, httpBase: m.httpBase, dir: dir,
                            onLazygit: { terminals.openLazygitTerminal(ref, httpBase: m.httpBase, dir: dir) },
                            onOpenFile: { p in
                                // Open the containing folder in Files (startPath expects a dir).
                                let abs = p.hasPrefix("/") ? p : dir + "/" + p
                                files.addTab(m, startPath: (abs as NSString).deletingLastPathComponent)
                                openWindow(id: "files")
                            }))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Theme.textTertiary)
                            Text(terminals.gitError[ref.id] ?? "machine offline or no folder known")
                                .font(cf(12)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if terminals.isWandbShown(ref), terminals.currentRun(for: ref) != nil {
                    // W&B run, in place of the terminal. Its broker connection and
                    // W&B detector stay alive; SwiftTerm catches up from one snapshot
                    // on return instead of repainting an invisible terminal.
                    WandbPaneView(controller: wandb, terminals: terminals, ref: ref)
                } else {
                    TerminalHostView(controller: terminals, ref: ref, url: state.wsURL(for: ref))
                        .padding(EdgeInsets(top: 8, leading: Theme.contentInset, bottom: 8, trailing: Theme.contentInset))
                }
            } else {
                emptyGuidance
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .ignoresSafeArea(.container, edges: .top) // column-level: kill the titlebar/notch reserve
        .onAppear {
            // Route a terminal cmd+click on a file path to the Files window for the
            // VISIBLE session's host (paths live on the node, not the Mac).
            terminals.openPathHandler = { path, line in
                guard let ref = state.selection, let m = state.machine(for: ref) else { return }
                let cwd = state.resolveBase(for: ref)   // honor a user-pinned working dir
                files.openTerminalPath(m, rawPath: path, base: cwd, line: line)
                openWindow(id: "files")
            }
            // Route a terminal ⌘-click on a localhost URL to the Dashboards window for
            // the visible session's host (auto-forwarding the port if it's remote).
            terminals.openLocalhostHandler = { port, path, scheme in
                guard let ref = state.selection, let m = state.machine(for: ref) else { return }
                dashboards.openLocalhost(on: m, port: port, path: path, scheme: scheme)
                openWindow(id: "dashboards")
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: hairline).ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            if state.showFind, state.selection != nil { findBar.padding(.top, detailTop + 6).padding(.trailing, 12) }
        }
        .overlay(alignment: .bottomTrailing) {
            if state.selection != nil, !terminals.atBottom {
                Button { terminals.scrollToBottom() } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.accent).shadow(color: .black.opacity(0.3), radius: 4, y: 1))
                }
                .buttonStyle(.plain)
                .padding(20)
                .transition(.opacity)
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            TextField("Find", text: $state.findText)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .frame(width: 150)
                .focused($findFocused)
                .onSubmit { _ = terminals.findNext(state.findText) }
                .onChange(of: state.findText) { t in
                    if t.isEmpty { terminals.clearFind(); matchCount = 0 }
                    else { _ = terminals.findNext(t); matchCount = terminals.matchCount(t) }
                }
            if !state.findText.isEmpty {
                Text(matchCount == 0 ? "no results" : "\(matchCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(matchCount == 0 ? Theme.waiting : Theme.textTertiary)
                    .fixedSize()
            }
            Button { _ = terminals.findPrev(state.findText) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            Button { _ = terminals.findNext(state.findText) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            Button { closeFind() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        )
        .onExitCommand { closeFind() }
        .onChange(of: state.findFocusToken) { _ in focusFindSoon() }
        .onAppear { focusFindSoon(); if !state.findText.isEmpty { matchCount = terminals.matchCount(state.findText) } }
    }

    /// Focus the find field RELIABLY: setting @FocusState synchronously while
    /// the bar is being inserted silently fails on macOS, and focus then falls
    /// to the first key view — the sidebar filter. Set it now (bar already
    /// mounted) AND after a beat (fresh insert).
    private func focusFindSoon() {
        findFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { findFocused = true }
    }

    private func closeFind() {
        state.showFind = false
        terminals.clearFind()
        findFocused = false
    }

    private var detailHeader: some View {
        let ref = state.selection
        let s = ref.flatMap { selectedSession($0) }
        let st = ref.flatMap { terminals.connState[$0.id] }
        return HStack(spacing: 8) {
            IconButton(system: "sidebar.leading", help: "Toggle Sidebar (⌃⌘S)") { state.toggleSidebar() }
            if let nb = notebooks.active {
                // A notebook is the active pane — show ITS identity, not the terminal's.
                let busy = nb.tab.status != nil || nb.tab.isLoading
                Circle().fill(busy ? Color(hex: "#E0AF68") : Theme.attached).frame(width: 7, height: 7)
                Image(systemName: "book.closed").font(cf(12)).foregroundStyle(Theme.textSecondary)
                Text(nb.name).font(cf(13, .semibold)).foregroundStyle(Theme.textPrimary)
                meta("·"); meta(machineName(nb.machineID))
                meta("·"); meta(nb.path)
                if let stx = nb.tab.status {
                    meta("·")
                    Text(stx).font(cf(11, .medium)).foregroundStyle(Color(hex: "#E0AF68")).lineLimit(1)
                }
            } else if let ref {
                Circle().fill(liveColor(st)).frame(width: 7, height: 7)
                Text(ref.session)
                    .font(cf(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                meta("·"); meta(machineName(ref.machineID))
                if let s {
                    meta("·"); meta("\(s.windows) win")
                    meta("·")
                    SessionPathField(ref: ref, brokerPath: s.path ?? "",
                                     isLocal: machineIsLocal(ref.machineID), font: cf(11))
                    meta("·"); activityMeta(s.activity)
                }
                if st == .reconnecting || st == .connecting {
                    Text(st == .connecting ? "connecting…" : "reconnecting…")
                        .font(cf(11, .medium))
                        .foregroundStyle(Color(hex: "#E0AF68"))
                }
            } else {
                Text("No session selected")
                    .font(cf(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            if let nb = notebooks.active {
                IconButton(system: "arrow.clockwise", help: "Reload notebook") {
                    if let m = state.machines.first(where: { $0.id == nb.machineID }) { notebooks.reload(nb, on: m) }
                }
                IconButton(system: "safari", help: "Open in browser") { nb.tab.openInSystemBrowser() }
            } else {
                if let ref = state.selection {
                    if let context = state.artifactContext(for: ref) {
                        let artifactCount = artifacts.count(for: context.key)
                        IconButton(
                            system: artifactCount > 0 ? "archivebox.fill" : "archivebox",
                            help: artifactCount == 0
                                ? "Artifacts for this panel"
                                : "Artifacts for this panel (\(artifactCount) PDF\(artifactCount == 1 ? "" : "s"))"
                        ) {
                            artifacts.open(panel: context)
                            state.presentArtifacts()
                        }
                    }
                    // Git panel toggle: lazygit in this session's folder, in place of
                    // the terminal (⇧⌘G).
                    IconButton(system: terminals.isGitShown(ref) ? "terminal" : "arrow.triangle.branch",
                               help: terminals.isGitShown(ref) ? "Back to terminal (⇧⌘G)" : "Git panel — lazygit (⇧⌘G)") {
                        if let m = state.machines.first(where: { $0.id == ref.machineID }) {
                            terminals.toggleGit(ref, httpBase: m.httpBase, dir: state.resolveBase(for: ref))
                        }
                    }
                }
                IconButton(system: "textformat.size.smaller", help: "Decrease font (⌘-)") { terminals.adjustFont(-1) }
                IconButton(system: "textformat.size.larger", help: "Increase font (⌘=)") { terminals.adjustFont(1) }
            }
            IconButton(system: "plus", help: "New session (⌘N)") { openNew() }
        }
        .frame(height: 36)
        .padding(.horizontal, Theme.contentInset)
        .padding(.top, detailTop)
        .background(Theme.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: hairline)
        }
    }

    private func meta(_ s: String) -> some View {
        Text(s).font(cf(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }

    private func activityMeta(_ activity: Int64) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            meta(relativeShort(activity))
        }
    }

    private func liveColor(_ st: ConnState?) -> Color {
        switch st {
        case .connected: return Theme.attached
        case .connecting, .reconnecting: return Color(hex: "#E0AF68")
        case .closed: return Theme.unreachable
        case .none: return Theme.textTertiary
        }
    }

    private var emptyGuidance: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 42))
                .foregroundStyle(Theme.textTertiary)
            Text("No session selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Pick a session in the sidebar, or start a new one.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Button { openNew() } label: {
                Text("New Session  ⌘N").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectedSession(_ ref: SessionRef) -> SessionInfo? {
        (state.sessionsByMachine[ref.machineID] ?? []).first { $0.name == ref.session }
    }

    private func machineName(_ id: String) -> String {
        state.machines.first(where: { $0.id == id })?.name ?? id
    }

    private func machineIsLocal(_ id: String) -> Bool {
        state.machines.first(where: { $0.id == id })?.isLocal ?? false
    }

    // MARK: New-session sheet

    private func openNew() {
        newName = ""
        newMachine = state.selection?.machineID ?? "local"
        newIsNotebook = false
        newFolder = state.selection.flatMap { state.session(for: $0)?.path } ?? ""
        state.showNew = true
    }

    private var newSessionSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(newIsNotebook ? "New JupyterLab" : "New session")
                .font(cf(18, .semibold))
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $newIsNotebook) {
                Text("Terminal").tag(false)
                Text("JupyterLab").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 7) {
                Text("Machine").font(cf(13, .medium)).foregroundStyle(Theme.textSecondary)
                Menu {
                    ForEach(state.machines) { m in
                        Button(m.name) { newMachine = m.id }
                    }
                } label: {
                    HStack {
                        Text(machineName(newMachine)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(cf(11)).foregroundStyle(Theme.textTertiary)
                    }
                    .font(cf(14))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(fieldChrome)
                }
                .menuStyle(.borderlessButton)
            }

            if !newIsNotebook {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Name").font(cf(13, .medium)).foregroundStyle(Theme.textSecondary)
                    TextField("session name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(cf(14))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(fieldChrome)
                        .focused($newNameFocused)
                        .onSubmit { createSession() }
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Folder").font(cf(13, .medium)).foregroundStyle(Theme.textSecondary)
                    TextField("/absolute/path/to/folder", text: $newFolder)
                        .textFieldStyle(.plain)
                        .font(cf(14))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(fieldChrome)
                        .onSubmit { createSession() }
                    Text("Opens JupyterLab rooted at this folder; create or open notebooks from the Lab launcher. The kernel runs on the machine.")
                        .font(cf(10.5)).foregroundStyle(Theme.textTertiary)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { state.showNew = false }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button(newIsNotebook ? "Open" : "Create") { createSession() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(newIsNotebook
                              ? newFolder.trimmingCharacters(in: .whitespaces).isEmpty
                              : newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(cf(14))
        }
        .padding(26)
        .frame(width: 460)
        .background(Theme.appBackground)
        .tint(Theme.accent)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { newNameFocused = true } }
    }

    private var fieldChrome: some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func createSession() {
        if newIsNotebook {
            let dir = newFolder.trimmingCharacters(in: .whitespaces)
            guard !dir.isEmpty, let m = state.machines.first(where: { $0.id == newMachine }) else { return }
            state.showNew = false
            notebooks.openLab(on: m, dir: dir)
        } else {
            let name = newName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            state.showNew = false
            state.createSession(on: newMachine, name: name)
        }
    }
}


/// The selected session's working directory in the detail header. Click to PIN a
/// manual override used as the resolve base for terminal cmd+click — the Windows
/// ConPTY backend can't yet track `cd`, so the broker's reported cwd goes stale.
/// Clearing the field unpins it (falls back to the broker's cwd). A pin glyph marks
/// an active override.
private struct SessionPathField: View {
    @EnvironmentObject var state: AppState
    let ref: SessionRef
    let brokerPath: String
    let isLocal: Bool
    let font: Font
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let override = state.pathOverride(for: ref)
        let effective = override ?? brokerPath
        return Group {
            if editing {
                TextField("working dir", text: $text)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 240, alignment: .leading)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { state.setPathOverride(text, for: ref); editing = false }
                    .onExitCommand { editing = false }   // Esc cancels without changing the pin
            } else {
                HStack(spacing: 4) {
                    if override != nil {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Theme.accent)
                    }
                    Text(effective.isEmpty ? "set working dir…" : state.folderDisplay(effective, isLocal: isLocal))
                        .font(font)
                        .foregroundStyle(override != nil ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: 240, alignment: .leading)
                .contentShape(Rectangle())
                .help(override != nil
                      ? "Pinned working dir for file clicks — click to edit, clear to unpin"
                      : "Click to pin this session's working dir for terminal file clicks")
                .onTapGesture { text = effective; editing = true }
            }
        }
    }
}

/// Shared status dot: filled when attached/live, hollow ring (equal weight) when not.
struct StatusDot: View {
    let filled: Bool
    var color: Color = Theme.attached
    var size: CGFloat = 6
    var body: some View {
        Group {
            if filled { Circle().fill(color) }
            else { Circle().strokeBorder(Theme.textSecondary, lineWidth: 1.5) }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Command palette (⌘K)

/// Fuzzy cross-node session switcher + action launcher. Type to filter, ↑/↓ to
/// move, ↩ to run the highlighted item, Esc to dismiss.
struct CommandPalette: View {
    let machineName: (String) -> String
    @ObservedObject var state: AppState
    @ObservedObject var terminals: TerminalController
    @ObservedObject var lab: LabModel
    @ObservedObject var artifacts: ArtifactStore
    @State private var query = ""
    @State private var sel = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let icon: String
        let title: String
        let subtitle: String
        let run: () -> Void
    }

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func match(_ s: String) -> Bool { q.isEmpty || s.lowercased().contains(q) }
        var out: [Item] = []
        for ref in state.allSessions {
            let mn = machineName(ref.machineID)
            if match(ref.session + " " + mn) {
                out.append(Item(id: "s:" + ref.id, icon: "terminal", title: ref.session, subtitle: mn) {
                    state.selection = ref
                    state.showOverview = false
                    state.showArtifacts = false
                })
            }
        }
        // Every app command, with its shortcut as the trailing hint.
        let actions: [(String, String, String, () -> Void)] = [
            ("plus", "New Session…", "⌘N", { state.showNew = true }),
            ("magnifyingglass", "Find in Terminal", "⌘F", { state.showFind = true; state.findFocusToken &+= 1 }),
            ("sparkles", "Render Output", "⇧⌘M", {
                RenderLauncher.open(state: state, terminals: terminals)
            }),
            ("archivebox", "Open Artifacts", "⇧⌘I", {
                artifacts.openLibrary()
                state.presentArtifacts()
            }),
            ("pencil", "Rename Current Session…", "⇧⌘R",
             { if let s = state.selection { state.renameText = s.session; state.renameTarget = s } }),
            ("trash", "Kill Current Session…", "⌘⌫", { if let s = state.selection { state.killTarget = s } }),
            ("xmark.square", "Clear Terminal Buffer", "⌘K", { terminals.clearBuffer() }),
            ("arrow.down.to.line", "Scroll to Bottom", "⌘↓", { terminals.scrollToBottom() }),
            ("textformat.size.larger", "Increase Font Size", "⌘+", { terminals.adjustFont(1) }),
            ("textformat.size.smaller", "Decrease Font Size", "⌘−", { terminals.adjustFont(-1) }),
            ("textformat.size", "Reset Font Size", "⌘0", { terminals.resetFontSize() }),
            ("arrow.clockwise", "Refresh Sessions", "⌘R", { state.refreshAll() }),
            ("line.3.horizontal.decrease.circle", "Filter Sessions", "⌘L", { state.focusSearch() }),
            ("sidebar.leading", "Toggle Sidebar", "⌃⌘S", { state.toggleSidebar() }),
            (state.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer",
             state.keepAwake ? "Stop Keeping This Mac Awake" : "Keep This Mac Awake & Reachable While Locked",
             "", { state.keepAwake.toggle() }),
            (lab.unattendedMode ? "moon.fill" : "moon",
             lab.unattendedMode ? "Turn Off Unattended Mode" : "Turn On Unattended Mode",
             "Auto-approve Lab gates", { lab.setUnattendedMode(!lab.unattendedMode) }),
            // Window opens route through state: SwiftUI's openWindow action is
            // not available inside the AppKit palette panel's hosting view.
            ("folder", "Open Files", "", { state.openWindowRequest = "files" }),
            ("chart.line.uptrend.xyaxis", "Open Dashboards", "", { state.openWindowRequest = "dashboards" }),
            ("network", "Open Port Forwards", "", { state.openWindowRequest = "ports" }),
            ("sparkles", "Argus Wrapped", "", { state.openWindowRequest = "wrapped" }),
        ]
        for (ic, t, hint, a) in actions where match(t) {
            out.append(Item(id: "a:" + t, icon: ic, title: t, subtitle: hint, run: a))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
                TextField("Jump to a session or run a command…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit(run)
            }
            .padding(.horizontal, 14).frame(height: 46)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                            HStack(spacing: 10) {
                                Image(systemName: it.icon).font(.system(size: 12))
                                    .foregroundStyle(i == sel ? Theme.accent : Theme.textTertiary).frame(width: 16)
                                Text(it.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(it.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(i == sel ? Theme.accent.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                            // Identity is the item's own id (the ForEach id). A prior
                            // `.id(i)` (row index) fought that identity, so SwiftUI reused
                            // rows by position and kept STALE content when the filtered
                            // list changed — filtering (incl. commands) looked broken.
                            .onTapGesture { sel = i; run() }
                        }
                    }
                    .padding(8)
                }
                .frame(height: 360)
                .onChange(of: sel) { i in if i >= 0, i < items.count { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(items[i].id) } } }
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sidebarBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        // The palette lives in its OWN key window (PaletteWindow): the query
        // field is the only focusable view there, so typing cannot reach the
        // main window. Arrows/Esc still need the key monitor — the focused
        // field consumes arrows for caret movement.
        .onAppear { sel = 0; installKeys(); focusSoon() }
        .onDisappear { removeKeys() }
        .onChange(of: query) { _ in sel = 0 }
        .onExitCommand { close() }
    }

    private func focusSoon() {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    @State private var keyMonitor: Any?
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let n = items.count
            switch e.keyCode {
            case 125: if n > 0 { sel = (sel + 1) % n }; return nil          // ↓
            case 126: if n > 0 { sel = (sel - 1 + n) % n }; return nil      // ↑
            case 36, 76: run(); return nil                                  // ↩ / keypad-enter
            case 53: close(); return nil                                    // Esc
            default: return e
            }
        }
    }
    private func removeKeys() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func run() {
        let list = items
        guard sel >= 0, sel < list.count else { close(); return }
        list[sel].run()
        close()
    }
    private func close() { state.showPalette = false; query = "" }
}

// MARK: - Palette panel host (a real key window)

/// A borderless panel that CAN become key — while it is up, the main window
/// cannot receive keystrokes, so palette typing can never leak into the
/// sidebar filter or a terminal. This is how Spotlight-style palettes work.
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PaletteWindow: NSObject, NSWindowDelegate {
    static let shared = PaletteWindow()
    private var panel: PalettePanel?
    private var onDismiss: (() -> Void)?

    func show<V: View>(over main: NSWindow?, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> V) {
        hide()
        self.onDismiss = onDismiss
        let p = PalettePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.delegate = self
        let host = NSHostingView(rootView: content())
        p.contentView = host
        let size = NSSize(width: 560, height: 407) // card: 46 input + 1 divider + 360 list
        let mf = main?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        p.setFrame(NSRect(x: mf.midX - size.width / 2, y: mf.maxY - 110 - size.height,
                          width: size.width, height: size.height), display: false)
        main?.addChildWindow(p, ordered: .above)   // rides along if the window moves
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        onDismiss = nil
        p.delegate = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        p.contentView = nil   // tears down the hosting view → onDisappear → key monitor removed
    }

    /// Clicking anywhere else (or switching apps) dismisses — standard palette UX.
    func windowDidResignKey(_ notification: Notification) {
        onDismiss?()
    }
}

// MARK: - AppKit bridges

/// A hover-aware icon button (hover state lives in a real View, not a ButtonStyle).
struct IconButton: View {
    let system: String
    var size: CGFloat = 12
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hover ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Vibrant translucent backing for the sidebar.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Lets the off-screen test window stay parked off every display even while it
/// is key/active. AppKit normally calls `constrainFrameRect:toScreen:` on an
/// activated window and pulls it back on-screen — which would flash the hidden
/// test window into view the moment a keystroke makes it key. We swizzle the
/// base method process-wide but make it a NO-OP except for windows explicitly
/// flagged here, so ordinary user windows keep their normal clamping behavior.
private var utUnconstrainKey: UInt8 = 0
extension NSWindow {
    var utUnconstrained: Bool {
        get { (objc_getAssociatedObject(self, &utUnconstrainKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &utUnconstrainKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    @objc func ut_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if utUnconstrained { return frameRect }
        return ut_constrainFrameRect(frameRect, to: screen) // original impl after exchange
    }
}
enum WindowConstraintPatch {
    // Lazy static → Swift guarantees exactly-once, thread-safe initialization, so the
    // IMP exchange can never double-run (a double exchange would silently undo itself).
    private static let install: Void = {
        guard let orig = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))),
              let repl = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.ut_constrainFrameRect(_:to:)))
        else { return }
        method_exchangeImplementations(orig, repl)
    }()
    static func installOnce() { _ = install }
}

/// Configures the hosting NSWindow (hidden titlebar, dark aqua, min size,
/// maximize-on-first-launch) and reports fullscreen transitions for top-inset.
struct WindowAccessor: NSViewRepresentable {
    var onFullscreen: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFullscreen) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            NSApp.appearance = NSAppearance(named: Theme.current.isLight ? .aqua : .darkAqua)
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.identifier = ArgusWindowIdentity.main
            w.titleVisibility = .hidden
            w.title = ""
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarSeparatorStyle = .none
            w.toolbar = nil
            w.backgroundColor = Theme.nsAppBackground
            w.isMovableByWindowBackground = true
            w.isRestorable = false
            w.minSize = NSSize(width: 980, height: 600)
            context.coordinator.observe(w)
            // Test capture mode: park the window OFF-SCREEN on the ACTIVE space so it
            // can be screenshotted by window-ID (rendered, never visible to the user).
            // UT_TEST_OFFSCREEN=WxH (e.g. 1600x1000). Does not affect normal launches.
            let env = ProcessInfo.processInfo.environment
            let args = CommandLine.arguments
            var offscreenSpec = env["UT_TEST_OFFSCREEN"]
            if let i = args.firstIndex(of: "--offscreen"), i + 1 < args.count { offscreenSpec = args[i + 1] }
            if let spec = offscreenSpec {
                var width = 1600.0, height = 1000.0
                let p = spec.split(separator: "x")
                if p.count == 2, let a = Double(p[0]), let b = Double(p[1]) { width = a; height = b }
                // .canJoinAllSpaces keeps it on the active Space (backing store always
                // rendered → always capturable by window-ID); off-screen origin hides it.
                // The unconstrain patch stops AppKit pulling it on-screen when it becomes
                // key, so keyboard-driven UI tests run fully invisibly.
                WindowConstraintPatch.installOnce()
                w.utUnconstrained = true
                w.collectionBehavior.insert(.canJoinAllSpaces)
                w.setFrame(NSRect(x: 9000, y: 80, width: width, height: height), display: true)
            } else {
                // Open maximized on first launch; persist the user's size/position after.
                let autosave = "UTMainWindow"
                let hadSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosave)") != nil
                w.setFrameAutosaveName(autosave)
                if !hadSavedFrame, let visible = w.screen?.visibleFrame {
                    w.setFrame(visible, display: true)
                }
            }
            context.coordinator.onFullscreen(w.styleMask.contains(.fullScreen))
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        let onFullscreen: (Bool) -> Void
        init(_ cb: @escaping (Bool) -> Void) { onFullscreen = cb }
        func observe(_ w: NSWindow) {
            let nc = NotificationCenter.default
            nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: w, queue: .main) { [weak self] _ in
                self?.onFullscreen(true)
            }
            nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { [weak self] _ in
                self?.onFullscreen(false)
            }
        }
    }
}
