import SwiftUI

/// Todo Maps: a checklist per <machine, session> that outlives the session,
/// plus the permanent Misc board.
struct TodoMapsView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var fleet: FleetStore
    @AppStorage("argus.todos.showFinished") private var showFinished = false
    @State private var addingPanel = false
    @State private var editing: TodoEdit?
    @State private var editText = ""

    struct TodoEdit: Identifiable {
        let boardID: String
        let item: TodoItem
        var id: String { item.id }
    }

    var body: some View {
        List {
            WorkspaceSyncSection(key: .todos)
            ForEach(store.displayBoards(showFinished: showFinished)) { board in
                TodoBoardSection(board: board, live: store.liveSession(for: board)) { item in
                    editText = item.text
                    editing = TodoEdit(boardID: board.id, item: item)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Todo Maps")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showFinished.toggle() } label: {
                    Image(systemName: showFinished ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(showFinished ? "Hide finished panels" : "Show finished panels")
                Button { addingPanel = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New panel")
            }
        }
        .sheet(isPresented: $addingPanel) { NewTodoPanelSheet() }
        .alert("Edit task", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), presenting: editing) { edit in
            TextField("Task", text: $editText)
            Button("Save") { store.editTodo(edit.boardID, edit.item.id, text: editText) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct TodoBoardSection: View {
    let board: TodoBoard
    let live: (Machine, SessionInfo)?
    let onEdit: (TodoItem) -> Void
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var router: AppRouter
    @State private var newText = ""
    @State private var confirmDelete = false
    @FocusState private var adding: Bool

    var body: some View {
        Section {
            if board.items.isEmpty {
                Text("No tasks yet").foregroundStyle(.secondary)
            }
            ForEach(WorkspaceRules.sortedItems(board.items)) { item in
                TodoItemRow(item: item) { store.toggleTodo(board.id, item.id) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.deleteTodo(board.id, item.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { onEdit(item) } label: { Label("Edit", systemImage: "pencil") }
                    }
                    .contextMenu {
                        Button { onEdit(item) } label: { Label("Edit", systemImage: "pencil") }
                        Button { store.toggleTodo(board.id, item.id) } label: {
                            Label(item.done ? "Mark not done" : "Mark done", systemImage: item.done ? "circle" : "checkmark.circle")
                        }
                        Button(role: .destructive) { store.deleteTodo(board.id, item.id) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
            TextField("Add a task", text: $newText)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit {
                    guard !newText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    store.addTodo(board.id, newText)
                    newText = ""
                    adding = true   // keep the keyboard up for the next task
                }
        } header: {
            header
        }
        .confirmationDialog("Delete the \(board.session) panel and its \(board.items.count) tasks?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Panel", role: .destructive) { store.deleteBoard(board.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !board.isMisc {
                Circle()
                    .fill(live != nil ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(live != nil ? "Session running" : "Session not running")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(board.isMisc ? "Misc" : board.session)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !board.isMisc {
                    Text(board.machine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if board.pending > 0 {
                Text("\(board.pending)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
            Menu {
                if let (m, s) = live {
                    Button { router.openTerminal(m, s) } label: { Label("Open Session", systemImage: "terminal") }
                }
                if board.items.contains(where: \.done) {
                    Button { store.clearCompleted(board.id) } label: { Label("Clear Completed", systemImage: "checkmark.circle.badge.xmark") }
                }
                if !board.isMisc {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Panel", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").imageScale(.large)
            }
            .accessibilityLabel("Panel actions")
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

private struct TodoItemRow: View {
    let item: TodoItem
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")
            Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
        }
        .sensoryFeedback(.success, trigger: item.done) { _, done in done }
    }
}

/// Pick a running session, or name one that doesn't exist yet.
private struct NewTodoPanelSheet: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var fleet: FleetStore
    @Environment(\.dismiss) private var dismiss
    @State private var machine = ""
    @State private var session = ""

    private var running: [(Machine, SessionInfo)] {
        fleet.machines.flatMap { m in (fleet.allSessions[m.id] ?? []).filter(\.isForeground).map { (m, $0) } }
    }

    private func label(_ m: Machine) -> String { WorkspaceRules.machineLabel(for: m, syncHostID: fleet.syncHost?.id) }

    private func hasBoard(_ m: Machine, _ s: SessionInfo) -> Bool {
        store.todos.contains { !$0.isMisc && $0.machine == label(m) && $0.session == s.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !running.isEmpty {
                    Section("Running sessions") {
                        ForEach(running, id: \.1.id) { m, s in
                            Button {
                                store.ensureBoard(machine: label(m), session: s.name)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(s.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text(m.name).font(.caption).foregroundStyle(.secondary)
                                    if hasBoard(m, s) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("Machine", text: $machine)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(store.machineSuggestions, id: \.self) { s in
                                Button(s) { machine = s }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    TextField("Session name", text: $session)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(running.isEmpty ? "Session" : "Or a future session")
                } footer: {
                    Text("A panel keeps its tasks when the session ends; reopen a session with the same name on the same machine to see them again.")
                }
            }
            .navigationTitle("New Todo Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { store.ensureBoard(machine: machine, session: session); dismiss() }
                        .disabled(machine.trimmingCharacters(in: .whitespaces).isEmpty || session.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
