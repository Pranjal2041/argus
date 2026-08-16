import SwiftUI

struct WeeklyProgressPanelLocation: Hashable, Identifiable {
    var id: String { machineID }
    let machineID: String
    let machineName: String
    let folders: [String]
    let isAgent: Bool
    let lastSeen: Int64?

    var folder: String? { folders.first }
}

enum WeeklyProgressPanelAvailability: String, CaseIterable, Identifiable {
    case running = "Running"
    case past = "Past"

    var id: String { rawValue }
}

struct WeeklyProgressPanelCandidate: Identifiable, Hashable {
    var id: String { session.folding(options: [.caseInsensitive], locale: .current) }
    let session: String
    var locations: [WeeklyProgressPanelLocation]
    let availability: WeeklyProgressPanelAvailability
    var isAgentOnly: Bool { !locations.isEmpty && locations.allSatisfy(\.isAgent) }
    var lastSeen: Int64? { locations.compactMap(\.lastSeen).max() }
}

enum WeeklyProgressPanelCatalog {
    static func make(
        machines: [Machine],
        sessionsByMachine: [String: [SessionInfo]]
    ) -> [WeeklyProgressPanelCandidate] {
        var names: [String: String] = [:]
        var locations: [String: [WeeklyProgressPanelLocation]] = [:]
        let machinesByID = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        for (machineID, sessions) in sessionsByMachine {
            let machineName = machinesByID[machineID]?.name ?? machineID
            for session in sessions {
                let key = session.name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                names[key] = names[key] ?? session.name
                let location = WeeklyProgressPanelLocation(
                    machineID: machineID,
                    machineName: machineName,
                    folders: cleanFolders([session.path]),
                    isAgent: session.agent,
                    lastSeen: session.activity > 0 ? session.activity : nil
                )
                merge(location, into: &locations[key, default: []])
            }
        }
        return names.map { key, name in
            WeeklyProgressPanelCandidate(
                session: name,
                locations: (locations[key] ?? []).sorted {
                    $0.machineName.localizedCaseInsensitiveCompare($1.machineName) == .orderedAscending
                },
                availability: .running
            )
        }.sorted {
            if $0.isAgentOnly != $1.isAgentOnly { return !$0.isAgentOnly }
            return $0.session.localizedCaseInsensitiveCompare($1.session) == .orderedAscending
        }
    }

    /// Durable broker history is the authority for ended panels. A panel that is
    /// currently live anywhere is omitted from Past, even if older history rows for
    /// the same name exist on other Babel nodes.
    static func makePast(
        machines: [Machine],
        sessionsByMachine: [String: [SessionInfo]],
        historyItems: [SessionHistoryItem]
    ) -> [WeeklyProgressPanelCandidate] {
        let liveNames = Set(sessionsByMachine.values.flatMap { $0 }.map { key($0.name) })
        var names: [String: String] = [:]
        var newestByName: [String: Int64] = [:]
        var locations: [String: [WeeklyProgressPanelLocation]] = [:]

        for item in historyItems {
            let nameKey = key(item.name)
            guard !liveNames.contains(nameKey) else { continue }
            if item.last >= newestByName[nameKey, default: 0] {
                names[nameKey] = item.name
                newestByName[nameKey] = item.last
            }
            let machine = machine(for: item.node, in: machines)
            let spans = item.folders.sorted { $0.last > $1.last }.map(\.path)
            let location = WeeklyProgressPanelLocation(
                machineID: machine?.id ?? item.node,
                machineName: machine?.name ?? item.node,
                folders: cleanFolders(spans.map(Optional.some)),
                isAgent: item.agent,
                lastSeen: item.last
            )
            merge(location, into: &locations[nameKey, default: []])
        }

        return names.map { nameKey, name in
            WeeklyProgressPanelCandidate(
                session: name,
                locations: (locations[nameKey] ?? []).sorted {
                    let lhs = $0.lastSeen ?? 0
                    let rhs = $1.lastSeen ?? 0
                    if lhs != rhs { return lhs > rhs }
                    return $0.machineName.localizedCaseInsensitiveCompare($1.machineName) == .orderedAscending
                },
                availability: .past
            )
        }.sorted {
            let lhs = $0.lastSeen ?? 0
            let rhs = $1.lastSeen ?? 0
            if lhs != rhs { return lhs > rhs }
            if $0.isAgentOnly != $1.isAgentOnly { return !$0.isAgentOnly }
            return $0.session.localizedCaseInsensitiveCompare($1.session) == .orderedAscending
        }
    }

