import SwiftUI

/// The ⇧⌘N "Notes" hub: a full main-pane panel (like the command center / Todo Maps) of
/// free-form notes — multiline, optionally checkable, not tied to any machine or session.
/// Grouped into time buckets, newest first.
struct NotesHubView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @FocusState private var focusedNote: UUID?

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    private var groups: [(label: String, notes: [Note])] {
        let now = Date(); let cal = Calendar.current
        func bucket(_ d: Date) -> Int {
            if cal.isDateInToday(d) { return 0 }
            if cal.isDateInYesterday(d) { return 1 }
            if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) { return 2 }
            if cal.isDate(d, equalTo: now, toGranularity: .month) { return 3 }
            return 4
        }
        let labels = ["Today", "Yesterday", "Earlier this week", "This month", "Earlier"]
        let by = Dictionary(grouping: state.notes, by: { bucket($0.createdAt) })
        return (0..<5).compactMap { b in
            guard let ns = by[b], !ns.isEmpty else { return nil }
            return (labels[b], ns.sorted { $0.createdAt > $1.createdAt })   // newest first
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(group.label).font(cf(12, .semibold)).foregroundStyle(Theme.textTertiary)
                        ForEach(group.notes) { note in NoteRow(note: note, focused: $focusedNote) }
                    }
                }
                if state.notes.isEmpty {
                    Text("No notes yet. Tap + to write one.").font(cf(14)).foregroundStyle(Theme.textTertiary).padding(.top, 50)
                }
            }
            .frame(maxWidth: 780, alignment: .leading)   // a comfortable reading column
            .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 34)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.appBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text").font(cf(20)).foregroundStyle(Theme.textSecondary)
            Text("Notes").font(cf(21, .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { focusedNote = state.addNote() } label: { Label("New note", systemImage: "plus").font(cf(13)) }
                .buttonStyle(.borderless)
            Button { state.showNotes = false } label: { Image(systemName: "xmark").font(cf(15)) }
                .buttonStyle(.borderless).help("Close (⇧⌘N)")
        }
    }
}

private struct NoteRow: View {
    let note: Note
    @FocusState.Binding var focused: UUID?
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var text = ""
    @State private var hover = false

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }
    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d · h:mm a"; return f.string(from: d)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button { state.toggleNote(note.id) } label: {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .font(cf(16)).foregroundStyle(note.done ? Theme.running : Theme.textTertiary)
            }
            .buttonStyle(.plain).padding(.top, 1)

            if note.done {
                Text(note.text.isEmpty ? "(empty)" : note.text)
                    .font(cf(15)).foregroundStyle(Theme.textTertiary)
                    .strikethrough(true, color: Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Write a note…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(cf(15)).foregroundStyle(Theme.textPrimary)
                    .focused($focused, equals: note.id)
                    .onChange(of: text) { v in state.updateNoteText(note.id, v) }
            }

            VStack(alignment: .trailing, spacing: 4) {
                Button { state.deleteNote(note.id) } label: { Image(systemName: "xmark").font(cf(11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).opacity(hover ? 1 : 0)
                Text(timeLabel(note.createdAt)).font(cf(10)).foregroundStyle(Theme.textTertiary.opacity(0.7))
                    .fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .onHover { hover = $0 }
        .onAppear { if text != note.text { text = note.text } }
    }
}
