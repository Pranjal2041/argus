import SwiftUI

/// Every foreground session across the fleet, sectioned by what it needs from
/// you (the Mac's model label first, the broker's state as fallback), with Lab
/// decisions on top and a device-local Backlog for things set aside.
struct CommandCenterView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var lab: LabStore
    @EnvironmentObject var theme: ThemeStore
    @State private var query = ""
    @State private var actionError: String?
    @State private var focus: Bucket?
    @State private var replying: FleetStore.Card?

    enum Bucket: Int, CaseIterable, Identifiable {
        case needsYou, working, idle, backlog
        var id: Int { rawValue }
        var title: String { ["Needs you", "Working", "Done & idle", "Backlog"][rawValue] }
    }

    private func bucket(_ c: FleetStore.Card) -> Bucket {
        if c.backlogged { return .backlog }
        switch c.status { case .needsYou: return .needsYou; case .working: return .working; case .idle: return .idle }
    }

    private var cards: [FleetStore.Card] {
        guard !query.isEmpty else { return fleet.cards }
        return fleet.cards.filter {
            $0.session.name.localizedCaseInsensitiveContains(query) || $0.machine.name.localizedCaseInsensitiveContains(query)
                || ($0.item?.summary ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let all = cards
        List {
            if let e = fleet.hubError { Section { Label(e, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange) } }
            Section {
                SummaryChips(counts: Dictionary(uniqueKeysWithValues: Bucket.allCases.map { b in
                    (b, all.filter { bucket($0) == b }.count + (b == .needsYou ? lab.attention.count : 0))
                }), focus: $focus, palette: theme.palette)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            ForEach(Bucket.allCases.filter { focus == nil || focus == $0 }) { b in
                let rows = all.filter { bucket($0) == b }
                let labItems = b == .needsYou && query.isEmpty ? lab.attention : []
                if !rows.isEmpty || !labItems.isEmpty {
                    Section {
                        ForEach(labItems) { item in
                            Button { router.openLab(item) } label: { LabAttentionRow(item: item) }.buttonStyle(.plain)
                        }
                        ForEach(rows) { card in row(card) }
                    } header: {
                        Text("\(b.title) · \(rows.count + labItems.count)")
                    }
                }
            }
            if let focus, all.filter({ bucket($0) == focus }).isEmpty, focus != .needsYou || lab.attention.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Text(focus == .needsYou ? "Nothing needs you" : "Nothing in \(focus.title)").font(.headline)
                        Button("Show everything") { self.focus = nil }.font(.subheadline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                .listRowBackground(Color.clear)
            }
            if all.isEmpty && lab.attention.isEmpty && fleet.hubError == nil {
                ContentUnavailableView(fleet.machines.isEmpty ? "Looking for machines…" : "No sessions",
                                       systemImage: "rectangle.stack",
                                       description: Text(fleet.machines.isEmpty ? "Connecting to your Mac." : "Start one from Machines."))
            }
        }
        .navigationTitle("Command Center")
        .searchable(text: $query, prompt: "Filter sessions")
        .refreshable { await fleet.refreshNow() }
        .sheet(item: $replying) { QuickReplySheet(card: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { UnattendedPill() }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    @ViewBuilder private func row(_ card: FleetStore.Card) -> some View {
        Button { router.openTerminal(card.machine, card.session) } label: {
            CardRow(card: card, palette: theme.palette).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session-card")
            .opacity(card.backlogged ? 0.6 : 1)
            .swipeActions(edge: .leading) {
                Button { fleet.toggleBacklog(card.machine, card.session) } label: {
                    Label(card.backlogged ? "Restore" : "Backlog", systemImage: card.backlogged ? "tray.and.arrow.up" : "tray")
                }
                .tint(.gray)
            }
            .swipeActions(edge: .trailing) {
                Button { replying = card } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }.tint(.blue)
                Button { setStatus("milestone", card) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
            }
            .contextMenu {
                Button { replying = card } label: { Label("Quick reply", systemImage: "arrowshape.turn.up.left") }
                Section("Set status") {
                    ForEach(FleetStore.statusLabels, id: \.label) { s in
                        Button((card.label == s.label ? "● " : "") + s.title) { setStatus(s.label, card) }
                    }
                }
                Button { fleet.toggleBacklog(card.machine, card.session) } label: {
                    Label(card.backlogged ? "Remove from backlog" : "Backlog — set aside", systemImage: "tray")
                }
                if let path = card.session.path, !path.isEmpty {
                    Button { router.openFiles(card.machine, path: path) } label: { Label("Open folder", systemImage: "folder") }
                }
                if let look = card.item?.lookAtThis, !look.isEmpty {
                    Button { UIPasteboard.general.string = look } label: { Label("Copy highlighted line", systemImage: "doc.on.doc") }
                }
            }
    }

    private func setStatus(_ label: String, _ card: FleetStore.Card) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do { try await fleet.setStatus(label, for: card.session, on: card.machine) }
            catch { actionError = error.localizedDescription }
        }
    }
}

struct CardRow: View {
    let card: FleetStore.Card
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(card.session.name).font(.body.weight(.medium)).lineLimit(1)
                if let chip = chip {
                    Text(chip).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
                }
                Spacer()
                Text(card.machine.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = card.item?.summary, !summary.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            if let look = card.item?.lookAtThis, !look.isEmpty {
                Text(look).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            if let updated = card.item?.updatedAt {
                Text(Date(timeIntervalSince1970: updated), format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var chip: String? {
        switch card.label {
        case "needs-decision": return "Needs you"
        case "stuck": return "Stuck"
        case "drifting": return "Drifting"
        case "no-progress": return "No progress"
        case "milestone": return "Milestone"
        case "look": return "Worth a look"
        default: return nil
        }
    }

    private var color: Color {
        switch card.label {
        case "stuck": return palette.badColor
        case "look": return palette.lookColor
        case "milestone": return palette.milestoneColor
        case "drifting", "no-progress": return palette.unseenColor
        default:
            switch card.status {
            case .needsYou: return palette.waitingColor
            case .working: return palette.workingColor
            case .idle: return palette.idleColor
            }
        }
    }
}

struct LabAttentionRow: View {
    let item: LabAttentionItem
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flask.fill").foregroundStyle(theme.palette.waitingColor)
                Text(item.reference).font(.body.weight(.semibold))
                Text(item.kind == .key ? "Lab access" : "Lab approval").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(theme.palette.waitingColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(theme.palette.waitingColor)
                Spacer()
                Text(item.machineName).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.project).font(.caption).foregroundStyle(.secondary)
            Text(item.summary).font(.footnote).lineLimit(6)
            Text("OPEN DECISION →").font(.caption2.weight(.bold)).foregroundStyle(theme.palette.accentColor)
        }
        .padding(.vertical, 4)
    }
}

/// Unattended Mode (Mac): Lab gates auto-approve while you're away.
struct UnattendedPill: View {
    @EnvironmentObject var lab: LabStore
    @State private var busy = false

    var body: some View {
        if let on = lab.unattended {
            Button {
                busy = true
                Task { await lab.setUnattended(!on); busy = false }
            } label: {
                Label(busy ? "…" : (on ? "Unattended" : "Auto Lab"), systemImage: on ? "moon.fill" : "moon")
                    .labelStyle(.titleAndIcon).font(.caption.weight(.semibold))
            }
            .tint(on ? .purple : .secondary)
            .disabled(busy)
        }
    }
}

/// Counts per bucket; tapping one shows only that bucket.
struct SummaryChips: View {
    let counts: [CommandCenterView.Bucket: Int]
    @Binding var focus: CommandCenterView.Bucket?
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CommandCenterView.Bucket.allCases) { b in
                let n = counts[b] ?? 0
                let on = focus == b
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    focus = on ? nil : b
                } label: {
                    VStack(spacing: 2) {
                        Text("\(n)").font(.title3.weight(.semibold).monospacedDigit())
                        Text(b.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(n == 0 ? Color.secondary : color(b))
                    .background(color(b).opacity(on ? 0.28 : 0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? color(b) : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) \(b.title)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func color(_ b: CommandCenterView.Bucket) -> Color {
        switch b {
        case .needsYou: return palette.waitingColor
        case .working: return palette.workingColor
        case .idle: return palette.milestoneColor
        case .backlog: return .gray
        }
    }
}

/// Answer an agent without opening the full terminal: its latest output
/// (`/recent`), a reply box, and one-tap answers. Text is typed with Enter.
struct QuickReplySheet: View {
    let card: FleetStore.Card
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var recent = ""
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(recent.isEmpty ? "Loading output…" : recent)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color.black.opacity(0.35))
                    .onChange(of: recent) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                if let summary = card.item?.summary, !summary.isEmpty {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.top, 8)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["y", "n", "1", "2", "3", "continue"], id: \.self) { quick in
                            Button(quick) { send(quick) }.buttonStyle(.bordered)
                        }
                        Button { send("") } label: { Label("Enter", systemImage: "return") }.buttonStyle(.bordered)
                    }
                    .padding(.horizontal).padding(.top, 8)
                }
                HStack(alignment: .bottom) {
                    TextField("Reply to \(card.session.name)", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .padding(10).background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    Button { send(text) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(text.isEmpty || sending)
                }
                .padding()
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 6) }
            }
            .navigationTitle(card.session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Terminal") {
                        dismiss()
                        router.openTerminal(card.machine, card.session)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            focused = true
            while !Task.isCancelled {
                await loadRecent()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func loadRecent() async {
        guard let data = try? await BrokerHTTP.getData(card.machine.httpBase, "recent", query: [
            .init(name: "session", value: card.session.name), .init(name: "lines", value: "60"),
        ]) else { return }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        recent = lines.reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed().joined(separator: "\n")
    }

    private func send(_ reply: String) {
        sending = true
        Task {
            defer { sending = false }
            do {
                try await fleet.send(reply, to: card.session, on: card.machine)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                text = ""
                fleet.acknowledge(card.machine, card.session)
                try? await Task.sleep(nanoseconds: 600_000_000)
                await loadRecent()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
