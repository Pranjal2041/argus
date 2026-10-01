import SwiftUI

// The Lab tab: masthead (areas + Unattended Mode), Inbox, Research, Guidance,
// and the small components every Lab page shares. Detail pages are in LabPages.swift.

enum LabArea: String, CaseIterable, Identifiable {
    case inbox, research, guidance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .research: return "Research"
        case .guidance: return "Guidance"
        }
    }
}

/// Lab destinations pushed onto the Lab tab's stack.
enum LabRoute: Hashable {
    case key(String)          // LabPendingKey.id
    case proposal(String)     // LabPendingRun.id
    case set(String)          // LabSetCard.id
    case run(String, String)  // card id, run id
    case compare(String, String, String)

    static func of(_ item: LabAttentionItem) -> LabRoute {
        item.kind == .key ? .key(item.targetID) : .proposal(item.targetID)
    }
}

struct LabView: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var lab: LabStore
    @State private var area: LabArea = .inbox
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            LabMasthead(area: $area)
            Group {
                switch area {
                case .inbox: LabInboxList(query: query)
                case .research: LabResearchList(query: query)
                case .guidance: LabGuidanceList(query: query)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("Lab")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: searchPrompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if lab.refreshing { ProgressView() } else {
                    Button { Task { await lab.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh")
                        .accessibilityLabel("Refresh Lab")
                }
            }
        }
        .navigationDestination(for: LabRoute.self) { LabRouteView(route: $0) }
        .onAppear {
            consumeTarget()
            Task { await lab.refresh() }
        }
        .onChange(of: router.labTarget) { _, _ in consumeTarget() }
    }

    private var searchPrompt: String {
        switch area {
        case .inbox: return "Search requests"
        case .research: return "Search sets, runs, results"
        case .guidance: return "Search guidance"
        }
    }

    /// A notification or Command Center tap: open exactly that dossier.
    private func consumeTarget() {
        guard let target = router.labTarget else { return }
        area = .inbox
        var path = NavigationPath()
        path.append(LabRoute.of(target))
        router.labPath = path
        router.labTarget = nil
        Task { await lab.refresh() }
    }
}

// MARK: Masthead

struct LabMasthead: View {
    @EnvironmentObject var lab: LabStore
    @Binding var area: LabArea

