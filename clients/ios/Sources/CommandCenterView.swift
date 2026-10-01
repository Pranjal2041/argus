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

    private enum Bucket: Int, CaseIterable, Identifiable {
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
        let needs = all.filter { bucket($0) == .needsYou }.count + lab.attention.count
        List {
            if let e = fleet.hubError { Section { Label(e, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange) } }
            ForEach(Bucket.allCases) { b in
                let rows = all.filter { bucket($0) == b }
                let labItems = b == .needsYou && query.isEmpty ? lab.attention : []
                if !rows.isEmpty || !labItems.isEmpty {
                    Section {
                        ForEach(labItems) { item in LabAttentionRow(item: item).contentShape(Rectangle()).onTapGesture { router.openLab(item) } }
                        ForEach(rows) { card in row(card) }
                    } header: {
                        Text("\(b.title) · \(rows.count + labItems.count)")
                    }
                }
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
        .safeAreaInset(edge: .top) {
            Text(needs == 0 ? "All \(all.count) quiet" : "\(needs) need you · \(all.count + lab.attention.count - needs) other")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 2)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { UnattendedPill() }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    @ViewBuilder private func row(_ card: FleetStore.Card) -> some View {
        CardRow(card: card, palette: theme.palette)
            .contentShape(Rectangle())
            .onTapGesture { router.openTerminal(card.machine, card.session) }
            .opacity(card.backlogged ? 0.6 : 1)
            .swipeActions(edge: .leading) {
                Button { fleet.toggleBacklog(card.machine, card.session) } label: {
                    Label(card.backlogged ? "Restore" : "Backlog", systemImage: card.backlogged ? "tray.and.arrow.up" : "tray")
                }
                .tint(.gray)
            }
            .swipeActions(edge: .trailing) {
                Button { setStatus("milestone", card) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                Button { setStatus("needs-decision", card) } label: { Label("Needs you", systemImage: "hand.raised") }.tint(.orange)
            }
            .contextMenu {
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
                Text(Date(timeIntervalSince1970: updated), style: .relative).font(.caption2).foregroundStyle(.tertiary)
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
