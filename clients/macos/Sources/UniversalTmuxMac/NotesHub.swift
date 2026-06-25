import AppKit
import SwiftUI

/// The ⇧⌘N "Notes" hub: a full main-pane panel of free-form notes — multiline, optionally
/// checkable, not tied to any machine or session. Grouped into time buckets by last edit,
/// newest first.
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
        let by = Dictionary(grouping: state.notes, by: { bucket($0.editedAt) })
        return (0..<5).compactMap { b in
            guard let ns = by[b], !ns.isEmpty else { return nil }
            return (labels[b], ns.sorted { $0.editedAt > $1.editedAt })   // newest edit first
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.bottom, 24).padding(.top, 34)
        }
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
    @State private var height: CGFloat = 22
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
            .buttonStyle(.plain).padding(.top, 2)

            if note.done {
                Text(note.text.isEmpty ? "(empty)" : note.text)
                    .font(cf(15)).foregroundStyle(Theme.textTertiary)
                    .strikethrough(true, color: Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a note…").font(cf(15)).foregroundStyle(Theme.textTertiary)
                    }
                    NoteEditor(text: $text, height: $height, fontSize: 15 * uiScale,
                               color: NSColor(Theme.textPrimary), isFocused: focused == note.id)
                        .frame(height: max(22, height))
                        // Only a REAL edit (text diverged from the model) bumps editedAt.
                        // The .onAppear sync below sets `text = note.text`, which also fires
                        // this onChange — without the guard, just OPENING the panel re-stamped
                        // every note's editedAt to now (jumping old notes to "Today").
                        .onChange(of: text) { v in if v != note.text { state.updateNoteText(note.id, v) } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Button { state.deleteNote(note.id) } label: { Image(systemName: "xmark").font(cf(11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).opacity(hover ? 1 : 0)
                Text(timeLabel(note.editedAt)).font(cf(10)).foregroundStyle(Theme.textTertiary.opacity(0.7)).fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .onHover { hover = $0 }
        .onAppear { if text != note.text { text = note.text } }
    }
}

/// An auto-growing plain-text editor backed by NSTextView — so Enter inserts a newline
/// (true multiline) and the field grows to fit its content. SwiftUI's TextField/TextEditor
/// don't give both on macOS.
private struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var fontSize: CGFloat
    var color: NSColor
    var isFocused: Bool

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = color
        tv.insertionPointColor = color
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.string != text { tv.string = text }
        if tv.font?.pointSize != fontSize { tv.font = .systemFont(ofSize: fontSize) }
        tv.textColor = color
        DispatchQueue.main.async {
            Self.recalc(tv, $height)
            if isFocused, tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        }
    }

    static func recalc(_ tv: NSTextView, _ height: Binding<CGFloat>) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = max(20, lm.usedRect(for: tc).height)
        if abs(height.wrappedValue - h) > 0.5 { height.wrappedValue = h }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NoteEditor
        init(_ p: NoteEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            DispatchQueue.main.async { NoteEditor.recalc(tv, self.parent.$height) }
        }
    }
}