    private static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func machine(for node: String, in machines: [Machine]) -> Machine? {
        machines.first { $0.id.caseInsensitiveCompare(node) == .orderedSame }
            ?? machines.first { $0.name.caseInsensitiveCompare(node) == .orderedSame }
            ?? machines.first {
                !$0.host.isEmpty && $0.host.caseInsensitiveCompare(node) == .orderedSame
            }
    }

    private static func cleanFolders(_ values: [String?]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !clean.isEmpty else { return nil }
            let folded = clean.folding(options: [.caseInsensitive], locale: .current)
            return seen.insert(folded).inserted ? clean : nil
        }
    }

    private static func merge(
        _ incoming: WeeklyProgressPanelLocation,
        into locations: inout [WeeklyProgressPanelLocation]
    ) {
        guard let index = locations.firstIndex(where: { $0.machineID == incoming.machineID }) else {
            locations.append(incoming)
            return
        }
        let existing = locations[index]
        let newest = (incoming.lastSeen ?? 0) >= (existing.lastSeen ?? 0) ? incoming : existing
        let allFolders = cleanFolders(
            (newest.folders + (newest == incoming ? existing.folders : incoming.folders)).map(Optional.some)
        )
        locations[index] = WeeklyProgressPanelLocation(
            machineID: newest.machineID,
            machineName: newest.machineName,
            folders: allFolders,
            isAgent: incoming.isAgent && existing.isAgent,
            lastSeen: max(incoming.lastSeen ?? 0, existing.lastSeen ?? 0)
        )
    }
}

private struct WeeklyProgressPanelDraft: Identifiable {
    let id: UUID
    var session: String
    var machineID: String?

    init(id: UUID = UUID(), selector: WeeklyProgressPanelSelector) {
        self.id = id
        session = selector.session
        machineID = selector.machineID
    }

    var selector: WeeklyProgressPanelSelector {
        WeeklyProgressPanelSelector(session: session, machineID: machineID)
    }
}

private struct WeeklyProgressRootDraft: Identifiable {
    let id: UUID
    var path: String
    init(id: UUID = UUID(), path: String) { self.id = id; self.path = path }
}

