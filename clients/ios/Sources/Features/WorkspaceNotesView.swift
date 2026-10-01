import SwiftUI

/// Notes Hub: free-form notes grouped by when they were last edited.
struct NotesView: View {
    @EnvironmentObject var store: WorkspaceStore
    @State private var search = ""
    @FocusState private var focused: String?
    /// Layout captured when editing starts, so the note being typed in (whose
    /// `editedAt` keeps moving) doesn't jump around under the cursor.
    @State private var frozen: [String: (bucket: WorkspaceRules.NoteBucket, rank: Int)]?
    /// Notes added here and not typed in yet: dropped again if left empty.
    @State private var fresh: Set<String> = []

    private var visible: [WorkspaceNote] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.notes : store.notes.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var groups: [(WorkspaceRules.NoteBucket, [WorkspaceNote])] {
        guard let frozen else { return WorkspaceRules.groupedNotes(visible, now: Date()) }
        let placed = visible.map { n in (frozen[n.id] ?? (.today, -1), n) }
        return WorkspaceRules.NoteBucket.allCases.compactMap { b in
            let ns = placed.filter { $0.0.bucket == b }
                .sorted { $0.0.rank != $1.0.rank ? $0.0.rank < $1.0.rank : $0.1.editedAt > $1.1.editedAt }
                .map(\.1)
            return ns.isEmpty ? nil : (b, ns)
        }
    }

    var body: some View {
        List {
            WorkspaceSyncSection(key: .notes)
            ForEach(groups, id: \.0) { bucket, notes in
                Section(bucket.title) {
                    ForEach(notes) { note in
                        NoteRow(note: note, focused: $focused)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.deleteNote(note.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button { store.toggleNote(note.id) } label: {
                                    Label(note.done ? "Reopen" : "Done", systemImage: note.done ? "arrow.uturn.backward" : "checkmark")
                                }
                                .tint(.green)
                            }
                    }
                }
            }
        }
        .overlay {
            if store.notes.isEmpty {
                ContentUnavailableView("No notes yet", systemImage: "note.text", description: Text("Tap + to write one."))
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search notes")
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newNote() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New note")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = nil }
            }
        }
        .onChange(of: focused) { old, new in
            if let old, old != new, fresh.remove(old) != nil,
               store.notes.first(where: { $0.id == old })?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                store.deleteNote(old)
            }
            if new == nil { frozen = nil } else if frozen == nil { freeze() }
        }
    }

    private func newNote() {
        search = ""
        let id = store.addNote()
        fresh.insert(id)
        freeze()
        frozen?[id] = (.today, -1)
        focused = id
    }

    private func freeze() {
        var snapshot: [String: (bucket: WorkspaceRules.NoteBucket, rank: Int)] = [:]
        var rank = 0
        for (bucket, notes) in WorkspaceRules.groupedNotes(store.notes, now: Date()) {
            for n in notes { snapshot[n.id] = (bucket, rank); rank += 1 }
        }
        frozen = snapshot
    }
}

private struct NoteRow: View {
    let note: WorkspaceNote
    var focused: FocusState<String?>.Binding
    @EnvironmentObject var store: WorkspaceStore

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { store.toggleNote(note.id) } label: {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(note.done ? Color.green : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(note.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 4) {
                if note.done {
                    Text(note.text.isEmpty ? "(empty)" : note.text)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Write a note…", text: Binding(get: { note.text }, set: { store.updateNoteText(note.id, $0) }),
                              axis: .vertical)
                        .focused(focused, equals: note.id)
                }
                Text(note.editedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .sensoryFeedback(.selection, trigger: note.done)
    }
}