    var body: some View {
        VStack(spacing: 8) {
            Picker("Area", selection: $area) {
                ForEach(LabArea.allCases) { a in
                    Text(a == .inbox && !lab.attention.isEmpty ? "Inbox · \(lab.attention.count)" : a.title).tag(a)
                }
            }
            .pickerStyle(.segmented)
            if lab.hasMac {
                HStack(spacing: 8) {
                    Image(systemName: lab.unattended == true ? "moon.stars.fill" : "moon.stars")
                        .foregroundStyle(lab.unattended == true ? Color.orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unattended Mode").font(.subheadline.weight(.medium))
                        Text(lab.unattended == true ? "The Mac auto-approves access and proposals" : "You approve every Lab gate")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if lab.unattendedUpdating { ProgressView().controlSize(.small) }
                    Toggle("Unattended Mode", isOn: Binding(
                        get: { lab.unattended ?? false },
                        set: { on in Task { await lab.setUnattended(on) } }))
                        .labelsHidden()
                        .tint(.orange)
                        .disabled(lab.unattendedUpdating || lab.unattended == nil)
                }
                if let e = lab.unattendedError {
                    Text(e).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LabErrorBanner()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The last rejected action or connectivity problem; tap to dismiss.
struct LabErrorBanner: View {
    @EnvironmentObject var lab: LabStore
    var body: some View {
        if let e = lab.error {
            Button { lab.error = nil } label: {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(e).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "xmark").font(.caption)
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(10)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: Inbox

struct LabInboxList: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var lab: LabStore
    let query: String

    private var items: [LabAttentionItem] {
        guard !query.isEmpty else { return lab.attention }
        return lab.attention.filter {
            [$0.reference, $0.project, $0.machineName, $0.summary].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            if !lab.attention.isEmpty {
                Section {
                    ForEach(items) { item in
                        NavigationLink(value: LabRoute.of(item)) { LabDecisionRow(item: item) }
                    }
                } header: {
                    Text("Newest request first · \(lab.attention.count) blocked")
                }
            }
        }
        .overlay {
            if fleet.machines.isEmpty {
                ContentUnavailableView("No brokers yet", systemImage: "network.slash",
                                       description: Text("Argus reads Lab from every broker it finds through your hub."))
            } else if !lab.loaded {
                ProgressView("Reading Lab stores…")
            } else if lab.attention.isEmpty {
                ContentUnavailableView("Decision queue clear", systemImage: "checkmark.seal",
                                       description: Text("No access request or experiment is waiting on you."))
            } else if items.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .refreshable { await lab.refresh() }
    }
}

struct LabDecisionRow: View {
    let item: LabAttentionItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.kind == .key ? "ACCESS" : "EXPERIMENT")
                        .font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.orange)
                    if item.kind == .proposal { Text(item.reference).font(.caption.monospaced()) }
                    Spacer()
                    if let created = item.created { Text(LabTime.ago(created)).font(.caption2).foregroundStyle(.secondary) }
                }
                Text(item.summary).font(.subheadline).lineLimit(3)
                Text("\(item.project) · \(item.machineName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Research

struct LabResearchList: View {
    @EnvironmentObject var fleet: FleetStore
    @EnvironmentObject var lab: LabStore
    let query: String
    @State private var showArchived = false

    private var cards: [LabSetCard] {
        lab.sets.filter { showArchived || !$0.brief.archived }.filter { query.isEmpty || matches($0) }
    }

    private func matches(_ card: LabSetCard) -> Bool {
        let set = card.brief.set
        let fields = [set.project, set.id, set.cwd, card.machineName]
            + card.brief.runs.flatMap { [$0.id, $0.group ?? "", $0.latest ?? ""] }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let byProject = Dictionary(grouping: cards, by: \.brief.set.project)
        List {
            Section {
                Picker("Show", selection: $showArchived) {
                    Text("Active").tag(false)
                    Text("Including archive").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            ForEach(byProject.keys.sorted(), id: \.self) { project in
                let projectCards = (byProject[project] ?? []).sorted { $0.brief.activityAt > $1.brief.activityAt }
                Section {
                    ForEach(projectCards) { card in
                        NavigationLink(value: LabRoute.set(card.id)) { LabSetRow(card: card) }
                            .swipeActions(edge: .trailing) {
                                if !card.offline {
                                    Button { Task { await lab.setArchived(card, on: !card.brief.archived) } } label: {
                                        Label(card.brief.archived ? "Restore" : "Archive",
                                              systemImage: card.brief.archived ? "tray.and.arrow.up" : "archivebox")
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }
                } header: {
                    Text("\(project.isEmpty ? "No project" : project) · \(projectCards.count) set\(projectCards.count == 1 ? "" : "s")")
                }
            }
        }
        .overlay {
            if fleet.machines.isEmpty {
                ContentUnavailableView("No brokers yet", systemImage: "network.slash")
            } else if !lab.loaded {
                ProgressView("Reading Lab stores…")
            } else if cards.isEmpty {
                if !query.isEmpty { ContentUnavailableView.search(text: query) } else {
                    ContentUnavailableView("No experiment sets", systemImage: "flask",
                                           description: Text(showArchived ? "The archive is empty." : "Approved agents have not recorded a set yet."))
                }
            }
        }
        .refreshable { await lab.refresh() }
    }
}

struct LabSetRow: View {
    let card: LabSetCard
    var body: some View {
        let live = card.brief.runs.filter { !$0.archived }
        let active = live.filter { $0.phase.isActive }.count
        var seen = Set<LabPhase>()
        let phases = live.map(\.phase).filter { seen.insert($0).inserted }
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                if phases.isEmpty { Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7) }
                ForEach(phases.prefix(4), id: \.self) { Circle().fill($0.color).frame(width: 7, height: 7) }
            }
            .frame(minWidth: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.machineName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if card.offline { LabTag(text: "OFFLINE", color: .secondary) }
                    if card.brief.archived { LabTag(text: "ARCHIVED", color: .secondary) }
                }
                Text("\(card.brief.set.id) · \(LabFormat.shortPath(card.brief.set.cwd))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(active > 0 ? "\(active) active" : "\(card.brief.runs.count) run\(card.brief.runs.count == 1 ? "" : "s")")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(active > 0 ? LabPhase.running.color : .secondary)
        }
    }
}

// MARK: Guidance

struct LabGuidanceList: View {
    @EnvironmentObject var lab: LabStore
    let query: String
    @State private var selectedKey = "all"
    @State private var text = ""
    @State private var showHidden = false

    var body: some View {
        let scopes = LabGuidance.scopes(notes: lab.notes, sets: lab.sets)
        let selected = scopes.first { $0.key == selectedKey } ?? scopes[0]
        let all = LabGuidance.notes(lab.notes, scope: selected)
        let entries = all.filter { (showHidden || !$0.note.hidden) && (query.isEmpty || $0.note.text.localizedCaseInsensitiveContains(query)) }
        List {
            Section("Audience") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(scopes) { scope in
                            let active = scope.key == selected.key
                            Button { selectedKey = scope.key } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scope.label).font(.footnote.weight(.semibold)).lineLimit(1)
                                    Text(scope.sub).font(.caption2).lineLimit(1).opacity(0.75)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .foregroundStyle(active ? Color.white : .primary)
                                .background(active ? Color.accentColor : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.label).font(.title3.bold())
                    Text(selected.sub).font(.caption).foregroundStyle(.secondary)
                    Text(selected.explanation).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                }
                TextField("Durable guidance for these agents", text: $text, axis: .vertical).lineLimit(2...8)
                Button {
                    let body = text
                    Task { if await publish(body, to: selected) { text = "" } }
                } label: {
                    Label("Publish guidance", systemImage: "paperplane")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lab.actionBusy
                          || (selected.type != .all && selected.group == nil && selected.card == nil))
            }
            Section {
                if entries.isEmpty {
                    Text(query.isEmpty ? "No guidance in this audience." : "No guidance matches “\(query)”.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    LabGuidanceRow(entry: entry)
                        .swipeActions(edge: .trailing) {
                            if !entry.note.hidden {
                                Button(entry.replicas.count > 1 ? "Hide all" : "Hide") { Task { await lab.hide(entry) } }
                                    .tint(.gray)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Instruction ledger · \(all.filter { !$0.note.hidden }.count) active")
                    Spacer()
                    Button(showHidden ? "Hide hidden" : "Show hidden") { showHidden.toggle() }
                        .font(.caption).textCase(nil)
                }
            }
        }
        .refreshable { await lab.refresh() }
    }

    private func publish(_ text: String, to scope: LabGuidanceScope) async -> Bool {
        switch scope.type {
        case .all: return await lab.postEverywhere(text)
        case .machine:
            guard let g = scope.group else { return false }
            return await lab.postScopeNote(g, scope: "machine", project: "", text)
        case .project:
            guard let g = scope.group else { return false }
            return await lab.postScopeNote(g, scope: "project", project: scope.project, text)
        case .set:
            guard let card = scope.card else { return false }
            return await lab.postSetNote(card, text)
        }
    }
}

struct LabGuidanceRow: View {
    @EnvironmentObject var lab: LabStore
    let entry: LabGuidanceNote
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.note.scope == "global" ? "EVERYWHERE" : entry.note.scope.uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(Color.accentColor)
                .frame(width: 70, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                LabMarkdownView(text: entry.note.text)
                    .foregroundStyle(entry.note.hidden ? .secondary : .primary)
                let origin = entry.replicas.isEmpty ? "" : "\(entry.replicas.count) store\(entry.replicas.count == 1 ? "" : "s") · "
                HStack(spacing: 6) {
                    Text(origin + LabTime.ago(entry.note.time))
                    if entry.note.hidden { LabTag(text: "HIDDEN", color: .secondary) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !entry.note.hidden {
                Button(entry.replicas.count > 1 ? "HIDE ALL" : "HIDE") { Task { await lab.hide(entry) } }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.borderless)
                    .disabled(lab.actionBusy)
            }
        }
    }
}

// MARK: Shared components

extension LabPhase {
    var color: Color {
        switch self {
        case .needs: return .orange
        case .approved: return .blue
        case .running: return .cyan
        case .failed, .rejected: return .red
        case .stopped: return .gray
        case .finished: return .green
        case .recorded: return .secondary
        }
    }
}

struct LabTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Label/value evidence rows in monospace, selectable.
struct LabFactsView: View {
    let facts: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { i, fact in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fact.0).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                        .frame(width: 98, alignment: .leading)
                    Text(fact.1).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
                if i < facts.count - 1 { Divider() }
            }
        }
    }
}

/// Scrollable monospaced evidence (argv, diffs, logs, parameter files).
struct LabCodeBlock: View {
    let text: String
    var maxHeight: CGFloat = 320
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: text.split(separator: "\n", omittingEmptySubsequences: false).count < 18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5))
    }
}

/// A titled evidence block that starts collapsed (long diffs and logs).
struct LabEvidence: View {
    let title: String
    let text: String
    var expanded = false
    @State private var open: Bool?
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { open ?? expanded }, set: { open = $0 })) {
            LabCodeBlock(text: text).padding(.top, 4)
        } label: {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Text(LabFormat.bytes(Int64(text.utf8.count))).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Agent-authored Markdown rendered natively: block structure from
/// LabMarkdown.parse, inline styling and links through AttributedString.
struct LabMarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(LabMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: LabMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(LabMarkdown.inline(t)).font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
        case .paragraph(let t):
            Text(LabMarkdown.inline(t)).font(.subheadline)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LabMarkdown.inline(item))
                    }
                    .font(.subheadline)
                }
            }
        case .quote(let t):
            Text(LabMarkdown.inline(t)).font(.subheadline).foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let t):
            LabCodeBlock(text: t, maxHeight: 240)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(LabMarkdown.inline(cell)).font(r == 0 ? .caption.bold() : .caption)
                            }
                        }
                        if r == 0 { Divider() }
                    }
                }
                .padding(8)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }
}

/// A note or result line: age, then Markdown.
struct LabNoteRow: View {
    let text: String
    let time: String
    var author: String?
    var hidden = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LabTime.ago(time)).font(.caption2).foregroundStyle(.secondary)
                if let author { Text(author).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .frame(width: 44, alignment: .leading)
            LabMarkdownView(text: text).foregroundStyle(hidden ? .secondary : .primary)
            if hidden { LabTag(text: "HIDDEN", color: .secondary) }
        }
    }
}

/// Reject/approve controls pinned under a decision dossier.
struct LabDecisionDock: View {
    let busy: Bool
    let rejectLabel: String
    let onReject: () -> Void
    let onApprove: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView() }
            Spacer()
            Button(role: .destructive, action: onReject) { Text(rejectLabel).frame(minWidth: 80) }
                .buttonStyle(.bordered)
                .controlSize(.large)
            Button(action: onApprove) { Text("Approve").bold().frame(minWidth: 110) }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
        }
        .disabled(busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

enum LabHaptics {
    static func decided(approve: Bool, ok: Bool) {
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(!ok ? .error : approve ? .success : .warning)
    }
}