struct WeeklyProgressProjectEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    let project: WeeklyProgressProject
    let onSave: (WeeklyProgressProject) -> Void

    @State private var name: String
    @State private var panels: [WeeklyProgressPanelDraft]
    @State private var roots: [WeeklyProgressRootDraft]
    @State private var panelQuery = ""
    @State private var panelAvailability: WeeklyProgressPanelAvailability = .running
    @FocusState private var nameFocused: Bool

    init(project: WeeklyProgressProject, onSave: @escaping (WeeklyProgressProject) -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project.name)
        _panels = State(initialValue: project.panels.map {
            WeeklyProgressPanelDraft(selector: $0)
        })
        _roots = State(initialValue: project.workspaceRoots.map {
            WeeklyProgressRootDraft(path: $0)
        })
    }

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var runningCandidates: [WeeklyProgressPanelCandidate] {
        WeeklyProgressPanelCatalog.make(
            machines: state.machines,
            sessionsByMachine: state.sessionsByMachine
        )
    }

    private var pastCandidates: [WeeklyProgressPanelCandidate] {
        WeeklyProgressPanelCatalog.makePast(
            machines: state.machines,
            sessionsByMachine: state.sessionsByMachine,
            historyItems: state.historyItems
        )
    }

    private var candidates: [WeeklyProgressPanelCandidate] {
        panelAvailability == .running ? runningCandidates : pastCandidates
    }

    private var allCandidates: [WeeklyProgressPanelCandidate] {
        runningCandidates + pastCandidates
    }

    private var matchingCandidates: [WeeklyProgressPanelCandidate] {
        let query = panelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.filter { candidate in
            !panels.contains(where: {
                $0.session.compare(
                    candidate.session,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) && (query.isEmpty
                    || candidate.session.localizedCaseInsensitiveContains(query)
                    || candidate.locations.contains {
                        $0.machineName.localizedCaseInsensitiveContains(query)
                            || $0.folders.contains { $0.localizedCaseInsensitiveContains(query) }
                    })
        }
    }

    private var cleanName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanPanelQuery: String {
        panelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddManualPanel: Bool {
        !cleanPanelQuery.isEmpty
            && !panels.contains {
                $0.session.compare(
                    cleanPanelQuery,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            && !allCandidates.contains {
                $0.session.compare(
                    cleanPanelQuery,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
    }

    private var canSave: Bool {
        !cleanName.isEmpty && (!panels.isEmpty || roots.contains {
            !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    nameSection
                    panelSection
                    folderSection
                }
                .padding(22)
            }
            Divider().overlay(Theme.border)
            footer
        }
        .frame(width: 690, height: 670)
        .background(Theme.appBackground)
        .onAppear {
            nameFocused = cleanName.isEmpty
            state.refreshHistoryCache()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.12))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(cf(13, .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: 1) {
                Text(cleanName.isEmpty ? "New project" : "Edit project")
                    .font(cf(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Define which panels and folders belong to the same research thread")
                    .font(cf(10.8))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(cf(12, .medium)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var nameSection: some View {
        editorSection(
            title: "Project name",
            detail: "A stable research name—not a machine or folder name."
        ) {
            TextField("e.g. VLM gating", text: $name)
                .textFieldStyle(.plain)
                .font(cf(13.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .focused($nameFocused)
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.72)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private var panelSection: some View {
        editorSection(
            title: "Panels",
            detail: "Across machines follows a panel when work moves between Babel nodes."
        ) {
            VStack(spacing: 10) {
                if panels.isEmpty {
                    editorEmpty("No panels included yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                            selectedPanelRow(index: index, panel: panel)
                            if index < panels.count - 1 {
                                Divider().overlay(Theme.border).padding(.leading, 37)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground.opacity(0.48)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
                }

                panelCatalogSwitcher

                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(cf(10.5))
                        .foregroundStyle(Theme.textTertiary)
                    TextField(
                        panelAvailability == .running ? "Find a running panel" : "Search past panels",
                        text: $panelQuery
                    )
                        .textFieldStyle(.plain)
                        .font(cf(12))
                        .foregroundStyle(Theme.textPrimary)
                    if !panelQuery.isEmpty {
                        Button { panelQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(cf(10.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.65)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))

                if !matchingCandidates.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(matchingCandidates.prefix(7).enumerated()), id: \.element.id) { index, candidate in
                            candidateRow(candidate)
                            if index < min(7, matchingCandidates.count) - 1 {
                                Divider().overlay(Theme.border).padding(.leading, 37)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border.opacity(0.8), lineWidth: 1))
                }
                if canAddManualPanel {
                    Button {
                        panels.append(WeeklyProgressPanelDraft(
                            selector: WeeklyProgressPanelSelector(session: cleanPanelQuery)
                        ))
                        panelQuery = ""
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle")
                                .font(cf(11.5, .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add “\(cleanPanelQuery)”")
                                    .font(cf(12, .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                Text("Not found in recorded panels · follows across machines")
                                    .font(cf(9.8))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text("Add")
                                .font(cf(10.5, .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border.opacity(0.8), lineWidth: 1))
                } else if matchingCandidates.isEmpty {
                    Text(panelCatalogEmptyMessage)
                        .font(cf(10.8))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 3)
                }
            }
        }
    }

    private var panelCatalogSwitcher: some View {
        HStack(spacing: 4) {
            scopeButton(.running, count: runningCandidates.count)
            scopeButton(.past, count: pastCandidates.count)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func scopeButton(
        _ availability: WeeklyProgressPanelAvailability,
        count: Int
    ) -> some View {
        let selected = panelAvailability == availability
        return Button {
            panelAvailability = availability
            panelQuery = ""
        } label: {
            HStack(spacing: 6) {
                Image(systemName: availability == .running ? "circle.fill" : "clock.arrow.circlepath")
                    .font(cf(7.5, .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                Text(availability.rawValue)
                    .font(cf(10.8, selected ? .semibold : .medium))
                Text(String(count))
                    .font(cf(9.5, .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(Capsule().fill(Theme.surface.opacity(selected ? 0.9 : 0.55)))
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 29)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Theme.selection.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelCatalogEmptyMessage: String {
        let query = cleanPanelQuery
        if panelAvailability == .past {
            if pastCandidates.isEmpty {
                return "No ended panels are recorded yet. Argus keeps up to 90 days of session history."
            }
            return query.isEmpty ? "Every recorded past panel is already included." : "No past panels match that search."
        }
        if runningCandidates.isEmpty { return "No panels are running right now." }
        return query.isEmpty ? "Every running panel is already included." : "No running panels match that search."
    }

    private func selectedPanelRow(index: Int, panel: WeeklyProgressPanelDraft) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(cf(11, .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(panel.session)
                .font(cf(12.5, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Across machines") { panels[index].machineID = nil }
                if let candidate = candidate(named: panel.session), !candidate.locations.isEmpty {
                    Divider()
                    ForEach(candidate.locations) { location in
                        Button(location.machineName) { panels[index].machineID = location.machineID }
                    }
                } else if let machineID = panel.machineID {
                    Divider()
                    Button(machineID) { panels[index].machineID = machineID }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: panel.machineID == nil ? "point.3.connected.trianglepath.dotted" : "desktopcomputer")
                    Text(scopeName(panel))
                    Image(systemName: "chevron.down").font(cf(7.5, .semibold))
                }
                .font(cf(10.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(Theme.surface.opacity(0.8)))
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button { panels.remove(at: index) } label: {
                Image(systemName: "minus.circle.fill").font(cf(11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .help("Remove panel")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func candidateRow(_ candidate: WeeklyProgressPanelCandidate) -> some View {
        Button { add(candidate) } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(cf(11.5, .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.session)
                        .font(cf(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(candidateLocationSummary(candidate))
                        .font(cf(9.8))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .help(candidateLocationSummary(candidate, includeFolder: true))
                }
                Spacer()
                Text("Add")
                    .font(cf(10.5, .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
        .buttonStyle(.plain)
    }

    private var folderSection: some View {
        editorSection(
            title: "Workspace folders",
            detail: "The agent may read these repositories for evidence; it cannot modify them."
        ) {
            VStack(spacing: 8) {
                if roots.isEmpty {
                    editorEmpty("Folders are filled automatically when you add a panel.")
                }
                ForEach(Array(roots.enumerated()), id: \.element.id) { index, _ in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(cf(10.5))
                            .foregroundStyle(Theme.textTertiary)
                        TextField("/path/to/project", text: $roots[index].path)
                            .textFieldStyle(.plain)
                            .font(cf(11.5))
                            .foregroundStyle(Theme.textSecondary)
                        Button { roots.remove(at: index) } label: {
                            Image(systemName: "minus.circle.fill").font(cf(11.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                }
                Button {
                    roots.append(WeeklyProgressRootDraft(path: ""))
                } label: {
                    Label("Add folder", systemImage: "plus")
                        .font(cf(10.8, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    private func editorSection<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(cf(10.5, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textSecondary)
                Text(detail)
                    .font(cf(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            content()
        }
    }

    private func editorEmpty(_ text: String) -> some View {
        Text(text)
            .font(cf(10.8))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBackground.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border.opacity(0.8), lineWidth: 1))
    }

    private var footer: some View {
        HStack {
            Text(canSave ? "" : "Add a project name and at least one panel or folder.")
                .font(cf(10.5))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button { dismiss() } label: {
                Text("Cancel")
                    .font(cf(11.5, .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            Button(action: save) {
                Text("Save project")
                    .font(cf(11.5, .semibold))
                    .padding(.horizontal, 13)
                    .frame(height: 30)
            }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
    }

    private func add(_ candidate: WeeklyProgressPanelCandidate) {
        panels.append(WeeklyProgressPanelDraft(
            selector: WeeklyProgressPanelSelector(session: candidate.session)
        ))
        for path in candidate.locations.flatMap(\.folders) {
            let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !roots.contains(where: {
                $0.path.compare(clean, options: [.caseInsensitive]) == .orderedSame
            }) else { continue }
            roots.append(WeeklyProgressRootDraft(path: clean))
        }
        panelQuery = ""
    }

    private func save() {
        let cleanRoots = roots.map { $0.path.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let updated = WeeklyProgressProject(
            id: project.id,
            name: cleanName,
            panels: panels.map(\.selector),
            workspaceRoots: cleanRoots,
            createdAt: project.createdAt,
            updatedAt: Date()
        )
        onSave(updated)
    }

    private func candidate(named session: String) -> WeeklyProgressPanelCandidate? {
        allCandidates.first {
            $0.session.compare(session, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func scopeName(_ panel: WeeklyProgressPanelDraft) -> String {
        guard let machineID = panel.machineID else { return "Across machines" }
        return candidate(named: panel.session)?.locations.first(where: { $0.machineID == machineID })?.machineName
            ?? machineID
    }

    private func candidateLocationSummary(
        _ candidate: WeeklyProgressPanelCandidate,
        includeFolder: Bool = false
    ) -> String {
        var parts: [String] = []
        if candidate.availability == .past, let lastSeen = candidate.lastSeen {
            parts.append("Last used " + lastUsedDate(lastSeen))
        }
        if candidate.isAgentOnly { parts.append("Agent session") }
        let names = candidate.locations.map(\.machineName)
        if names.count <= 2 { parts.append(contentsOf: names) }
        else {
            parts.append(contentsOf: names.prefix(2))
            parts.append("+\(names.count - 2) machines")
        }
        if includeFolder, let folder = candidate.locations.flatMap(\.folders).first {
            parts.append(folder)
        }
        return parts.joined(separator: " · ")
    }

    private func lastUsedDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInYesterday(date) { return "yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            ? "MMM d"
            : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
