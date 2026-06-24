import SwiftUI

/// The ⇧⌘D "Todo Maps" panel: per-session checklists laid out like the command center,
/// big tiles and large type. One tile per board (Misc first, then session boards), a live
/// dot when the session is running. Boards persist independently of the session.
struct TodoCenterView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var showFinished = false
    @State private var adding = false

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    private var boards: [TodoBoard] {
        let misc = state.todoBoards.filter { $0.isMisc }
        var sessions = state.todoBoards.filter { !$0.isMisc }
        if !showFinished {
            // Hide only FINISHED panels — those whose tasks all exist and are all done.
            // New/empty panels still show (so you can fill them), as do any with pending
            // tasks. Live-vs-dead affects only the sort below, not visibility. "Show
            // finished" reveals the done ones again.
            sessions = sessions.filter { $0.items.isEmpty || $0.pending > 0 }
        }
        sessions.sort { a, b in
            let la = state.isSessionLive(a), lb = state.isSessionLive(b)
            if la != lb { return la }                       // live sessions first
            return a.session.lowercased() < b.session.lowercased()
        }
        return misc + sessions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(boards) { TodoBoardTile(board: $0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .padding(.top, 34)   // clear the window's title/traffic-light zone
        }
        .background(Theme.appBackground)
        .sheet(isPresented: $adding) { TodoAddBoardView().environmentObject(state) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").font(cf(20)).foregroundStyle(Theme.textSecondary)
            Text("Todo Maps").font(cf(21, .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("Show finished", isOn: $showFinished).toggleStyle(.switch).font(cf(12))
                .help("Also show panels whose tasks are all completed")
            Button { adding = true } label: { Label("New panel", systemImage: "plus").font(cf(13)) }
                .buttonStyle(.borderless)
            Button { state.showTodos = false } label: { Image(systemName: "xmark").font(cf(15)) }
                .buttonStyle(.borderless).help("Close (⇧⌘D)")
        }
    }
}

/// One board tile — header (machine · session + live dot), the checklist, and an add field.
private struct TodoBoardTile: View {
    let board: TodoBoard
    @EnvironmentObject var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var newText = ""

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    private var live: Bool { state.isSessionLive(board) }
    private var sortedItems: [TodoItem] {
        board.items.sorted { a, b in
            if a.done != b.done { return !a.done }                                   // pending first
            if a.done { return (a.completedAt ?? a.createdAt) > (b.completedAt ?? b.createdAt) }  // recent done first
            return a.createdAt < b.createdAt                                          // oldest pending first
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                ForEach(sortedItems) { item in
                    TodoRow(item: item,
                            onToggle: { state.toggleTodo(board.id, item.id) },
                            onDelete: { state.deleteTodo(board.id, item.id) })
                }
                if board.items.isEmpty {
                    Text("No tasks yet").font(cf(13)).foregroundStyle(Theme.textTertiary).padding(.vertical, 2)
                }
            }
            addField
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 13).fill(Theme.surface.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if board.isMisc {
                Image(systemName: "tray.full").font(cf(16)).foregroundStyle(Theme.accent)
                Text("Misc").font(cf(18, .semibold)).foregroundStyle(Theme.textPrimary)
            } else {
                Circle().fill(live ? Theme.running : Theme.textTertiary.opacity(0.5)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(board.session).font(cf(18, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(board.machine).font(cf(12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            if board.pending > 0 {
                Text("\(board.pending)").font(cf(13, .semibold)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.surface))
            }
            Menu {
                if live { Button("Open session") { state.openBoardSession(board) } }
                if board.items.contains(where: { $0.done }) {
                    Button("Clear completed") { for i in board.items where i.done { state.deleteTodo(board.id, i.id) } }
                }
                if !board.isMisc { Button("Delete panel", role: .destructive) { state.deleteBoard(board.id) } }
            } label: {
                Image(systemName: "ellipsis").font(cf(15))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private var addField: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle").font(cf(16)).foregroundStyle(Theme.textTertiary)
            TextField("Add a task", text: $newText)
                .textFieldStyle(.plain).font(cf(15)).onSubmit(add)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5)))
    }

    private func add() { state.addTodo(board.id, newText); newText = "" }
}

private struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var hover = false

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }
    private func when(_ d: Date) -> String { absoluteTime(Int64(d.timeIntervalSince1970)) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(cf(17)).foregroundStyle(item.done ? Theme.running : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            Text(item.text).font(cf(15))
                .foregroundStyle(item.done ? Theme.textTertiary : Theme.textPrimary)
                .strikethrough(item.done, color: Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if hover {
                Button(action: onDelete) { Image(systemName: "xmark").font(cf(12)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
            }
        }
        .help(item.done ? "Completed \(when(item.completedAt ?? item.createdAt))  ·  added \(when(item.createdAt))"
                        : "Added \(when(item.createdAt))")
        .onHover { hover = $0 }
    }
}

/// New-panel sheet: pick a running session, or type a machine + session for a future one.
struct TodoAddBoardView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var machine = ""
    @State private var session = ""

    private func cf(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: s * uiScale, weight: w) }

    private var liveSessions: [(machine: String, session: String)] {
        state.machines.flatMap { m in
            (state.sessionsByMachine[m.id] ?? []).filter { !$0.agent }.map { (machine: m.name, session: $0.name) }
        }
        .sorted { ($0.machine + $0.session).lowercased() < ($1.machine + $1.session).lowercased() }
    }
    private var knownHosts: [String] { state.machines.map { $0.name }.sorted() }
    private var sessionsOnMachine: [String] {
        let m = machine.trimmingCharacters(in: .whitespaces).lowercased()
        return state.machines.filter { $0.name.lowercased() == m }
            .flatMap { state.sessionsByMachine[$0.id] ?? [] }.filter { !$0.agent }.map { $0.name }.sorted()
    }
    private var canAdd: Bool {
        !machine.trimmingCharacters(in: .whitespaces).isEmpty && !session.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Todo Panel").font(cf(17, .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 16) {
                if !liveSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pick a running session").font(cf(12, .semibold)).foregroundStyle(Theme.textSecondary)
                        Menu {
                            ForEach(liveSessions.indices, id: \.self) { i in
                                let s = liveSessions[i]
                                Button("\(s.session)   ·   \(s.machine)") { machine = s.machine; session = s.session }
                            }
                        } label: {
                            HStack {
                                Text(canAdd ? "\(session)  ·  \(machine)" : "Choose a session…").font(cf(14))
                                Spacer(); Image(systemName: "chevron.down").font(cf(11))
                            }
                            .padding(9).background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.5)))
                        }
                        .menuStyle(.borderlessButton)
                    }
                    HStack { VStack { Divider() }; Text("or type a future one").font(cf(11)).foregroundStyle(Theme.textTertiary); VStack { Divider() } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Machine").font(cf(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        TextField("babel-o9-32  ·  this mac", text: $machine).textFieldStyle(.roundedBorder).font(cf(14))
                        Menu {
                            ForEach(knownHosts, id: \.self) { h in Button(h) { machine = h } }
                        } label: { Image(systemName: "chevron.down").font(cf(11, .semibold)) }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Session name").font(cf(12, .semibold)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 6) {
                        TextField("vlm_gating", text: $session).textFieldStyle(.roundedBorder).font(cf(14))
                        if !sessionsOnMachine.isEmpty {
                            Menu {
                                ForEach(sessionsOnMachine, id: \.self) { s in Button(s) { session = s } }
                            } label: { Image(systemName: "chevron.down").font(cf(11, .semibold)) }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 18)

            Spacer()
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    state.ensureBoard(machine: machine, session: session); dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canAdd).buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
        .background(Theme.appBackground)
    }
}
