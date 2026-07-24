import SwiftUI

/// The ⇧⌘W "Workflows" panel: saved recipes (machine + folder + command sequence),
/// grouped by machine like the command center. Click a card to run it, the pencil to
/// edit, + to add.
struct WorkflowsView: View {
    @EnvironmentObject var state: AppState
    @State private var editing: WorkflowEdit?

    private var groups: [(machine: String, items: [Workflow])] {
        Dictionary(grouping: state.workflows, by: { $0.machine })
            .map { (machine: $0.key, items: $0.value) }
            .sorted { $0.machine.lowercased() < $1.machine.lowercased() }
    }

    private func newDraft() -> WorkflowEdit {
        WorkflowEdit(workflow: Workflow(name: "", machine: "", folder: "", commands: ""), isNew: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.textSecondary)
                Text("Workflows").font(.system(size: 15, weight: .semibold))
                if !state.workflows.isEmpty {
                    Text("\(state.workflows.count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.surface))
                }
                Spacer()
                Button { editing = newDraft() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New workflow")
                Button("Done") { state.showWorkflows = false }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if state.workflows.isEmpty { emptyState } else { list }
        }
        .frame(width: 640, height: 580)
        .background(Theme.appBackground)
        .sheet(item: $editing) { e in
            WorkflowFormView(
                state: state, draft: e.workflow, isNew: e.isNew,
                onSave: { state.upsertWorkflow($0); editing = nil },
                onDelete: e.isNew ? nil : { state.deleteWorkflow($0); editing = nil },
                onCancel: { editing = nil })
        }
        .alert("Workflow", isPresented: Binding(
            get: { state.workflowError != nil }, set: { if !$0 { state.workflowError = nil } })) {
            Button("OK") { state.workflowError = nil }
        } message: { Text(state.workflowError ?? "") }
        .confirmationDialog(
            "Run on which machine?",
            isPresented: Binding(get: { state.workflowPick != nil }, set: { if !$0 { state.workflowPick = nil } }),
            presenting: state.workflowPick
        ) { pick in
            ForEach(pick.machines) { m in Button(m.name) { state.runWorkflow(pick.workflow, on: m) } }
            Button("Cancel", role: .cancel) { state.workflowPick = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
            Text("No workflows yet").foregroundStyle(Theme.textSecondary)
            Text("Add one with + — a name, a machine (e.g. babel-*), a folder, and the commands to run.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("New Workflow") { editing = newDraft() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.machine) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.machine.isEmpty ? "—" : group.machine)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 10)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(group.items) { wf in
                                WorkflowCard(wf: wf,
                                             onRun: { state.runWorkflow(wf) },
                                             onEdit: { editing = WorkflowEdit(workflow: wf, isNew: false) })
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct WorkflowEdit: Identifiable {
    let id = UUID()
    var workflow: Workflow
    var isNew: Bool
}

/// One workflow tile — name + optional notes + folder. Click anywhere to run; the
/// pencil (on hover) edits without triggering the run.
private struct WorkflowCard: View {
    let wf: Workflow
    let onRun: () -> Void
    let onEdit: () -> Void
    @State private var hover = false

    private var accent: Color { wf.colorHex.isEmpty ? Theme.accent : Color(hex: wf.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(wf.name.isEmpty ? "(unnamed)" : wf.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).opacity(hover ? 1 : 0)
                    .help("Edit")
            }
            if !wf.notes.isEmpty {
                Text(wf.notes).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            if !wf.folder.isEmpty {
                Text(wf.folder).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? accent.opacity(0.12) : Theme.surface.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent.opacity(hover ? 0.5 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onRun() }
        .help("Run “\(wf.name)” on \(wf.machine.isEmpty ? "?" : wf.machine)")
    }
}

/// Add / edit form — clear top-labelled fields, a machine dropdown (This Mac / online
/// hosts / derived patterns) over an editable pattern, a real folder Browse, a monospace
/// commands editor, plus optional notes and a color tag.
private struct WorkflowFormView: View {
    @ObservedObject var state: AppState
    @State var draft: Workflow
    let isNew: Bool
    let onSave: (Workflow) -> Void
    let onDelete: ((Workflow) -> Void)?
    let onCancel: () -> Void

    @State private var browsing = false
    private let swatches = ["", "#E5484D", "#F5A623", "#30A46C", "#3B82F6", "#8B5CF6", "#EC4899"]

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.machine.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var knownHosts: [String] { state.machines.filter { !$0.isLocal }.map { $0.name }.sorted() }
    private var derivedPatterns: [String] {
        var s = Set<String>()
        for h in knownHosts { if let d = h.firstIndex(of: "-") { s.insert(String(h[..<d]) + "-*") } }
        return s.sorted()
    }
    private var browseTarget: Machine? { state.machinesMatching(draft.machine).first }

    private let commandPresets = [
        "claude --dangerously-skip-permissions",
        "claude --dangerously-skip-permissions --resume ",
        "codex",
    ]
    /// Commands you can drop in: the distinct ones from your other workflows (so a command
    /// you use a lot is one click away), then a few common presets not already there.
    private var commandSuggestions: [String] {
        var seen = Set<String>(); var out: [String] = []
        func add(_ raw: String) {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key); out.append(raw)
        }
        for w in state.workflows where w.id != draft.id { add(w.commands) }
        for p in commandPresets { add(p) }
        return out
    }
    private func commandLabel(_ c: String) -> String {
        let first = (c.split(separator: "\n").first.map(String.init) ?? c).trimmingCharacters(in: .whitespaces)
        return first.count > 52 ? String(first.prefix(52)) + "…" : first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Workflow" : "Edit Workflow")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    LabeledField(label: "Name") {
                        TextField("e.g. website", text: $draft.name).textFieldStyle(.roundedBorder)
                    }
                    LabeledField(label: "Machine",
                                 hint: "Wildcards — babel-* matches any babel node. The session is named after the workflow.") {
                        HStack(spacing: 6) {
                            TextField("babel-*  ·  this mac", text: $draft.machine).textFieldStyle(.roundedBorder)
                            machineMenu
                        }
                    }
                    LabeledField(label: "Folder",
                                 hint: "Where the session starts. ~ is expanded on the target machine.") {
                        HStack(spacing: 6) {
                            TextField("~/scratch", text: $draft.folder).textFieldStyle(.roundedBorder)
                            Button("Browse…") { browsing = true }
                                .disabled(browseTarget == nil)
                                .help(browseTarget == nil
                                      ? "Connect a machine matching this pattern to browse"
                                      : "Browse folders on \(browseTarget!.name)")
                        }
                    }
                    LabeledField(label: "Commands",
                                 hint: "One per line, typed in after the session starts.") {
                        VStack(alignment: .leading, spacing: 5) {
                            if !commandSuggestions.isEmpty {
                                Menu {
                                    ForEach(commandSuggestions, id: \.self) { c in
                                        Button(commandLabel(c)) { draft.commands = c }
                                    }
                                } label: {
                                    Label("Use a command", systemImage: "text.append").font(.system(size: 11))
                                }
                                .menuStyle(.borderlessButton).fixedSize()
                                .help("Drop in a command from another workflow, or a common one")
                            }
                            TextEditor(text: $draft.commands)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(height: 116).padding(6).scrollContentBackground(.hidden)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface.opacity(0.5)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                        }
                    }
                    LabeledField(label: "Notes", hint: "Optional.") {
                        TextField("what this workflow is for", text: $draft.notes).textFieldStyle(.roundedBorder)
                    }
                    LabeledField(label: "Color", hint: "Optional accent on the card.") {
                        HStack(spacing: 9) {
                            ForEach(swatches, id: \.self) { hex in
                                Circle().fill(hex.isEmpty ? Color.gray.opacity(0.3) : Color(hex: hex))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: draft.colorHex == hex ? 2.5 : 0))
                                    .overlay(hex.isEmpty ? Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) : nil)
                                    .contentShape(Circle())
                                    .onTapGesture { draft.colorHex = hex }
                            }
                            Spacer()
                        }
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                if let onDelete { Button("Delete", role: .destructive) { onDelete(draft) } }
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction).disabled(!canSave).buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 500, height: 640)
        .background(Theme.appBackground)
        .sheet(isPresented: $browsing) {
            if let m = browseTarget {
                FolderPickerView(httpBase: m.httpBase, machineName: m.name, initial: draft.folder,
                                 onPick: { draft.folder = $0; browsing = false },
                                 onCancel: { browsing = false })
            }
        }
    }

    private var machineMenu: some View {
        Menu {
            Button("This Mac") { draft.machine = "this mac" }
            if !knownHosts.isEmpty {
                Divider()
                ForEach(knownHosts, id: \.self) { h in Button(h) { draft.machine = h } }
            }
            if !derivedPatterns.isEmpty {
                Divider()
                ForEach(derivedPatterns, id: \.self) { p in Button("Any \(p)") { draft.machine = p } }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton).fixedSize().help("Pick a known machine or pattern")
    }
}

/// A label + hint wrapper for a form field.
private struct LabeledField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            content()
            if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A folder picker that browses any machine's filesystem through its broker (`/fs/home`
/// + `/fs/list`) — so it works for the Mac and a cluster node alike. Returns the choice
/// as a `~`-relative path when it's under the machine's home, so a workflow stays portable
/// across nodes that share a home (e.g. an NFS cluster).
private struct FolderPickerView: View {
    let httpBase: String
    let machineName: String
    let initial: String
    let onPick: (String) -> Void
    let onCancel: () -> Void

    @State private var home = ""
    @State private var sep = "/"
    @State private var path = ""
    @State private var dirs: [WFEntry] = []
    @State private var loading = true
    @State private var error: String?

    private struct WFListResp: Decodable { let path: String; let entries: [WFEntry] }
    private struct WFHomeResp: Decodable { let home: String; let sep: String }

    private var displayPath: String {
        if !home.isEmpty, path == home || path.hasPrefix(home + sep) {
            let rest = String(path.dropFirst(home.count))
            return rest.isEmpty ? "~" : "~" + rest
        }
        return path.isEmpty ? sep : path
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                Text(machineName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            HStack(spacing: 6) {
                Button { Task { await up() } } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless).disabled(loading || path.isEmpty || path == sep)
                Text(displayPath).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.textTertiary)
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(dirs, id: \.path) { d in
                                Button { Task { await go(d.path) } } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.accent.opacity(0.85))
                                        Text(d.name).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if dirs.isEmpty {
                                Text("No subfolders here").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(20)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Choose This Folder") { onPick(displayPath) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(loading)
            }
            .padding(12)
        }
        .frame(width: 460, height: 470)
        .background(Theme.appBackground)
        .task { await start() }
    }

    private func start() async {
        if let url = URL(string: httpBase + "/fs/home"), let h: WFHomeResp = await get(url) {
            home = h.home
            sep = h.sep.isEmpty ? "/" : h.sep
        }
        await go(resolveInitial())
    }
    private func resolveInitial() -> String {
        let f = initial.trimmingCharacters(in: .whitespaces)
        if f.isEmpty || f == "~" { return home }
        if f.hasPrefix("~/") { return home + sep + String(f.dropFirst(2)) }
        if f.hasPrefix("/") || (f.count > 1 && f[f.index(f.startIndex, offsetBy: 1)] == ":") { return f } // absolute (unix / windows)
        return home
    }
    private func go(_ p: String) async {
        loading = true; error = nil
        if let url = listURL(p), let resp: WFListResp = await get(url) {
            path = resp.path
            dirs = resp.entries.filter { $0.isDir }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        } else {
            error = "Couldn’t read that folder."
        }
        loading = false
    }
    private func up() async {
        guard !path.isEmpty, path != sep else { return }
        let t = path.hasSuffix(sep) ? String(path.dropLast()) : path
        if let r = t.range(of: sep, options: .backwards) {
            let parent = String(t[..<r.lowerBound])
            await go(parent.isEmpty ? sep : parent)
        }
    }
    private func listURL(_ p: String) -> URL? {
        guard var c = URLComponents(string: httpBase + "/fs/list") else { return nil }
        c.queryItems = [URLQueryItem(name: "path", value: p)]
        return c.url
    }
    private func get<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url); req.timeoutInterval = 10
        guard let (d, _) = try? await brokerSession.data(for: req) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}

/// Minimal directory entry for the folder picker (subset of the /fs/list payload).
private struct WFEntry: Decodable, Hashable {
    let name: String
    let path: String
    let isDir: Bool
}
