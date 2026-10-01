import SwiftUI

/// Workflows: saved session recipes (machine pattern, folder, commands). Tap to
/// run: the session is named after the workflow and opened if it's already up.
struct WorkflowsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var editor: Editor?
    @State private var pick: Pick?
    @State private var message: String?
    @State private var running: String?
    @State private var launches = 0

    struct Editor: Identifiable {
        let workflow: WorkspaceWorkflow
        let isNew: Bool
        var id: String { workflow.id }
    }

    struct Pick: Identifiable {
        let workflow: WorkspaceWorkflow
        let machines: [Machine]
        var id: String { workflow.id }
    }

    private var groups: [(String, [WorkspaceWorkflow])] {
        Dictionary(grouping: store.workflows, by: \.machine)
            .map { ($0.key, $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        list
            .navigationTitle("Workflows")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = Editor(workflow: WorkspaceWorkflow(), isNew: true) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New workflow")
                }
            }
            .sheet(item: $editor) { WorkflowEditor(workflow: $0.workflow, isNew: $0.isNew) }
            .confirmationDialog("Run on which machine?", isPresented: isPicking, titleVisibility: .visible, presenting: pick) { p in
                ForEach(p.machines) { m in Button(m.name) { start(p.workflow, on: m) } }
            }
            .alert("Workflow", isPresented: hasMessage) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
            .alert("Workflow", isPresented: hasRunError) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.runError ?? "") }
            .sensoryFeedback(.impact, trigger: launches)
    }

    private var list: some View {
        List {
            WorkspaceSyncSection(key: .workflows)
            ForEach(groups, id: \.0) { machine, workflows in
                Section(machine.isEmpty ? "—" : machine) {
                    ForEach(workflows) { wf in row(wf) }
                }
            }
        }
        .overlay {
            if store.workflows.isEmpty {
                ContentUnavailableView("No workflows yet", systemImage: "play.rectangle",
                                       description: Text("Tap + to save a session recipe: a machine, a folder and the commands to type."))
            }
        }
    }

    private func row(_ wf: WorkspaceWorkflow) -> some View {
        WorkflowRow(workflow: wf, running: running == wf.id, run: { run(wf) }, edit: { edit(wf) })
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { store.deleteWorkflow(wf.id) } label: { Label("Delete", systemImage: "trash") }
                Button { edit(wf) } label: { Label("Edit", systemImage: "pencil") }
            }
            .contextMenu {
                Button { run(wf) } label: { Label("Run", systemImage: "play") }
                Button { edit(wf) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { store.deleteWorkflow(wf.id) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private var isPicking: Binding<Bool> { Binding(get: { pick != nil }, set: { if !$0 { pick = nil } }) }
    private var hasMessage: Binding<Bool> { Binding(get: { message != nil }, set: { if !$0 { message = nil } }) }
    private var hasRunError: Binding<Bool> { Binding(get: { store.runError != nil }, set: { if !$0 { store.runError = nil } }) }

    private func edit(_ wf: WorkspaceWorkflow) { editor = Editor(workflow: wf, isNew: false) }

    private func run(_ wf: WorkspaceWorkflow) {
        let machines = store.machines(for: wf)
        switch machines.count {
        case 0: message = "No reachable machine matches “\(wf.machine)”."
        case 1: start(wf, on: machines[0])
        default: pick = Pick(workflow: wf, machines: machines)
        }
    }

    private func start(_ wf: WorkspaceWorkflow, on m: Machine) {
        guard running == nil else { return }
        running = wf.id
        launches += 1
        Task {
            do { try await store.run(wf, on: m) } catch { message = error.localizedDescription }
            running = nil
        }
    }
}

private struct WorkflowRow: View {
    let workflow: WorkspaceWorkflow
    let running: Bool
    let run: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(WorkspaceSwatch.color(workflow.colorHex) ?? .accentColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name.isEmpty ? "(unnamed)" : workflow.name).font(.body.weight(.semibold))
                if !workflow.folder.isEmpty {
                    Text(workflow.folder).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if !workflow.notes.isEmpty {
                    Text(workflow.notes).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            Spacer()
            Button(action: edit) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(workflow.name)")
            if running {
                ProgressView()
            } else {
                Image(systemName: "play.fill").foregroundStyle(WorkspaceSwatch.color(workflow.colorHex) ?? .accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: run)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Runs the workflow")
    }
}

enum WorkspaceSwatch {
    static func color(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

private struct WorkflowEditor: View {
    let isNew: Bool
    @State private var wf: WorkspaceWorkflow
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(workflow: WorkspaceWorkflow, isNew: Bool) {
        self.isNew = isNew
        _wf = State(initialValue: workflow)
    }

    private var trimmedName: String { wf.name.trimmingCharacters(in: .whitespaces) }
    private var trimmedMachine: String { wf.machine.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $wf.name)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The session is named after the workflow; if it's already running, it just opens.")
                }
                Section {
                    TextField("babel-* or this mac", text: $wf.machine)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(store.machineSuggestions, id: \.self) { s in
                                Button(s) { wf.machine = s }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Machine")
                } footer: {
                    let matches = store.machines(for: wf).map(\.name)
                    Text(trimmedMachine.isEmpty ? "A name, a pattern with * wildcards, or “this mac”."
                         : matches.isEmpty ? "No reachable machine matches right now."
                         : "Matches: " + matches.joined(separator: ", "))
                }
                Section("Folder") {
                    TextField("~/scratch", text: $wf.folder)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Commands, one per line") {
                    TextField("git pull", text: $wf.commands, axis: .vertical)
                        .lineLimit(3...12)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Notes") {
                    TextField("Optional", text: $wf.notes, axis: .vertical)
                }
                Section("Color") {
                    HStack(spacing: 14) {
                        ForEach(WorkspaceRules.swatches, id: \.self) { hex in
                            Button { wf.colorHex = hex } label: {
                                Circle()
                                    .fill(WorkspaceSwatch.color(hex) ?? Color.secondary.opacity(0.35))
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if wf.colorHex == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                                    }
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(hex.isEmpty ? "Default color" : hex)
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Workflow", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New Workflow" : "Edit Workflow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        var saved = wf
                        saved.name = trimmedName
                        saved.machine = trimmedMachine
                        store.saveWorkflow(saved)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty || trimmedMachine.isEmpty)
                }
            }
            .confirmationDialog("Delete “\(wf.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Workflow", role: .destructive) { store.deleteWorkflow(wf.id); dismiss() }
            }
        }
    }
}
