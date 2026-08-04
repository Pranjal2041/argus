import SwiftUI

enum PlannerDefaults {
    /// A newly written plan is normally a promise for today, not an invitation to
    /// configure a calendar. Keep the final minute explicit so it sorts naturally
    /// with timed commitments while still reading as "by the end of today".
    static func deadline(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
    }
}

enum PlannerProjectSuggestions {
    static func filtered(_ projects: [String], query: String, limit: Int = 7) -> [String] {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let unique = projects.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
        let matches = cleanQuery.isEmpty ? unique : unique.filter {
            $0.localizedCaseInsensitiveContains(cleanQuery)
        }
        return Array(matches.sorted { lhs, rhs in
            let lhsPrefix = lhs.lowercased().hasPrefix(cleanQuery.lowercased())
            let rhsPrefix = rhs.lowercased().hasPrefix(cleanQuery.lowercased())
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }.prefix(max(0, limit)))
    }
}

struct PlannerProjectOption: Identifiable, Equatable {
    var id: String { name.lowercased() }
    let name: String
    let count: Int
}

enum PlannerProjectCatalog {
    static func options(from commitments: [PlannerCommitment], preserving selection: String) -> [PlannerProjectOption] {
        let retained = commitments.map(\.project).filter { !$0.isEmpty }
        let names = PlannerProjectSuggestions.filtered(retained + [selection], query: "", limit: .max)
        return names.map { name in
            PlannerProjectOption(
                name: name,
                count: commitments.lazy.filter {
                    $0.project.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }.count
            )
        }
    }
}

/// Planner is deliberately a rolling list of finish lines, not a general calendar.
/// The interface keeps one invariant visible everywhere: earlier deadlines come first.
struct PlannerView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @AppStorage("ut.planner.lastProject") private var draftProject = ""
    @AppStorage("ut.planner.projectFilter") private var projectFilter = ""

    @State private var anchorDay = Calendar.current.startOfDay(for: Date())
    @State private var draftTitle = ""
    @State private var draftDeadline = PlannerDefaults.deadline()
    @State private var draftHasExactTime = true
    @State private var editingCommitment: PlannerCommitment?
    @State private var highlightedID: UUID?
    @FocusState private var titleFocused: Bool

    private let calendar = Calendar.current

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: anchorDay) }
    }

    private var weekEnd: Date {
        calendar.date(byAdding: .day, value: 7, to: anchorDay) ?? anchorDay
    }

    private var knownProjects: [String] {
        let live = state.sessionsByMachine.values.flatMap { sessions in
            sessions.filter { !$0.agent }.map(\.name)
        }
        let retained = state.plannerCommitments.map(\.project).filter { !$0.isEmpty }
        return PlannerProjectSuggestions.filtered(live + retained + [draftProject, projectFilter], query: "", limit: .max)
    }

    /// Agenda filtering should only offer projects that actually have plans. Session
    /// names are useful while composing, but showing every live shell in this control
    /// turns a small filter into an enormous, mostly irrelevant menu.
    private var plannedProjectOptions: [PlannerProjectOption] {
        PlannerProjectCatalog.options(from: state.plannerCommitments, preserving: projectFilter)
    }

    private var filteredCommitments: [PlannerCommitment] {
        let selection = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return state.plannerCommitments }
        return state.plannerCommitments.filter {
            $0.project.compare(selection, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var visibleOpenCount: Int {
        filteredCommitments.lazy.filter { commitment in
            guard !commitment.isCompleted else { return false }
            let day = calendar.startOfDay(for: commitment.deadline)
            if day >= anchorDay && day < weekEnd { return true }
            return calendar.isDate(anchorDay, inSameDayAs: Date()) && day < anchorDay
        }.count
    }

    private var sections: [PlannerDaySection] {
        var result: [PlannerDaySection] = []

        // Active commitments from earlier dates stay visible when looking at the current
        // horizon. They are still sorted by their original deadlines; nothing is promoted
        // or rearranged based on status.
        if calendar.isDate(anchorDay, inSameDayAs: Date()) {
            let overdue = filteredCommitments.filter {
                !$0.isCompleted && calendar.startOfDay(for: $0.deadline) < anchorDay
            }.sorted { PlannerCommitment.chronologicallyBefore($0, $1, calendar: calendar) }
            if !overdue.isEmpty {
                result.append(PlannerDaySection(
                    id: "overdue",
                    day: nil,
                    title: "Overdue",
                    subtitle: "Earlier deadlines",
                    summary: "\(overdue.count) needs attention",
                    commitments: overdue,
                    showsDateInRows: true
                ))
            }
        }

        for day in weekDays {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let commitments = filteredCommitments.filter {
                $0.deadline >= day && $0.deadline < next
            }.sorted { PlannerCommitment.chronologicallyBefore($0, $1, calendar: calendar) }
            guard !commitments.isEmpty else { continue }
            let open = commitments.lazy.filter { !$0.isCompleted }.count
            let done = commitments.count - open
            result.append(PlannerDaySection(
                id: dayIdentifier(day),
                day: day,
                title: relativeDayTitle(day),
                subtitle: longDate(day),
                summary: daySummary(open: open, done: done),
                commitments: commitments,
                showsDateInRows: false
            ))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
                .padding(.top, 18)
            weekStrip
                .padding(.top, 15)
            agenda
                .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .background(Theme.appBackground)
        .sheet(item: $editingCommitment) { commitment in
            PlannerEditorView(commitment: commitment, knownProjects: knownProjects)
                .environmentObject(state)
        }
    }

    private var header: some View {
        PlannerHeaderLayout(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                    Image(systemName: "calendar")
                        .font(cf(12, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Planner")
                        .font(cf(21, .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(headerSubtitle)
                        .font(cf(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 220, alignment: .leading)

            PlannerProjectFilterControl(selection: $projectFilter, options: plannedProjectOptions) { project in
                if !project.isEmpty { draftProject = project }
            }

            HStack(spacing: 7) {
                plannerHeaderButton("chevron.left", help: "Previous 7 days") { moveWeek(-7) }
                Button("Today") { goToToday() }
                    .font(cf(11, .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 29)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                plannerHeaderButton("chevron.right", help: "Next 7 days") { moveWeek(7) }
                Button { state.showPlanner = false } label: {
                    Image(systemName: "xmark").font(cf(14)).frame(width: 27, height: 27)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .help("Close Planner (⇧⌘P)")
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Divider().opacity(0.65) }
    }

    private var headerSubtitle: String {
        let scope = projectFilter.isEmpty ? "" : " in \(projectFilter)"
        if visibleOpenCount == 0 { return "No open commitments\(scope) in this 7-day horizon" }
        return "\(visibleOpenCount) open commitment\(visibleOpenCount == 1 ? "" : "s")\(scope) · ordered by deadline"
    }

    private func plannerHeaderButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(cf(10, .semibold)).frame(width: 29, height: 29)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
        .help(help)
    }

    private var composer: some View {
        PlannerComposerLayout(spacing: 9) {
            composerTitleField
            PlannerProjectAutocomplete(text: $draftProject, projects: knownProjects)
                .frame(minWidth: 166, maxWidth: .infinity)
                .zIndex(30)
            PlannerDateControl(deadline: $draftDeadline)
            PlannerTimeControl(deadline: $draftDeadline, hasExactTime: $draftHasExactTime)
            planButton
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface.opacity(0.55))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .zIndex(20)
    }

    private var composerTitleField: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(cf(14, .medium))
                .foregroundStyle(Theme.accent)
            TextField("What will you finish?", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(cf(14))
                .foregroundStyle(Theme.textPrimary)
                .focused($titleFocused)
                .onSubmit(addCommitment)
        }
        .frame(minWidth: 190)
    }

    private var planButton: some View {
        Button { addCommitment() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.right")
                    .font(cf(9.5, .bold))
                Text("Plan")
            }
            .font(cf(11.5, .semibold))
            .padding(.horizontal, 14)
            .frame(minWidth: 70, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.current.isLight ? SwiftUI.Color.white : Theme.appBackground)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
        .shadow(color: Theme.accent.opacity(canAdd ? 0.18 : 0), radius: 8, y: 3)
        .opacity(canAdd ? 1 : 0.42)
        .disabled(!canAdd)
    }

    private var canAdd: Bool {
        !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekDays.enumerated()), id: \.element) { index, day in
                dayCell(day)
                if index < weekDays.count - 1 {
                    Rectangle().fill(Theme.border.opacity(0.7)).frame(width: 1)
                }
            }
        }
        .frame(height: 63)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface.opacity(0.17)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border.opacity(0.8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func dayCell(_ day: Date) -> some View {
        let counts = counts(on: day)
        let isToday = calendar.isDateInToday(day)
        let isDraftDay = calendar.isDate(day, inSameDayAs: draftDeadline)
        return Button { selectDraftDay(day) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text(dayNumber(day))
                        .font(cf(14, .semibold))
                        .foregroundStyle(isToday ? Theme.appBackground : Theme.textSecondary)
                        .frame(width: 29, height: 29)
                        .background(RoundedRectangle(cornerRadius: 8).fill(isToday ? Theme.accent : .clear))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shortWeekday(day).uppercased())
                            .font(cf(9, .bold))
                            .tracking(0.7)
                            .foregroundStyle(Theme.textTertiary)
                        Text(countLabel(open: counts.open, done: counts.done))
                            .font(cf(9.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(spacing: 2) {
                    Text(shortWeekday(day).prefix(1).uppercased())
                        .font(cf(7.5, .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                    Text(dayNumber(day))
                        .font(cf(12.5, .semibold))
                        .foregroundStyle(isToday ? Theme.appBackground : Theme.textSecondary)
                        .frame(width: 25, height: 25)
                        .background(RoundedRectangle(cornerRadius: 7).fill(isToday ? Theme.accent : .clear))
                    Text(compactCountLabel(open: counts.open, done: counts.done))
                        .font(cf(7.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isDraftDay && !isToday ? Theme.accent.opacity(0.06) : .clear)
            .overlay(alignment: .topTrailing) {
                if counts.open > 0 {
                    Circle()
                        .fill(counts.hasOverdue ? Theme.waiting : Theme.running)
                        .frame(width: 5, height: 5)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var agenda: some View {
        if sections.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(cf(30, .light))
                    .foregroundStyle(Theme.textTertiary.opacity(0.65))
                Text("Nothing planned in this window")
                    .font(cf(15, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Add one clear finish line above.")
                    .font(cf(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 80)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 17) {
                    ForEach(sections) { section in
                        PlannerDaySectionView(
                            section: section,
                            highlightedID: highlightedID,
                            onToggle: state.togglePlannerCommitment,
                            onEdit: { editingCommitment = $0 },
                            onDelete: state.deletePlannerCommitment,
                            onOpenProject: state.openPlannerProject,
                            canOpenProject: { state.liveRef(for: $0) != nil }
                        )
                    }
                    Color.clear.frame(height: 16)
                }
                .padding(.trailing, 3)
            }
        }
    }

    private func addCommitment() {
        guard canAdd else { return }
        if let id = state.addPlannerCommitment(
            title: draftTitle,
            project: draftProject,
            deadline: draftDeadline,
            hasExactTime: draftHasExactTime
        ) {
            highlightedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if highlightedID == id { highlightedID = nil }
            }
        }
        draftTitle = ""
        titleFocused = true
    }

    private func moveWeek(_ days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: anchorDay) {
            withAnimation(.easeInOut(duration: 0.18)) { anchorDay = calendar.startOfDay(for: next) }
        }
    }

    private func goToToday() {
        withAnimation(.easeInOut(duration: 0.18)) { anchorDay = calendar.startOfDay(for: Date()) }
    }

    private func selectDraftDay(_ day: Date) {
        let components = calendar.dateComponents([.hour, .minute], from: draftDeadline)
        draftDeadline = calendar.date(
            bySettingHour: components.hour ?? 23,
            minute: components.minute ?? 59,
            second: 0,
            of: day
        ) ?? day
        titleFocused = true
    }

    private func counts(on day: Date) -> (open: Int, done: Int, hasOverdue: Bool) {
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let commitments = filteredCommitments.filter { $0.deadline >= day && $0.deadline < next }
        let open = commitments.lazy.filter { !$0.isCompleted }.count
        let done = commitments.count - open
        let hasOverdue = commitments.contains { !$0.isCompleted && $0.effectiveDeadline() < Date() }
        return (open, done, hasOverdue)
    }

    private func daySummary(open: Int, done: Int) -> String {
        switch (open, done) {
        case (0, let done): return "\(done) completed"
        case (let open, 0): return "\(open) planned"
        default: return "\(open) open · \(done) done"
        }
    }

    private func countLabel(open: Int, done: Int) -> String {
        if open == 0 && done == 0 { return "open" }
        if done == 0 { return "\(open) planned" }
        if open == 0 { return "\(done) done" }
        return "\(open) open · \(done) done"
    }

    private func compactCountLabel(open: Int, done: Int) -> String {
        let total = open + done
        if total == 0 { return "—" }
        return "\(total)"
    }

    private func relativeDayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        let formatter = DateFormatter(); formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }

    private func longDate(_ day: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }

    private func shortWeekday(_ day: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "EEE"
        return formatter.string(from: day)
    }

    private func dayNumber(_ day: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "d"
        return formatter.string(from: day)
    }

    private func dayIdentifier(_ day: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

/// A bounded, searchable filter surface. Unlike a native Menu, it cannot grow to the
/// height of the window, and it only contains projects represented in Planner—not every
/// shell Argus happens to know about.
private struct PlannerProjectFilterControl: View {
    @Binding var selection: String
    let options: [PlannerProjectOption]
    let onSelect: (String) -> Void

    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var presented = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var filteredOptions: [PlannerProjectOption] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(clean) }
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(cf(9.5, .semibold))
                Text(selection.isEmpty ? "All projects" : selection)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(cf(8, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(cf(10.5, .medium))
            .foregroundStyle(selection.isEmpty ? Theme.textSecondary : Theme.accent)
            .padding(.horizontal, 10)
            .frame(minWidth: 112, maxWidth: 170, minHeight: 29, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                selection.isEmpty ? Theme.border : Theme.accent.opacity(0.42), lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help("Filter the agenda by project")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Filter Planner")
                            .font(cf(13.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Only projects with planned finish lines")
                            .font(cf(9.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if !selection.isEmpty {
                        Button("Clear") { choose("") }
                            .font(cf(10.5, .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 12)
                .padding(.bottom, 10)

                if options.count > 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(cf(10))
                            .foregroundStyle(Theme.textTertiary)
                        TextField("Find project", text: $query)
                            .textFieldStyle(.plain)
                            .font(cf(11.5))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($searchFocused)
                            .onSubmit {
                                if let first = filteredOptions.first { choose(first.name) }
                            }
                            .onExitCommand { presented = false }
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(cf(10))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 33)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
                }

                Divider().opacity(0.75)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        filterRow(name: "All projects", count: nil, selected: selection.isEmpty) {
                            choose("")
                        }

                        if filteredOptions.isEmpty {
                            Text(options.isEmpty ? "Add a plan with a project to filter it here."
                                 : "No matching projects")
                                .font(cf(10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(filteredOptions) { option in
                                filterRow(
                                    name: option.name,
                                    count: option.count,
                                    selected: selection.caseInsensitiveCompare(option.name) == .orderedSame
                                ) { choose(option.name) }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 248)
            }
            .frame(width: 292)
            .background(Theme.appBackground)
            .onAppear {
                query = ""
                if options.count > 6 {
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
        }
    }

    private func filterRow(name: String, count: Int?, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(cf(11))
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary.opacity(0.65))
                Text(name)
                    .font(cf(11.5, selected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let count {
                    Text("\(count)")
                        .font(cf(9.5, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                selected ? Theme.accent.opacity(0.09) : .clear
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ project: String) {
        selection = project
        onSelect(project)
        query = ""
        presented = false
    }
}

/// A real typeahead instead of a TextField bolted to an unrelated menu. It keeps
/// arbitrary project labels valid while making existing sessions/projects one click
/// away, and it never rewrites the user's text behind their back.
private struct PlannerProjectAutocomplete: View {
    @Binding var text: String
    let projects: [String]
    var dropdownWidth: CGFloat = 230

    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @FocusState private var focused: Bool
    @State private var showSuggestions = false
    @State private var selectedIndex = 0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var suggestions: [String] {
        PlannerProjectSuggestions.filtered(projects, query: text)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(cf(10, .medium))
                .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.accent)
            TextField("Project", text: $text)
                .textFieldStyle(.plain)
                .font(cf(11))
                .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .focused($focused)
                .onSubmit(acceptHighlightedSuggestion)
                .onMoveCommand(perform: moveHighlight)
                .onExitCommand {
                    showSuggestions = false
                    focused = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    selectedIndex = 0
                    focused = true
                    showSuggestions = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(cf(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear project")
            }
            Button {
                focused = true
                showSuggestions = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(cf(8, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 12, height: 22)
            }
            .buttonStyle(.plain)
            .help("Show projects")
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.appBackground.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            focused ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1
        ))
        .overlay(alignment: .topLeading) {
            if showSuggestions && focused {
                GeometryReader { geometry in
                    suggestionDropdown(width: max(dropdownWidth, geometry.size.width))
                        .offset(y: 39)
                        .zIndex(100)
                }
            }
        }
        .onChange(of: focused) { isFocused in
            showSuggestions = isFocused
            if isFocused { selectedIndex = 0 }
        }
        .onChange(of: text) { _ in
            selectedIndex = 0
            if focused { showSuggestions = true }
        }
    }

    private func suggestionDropdown(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "RECENT PROJECTS" : "MATCHING PROJECTS")
                .font(cf(8, .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 7)

            if suggestions.isEmpty {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "No projects yet" : "Press Return to use this project")
                    .font(cf(10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.element) { index, project in
                    Button { choose(project) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(cf(9))
                                .foregroundStyle(Theme.accent)
                            Text(project)
                                .font(cf(11, index == selectedIndex ? .semibold : .regular))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if project.caseInsensitiveCompare(text) == .orderedSame {
                                Image(systemName: "checkmark")
                                    .font(cf(8, .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 29)
                        .background(RoundedRectangle(cornerRadius: 6).fill(
                            index == selectedIndex ? Theme.selection.opacity(0.85) : .clear
                        ))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.sidebarBackground)
                .shadow(color: .black.opacity(0.30), radius: 16, y: 7)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func choose(_ project: String) {
        focused = false
        showSuggestions = false
        text = project
    }

    private func acceptHighlightedSuggestion() {
        guard showSuggestions, suggestions.indices.contains(selectedIndex) else {
            showSuggestions = false
            focused = false
            return
        }
        choose(suggestions[selectedIndex])
    }

    private func moveHighlight(_ direction: MoveCommandDirection) {
        guard !suggestions.isEmpty else { return }
        showSuggestions = true
        switch direction {
        case .down: selectedIndex = min(suggestions.count - 1, selectedIndex + 1)
        case .up: selectedIndex = max(0, selectedIndex - 1)
        default: break
        }
    }
}

private struct PlannerDateControl: View {
    @Binding var deadline: Date
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var showPicker = false
    private let calendar = Calendar.current

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(cf(10, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(dateLabel)
                    .font(cf(11, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(cf(8, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 106, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.appBackground.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                showPicker ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("DEADLINE DATE")
                    .font(cf(9, .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 7) {
                    quickDay("Today", date: Date())
                    quickDay("Tomorrow", date: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
                }
                DatePicker("", selection: dayBinding, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
                HStack {
                    Spacer()
                    Button("Done") { showPicker = false }
                        .font(cf(11, .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                        .padding(.horizontal, 13)
                        .frame(height: 29)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                }
            }
            .padding(14)
            .frame(width: 280)
            .background(Theme.appBackground)
        }
    }

    private var dateLabel: String {
        if calendar.isDateInToday(deadline) { return "Today" }
        if calendar.isDateInTomorrow(deadline) { return "Tomorrow" }
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d"
        return formatter.string(from: deadline)
    }

    private var dayBinding: Binding<Date> {
        Binding(get: { deadline }, set: { setDay($0) })
    }

    private func quickDay(_ title: String, date: Date) -> some View {
        let selected = calendar.isDate(deadline, inSameDayAs: date)
        return Button {
            setDay(date)
            showPicker = false
        } label: {
            Text(title)
                .font(cf(10.5, .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 29)
                .background(RoundedRectangle(cornerRadius: 7).fill(
                    selected ? Theme.accent.opacity(0.10) : Theme.surface.opacity(0.45)
                ))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                    selected ? Theme.accent.opacity(0.42) : Theme.border, lineWidth: 1
                ))
        }
        .buttonStyle(.plain)
    }

    private func setDay(_ day: Date) {
        let components = calendar.dateComponents([.hour, .minute, .second], from: deadline)
        deadline = calendar.date(
            bySettingHour: components.hour ?? 23,
            minute: components.minute ?? 59,
            second: components.second ?? 0,
            of: day
        ) ?? day
    }
}

private struct PlannerTimeControl: View {
    @Binding var deadline: Date
    @Binding var hasExactTime: Bool
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var showPicker = false
    private let calendar = Calendar.current

    private let presets: [(String, Int, Int)] = [
        ("9:00 AM", 9, 0), ("12:00 PM", 12, 0),
        ("5:00 PM", 17, 0), ("11:59 PM", 23, 59),
    ]

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: hasExactTime ? "clock" : "sunset")
                    .font(cf(10, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(timeLabel)
                    .font(cf(11, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(cf(8, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 105, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.appBackground.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                showPicker ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("DEADLINE TIME")
                    .font(cf(9, .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(presets, id: \.0) { preset in
                        presetButton(preset.0, hour: preset.1, minute: preset.2)
                    }
                }

                Button {
                    hasExactTime = false
                    showPicker = false
                } label: {
                    HStack {
                        Image(systemName: "sunset")
                        Text("End of day — no exact time")
                        Spacer()
                        if !hasExactTime { Image(systemName: "checkmark") }
                    }
                    .font(cf(10.5, .medium))
                    .foregroundStyle(!hasExactTime ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 31)
                    .background(RoundedRectangle(cornerRadius: 7).fill(
                        !hasExactTime ? Theme.accent.opacity(0.10) : Theme.surface.opacity(0.45)
                    ))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                        !hasExactTime ? Theme.accent.opacity(0.42) : Theme.border, lineWidth: 1
                    ))
                }
                .buttonStyle(.plain)

                Divider()
                HStack {
                    Text("Custom")
                        .font(cf(10.5, .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    DatePicker("", selection: exactTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .font(cf(11))
                }
                HStack {
                    Spacer()
                    Button("Done") { showPicker = false }
                        .font(cf(11, .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                        .padding(.horizontal, 13)
                        .frame(height: 29)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                }
            }
            .padding(14)
            .frame(width: 260)
            .background(Theme.appBackground)
        }
    }

    private var timeLabel: String {
        guard hasExactTime else { return "End of day" }
        let formatter = DateFormatter(); formatter.dateFormat = "h:mm a"
        return formatter.string(from: deadline)
    }

    private var exactTimeBinding: Binding<Date> {
        Binding(get: { deadline }, set: {
            deadline = $0
            hasExactTime = true
        })
    }

    private func presetButton(_ title: String, hour: Int, minute: Int) -> some View {
        let selected = hasExactTime
            && calendar.component(.hour, from: deadline) == hour
            && calendar.component(.minute, from: deadline) == minute
        return Button {
            deadline = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: deadline) ?? deadline
            hasExactTime = true
            showPicker = false
        } label: {
            HStack {
                Text(title)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark") }
            }
            .font(cf(10.5, .medium))
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                selected ? Theme.accent.opacity(0.10) : Theme.surface.opacity(0.45)
            ))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                selected ? Theme.accent.opacity(0.42) : Theme.border, lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
    }
}

private struct PlannerDaySection: Identifiable {
    let id: String
    let day: Date?
    let title: String
    let subtitle: String
    let summary: String
    let commitments: [PlannerCommitment]
    let showsDateInRows: Bool
}

private struct PlannerDaySectionView: View {
    let section: PlannerDaySection
    let highlightedID: UUID?
    let onToggle: (UUID) -> Void
    let onEdit: (PlannerCommitment) -> Void
    let onDelete: (UUID) -> Void
    let onOpenProject: (PlannerCommitment) -> Void
    let canOpenProject: (PlannerCommitment) -> Bool
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        PlannerSectionLayout(sidebarWidth: 128, verticalSpacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(cf(12.5, .semibold))
                    .foregroundStyle(section.day == nil ? Theme.waiting : Theme.textPrimary)
                Text(section.subtitle)
                    .font(cf(10))
                    .foregroundStyle(Theme.textTertiary)
                Text(section.summary)
                    .font(cf(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 7)
            }
            .padding(.top, 3)

            VStack(spacing: 8) {
                ForEach(section.commitments) { commitment in
                    PlannerCommitmentRow(
                        commitment: commitment,
                        showsDate: section.showsDateInRows,
                        highlighted: highlightedID == commitment.id,
                        canOpenProject: canOpenProject(commitment),
                        onToggle: { onToggle(commitment.id) },
                        onEdit: { onEdit(commitment) },
                        onDelete: { onDelete(commitment.id) },
                        onOpenProject: { onOpenProject(commitment) }
                    )
                }
            }
            .padding(.leading, 18)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.border.opacity(0.72)).frame(width: 1)
            }
        }
    }
}

private struct PlannerCommitmentRow: View {
    let commitment: PlannerCommitment
    let showsDate: Bool
    let highlighted: Bool
    let canOpenProject: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenProject: () -> Void

    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var hovering = false

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var overdue: Bool {
        !commitment.isCompleted && commitment.effectiveDeadline() < Date()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if showsDate {
                    Text(shortDate(commitment.deadline))
                        .font(cf(9.5, .medium))
                        .foregroundStyle(overdue ? Theme.waiting : Theme.textTertiary)
                }
                Text(timeLabel)
                    .font(cf(10.5, .medium))
                    .foregroundStyle(overdue ? Theme.waiting : Theme.textSecondary)
                    .monospacedDigit()
                if !commitment.hasExactTime {
                    Text("NO EXACT TIME")
                        .font(cf(7.5, .medium))
                        .tracking(0.35)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 82, alignment: .leading)

            Button(action: onToggle) {
                Image(systemName: commitment.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(cf(16))
                    .foregroundStyle(commitment.isCompleted ? Theme.attached : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(commitment.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 3) {
                Text(commitment.title)
                    .font(cf(13.5, .semibold))
                    .foregroundStyle(commitment.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(commitment.isCompleted, color: Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !commitment.project.isEmpty {
                    HStack(spacing: 4) {
                        Text(commitment.project)
                            .foregroundStyle(Theme.accent)
                        if canOpenProject { Image(systemName: "arrow.up.right").font(cf(7.5, .semibold)) }
                    }
                    .font(cf(9.5))
                    .onTapGesture { if canOpenProject { onOpenProject() } }
                    .help(canOpenProject ? "Open \(commitment.project)" : "Project")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(statusLabel(at: context.date))
                    .font(cf(9.5, .medium))
                    .foregroundStyle(overdue ? Theme.waiting : Theme.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 62, alignment: .trailing)
            }

            Menu {
                Button("Edit…", action: onEdit)
                if canOpenProject { Button("Open project", action: onOpenProject) }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(cf(11, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0.52)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: 1)
        )
        .opacity(commitment.isCompleted ? 0.58 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit…", action: onEdit)
            if canOpenProject { Button("Open project", action: onOpenProject) }
            Button(commitment.isCompleted ? "Mark incomplete" : "Mark complete", action: onToggle)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var rowFill: Color {
        if overdue { return Theme.waiting.opacity(0.055) }
        if highlighted { return Theme.accent.opacity(0.065) }
        return Theme.surface.opacity(0.43)
    }

    private var rowBorder: Color {
        if overdue { return Theme.waiting.opacity(0.30) }
        if highlighted { return Theme.accent.opacity(0.38) }
        return Theme.border.opacity(0.88)
    }

    private var timeLabel: String {
        guard commitment.hasExactTime else { return "END OF DAY" }
        let formatter = DateFormatter(); formatter.dateFormat = "h:mm a"
        return formatter.string(from: commitment.deadline)
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func statusLabel(at now: Date) -> String {
        if commitment.isCompleted { return "done" }
        let deadline = commitment.effectiveDeadline()
        if deadline < now { return "overdue" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: deadline, relativeTo: now)
    }
}

private struct PlannerEditorView: View {
    let commitment: PlannerCommitment
    let knownProjects: [String]

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var title: String
    @State private var project: String
    @State private var deadline: Date
    @State private var hasExactTime: Bool

    init(commitment: PlannerCommitment, knownProjects: [String]) {
        self.commitment = commitment
        self.knownProjects = knownProjects
        _title = State(initialValue: commitment.title)
        _project = State(initialValue: commitment.project)
        _deadline = State(initialValue: commitment.deadline)
        _hasExactTime = State(initialValue: commitment.hasExactTime)
    }

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                    .font(cf(16))
                    .foregroundStyle(Theme.accent)
                Text("Edit commitment")
                    .font(cf(17, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                plannerEditorField("Finish line") {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle")
                            .font(cf(12))
                            .foregroundStyle(Theme.accent)
                        TextField("What will you finish?", text: $title)
                            .textFieldStyle(.plain)
                            .font(cf(14))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                }
                plannerEditorField("Project (optional)") {
                    PlannerProjectAutocomplete(
                        text: $project,
                        projects: knownProjects,
                        dropdownWidth: 360
                    )
                    .frame(maxWidth: .infinity)
                    .zIndex(30)
                }
                plannerEditorField("Deadline") {
                    HStack(spacing: 9) {
                        PlannerDateControl(deadline: $deadline)
                        PlannerTimeControl(deadline: $deadline, hasExactTime: $hasExactTime)
                        Spacer()
                        Text(hasExactTime ? "Exact deadline" : "Due by the end of the selected day")
                            .font(cf(10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(18)
            .zIndex(10)

            Spacer()
            Divider()
            HStack {
                Button(role: .destructive) {
                    state.deletePlannerCommitment(commitment.id)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(cf(11, .medium))
                        .foregroundStyle(Theme.waiting)
                        .padding(.horizontal, 11)
                        .frame(height: 31)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.waiting.opacity(0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                            Theme.waiting.opacity(0.28), lineWidth: 1
                        ))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { dismiss() } label: {
                    Text("Cancel")
                        .font(cf(11, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 13)
                        .frame(height: 31)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.45)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                Button {
                    state.updatePlannerCommitment(
                        commitment.id,
                        title: title,
                        project: project,
                        deadline: deadline,
                        hasExactTime: hasExactTime
                    )
                    dismiss()
                } label: {
                    Text("Save changes")
                        .font(cf(11, .semibold))
                        .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                        .padding(.horizontal, 14)
                        .frame(height: 31)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .opacity(canSave ? 1 : 0.42)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 560, height: 390)
        .background(Theme.appBackground)
    }

    private func plannerEditorField<Content: View>(_ label: String,
                                                    @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(cf(11, .semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

/// Preserves the mockup's date rail at comfortable widths and moves that metadata above
/// the cards when the detail pane is narrow. The commitment rows themselves are never
/// squeezed behind a permanently reserved 128-point column.
private struct PlannerSectionLayout: Layout {
    var sidebarWidth: CGFloat
    var verticalSpacing: CGFloat

    private func horizontal(_ width: CGFloat) -> Bool { width >= 600 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }
        let width = proposal.width ?? 700
        if horizontal(width) {
            let sidebar = subviews[0].sizeThatFits(ProposedViewSize(width: sidebarWidth, height: nil))
            let content = subviews[1].sizeThatFits(ProposedViewSize(width: width - sidebarWidth, height: nil))
            return CGSize(width: width, height: max(sidebar.height, content.height))
        }
        let sidebar = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let content = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: sidebar.height + verticalSpacing + content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        if horizontal(bounds.width) {
            subviews[0].place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: sidebarWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + sidebarWidth, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width - sidebarWidth, height: bounds.height)
            )
            return
        }
        let sidebar = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: sidebar.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + sidebar.height + verticalSpacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: max(0, bounds.height - sidebar.height - verticalSpacing)
            )
        )
    }
}

/// Keeps the title and navigation on one row when possible, then intentionally wraps
/// them into a balanced two-row header. This avoids the clipped next-arrow/close button
/// that a shrinking HStack produced beside the sidebar.
private struct PlannerHeaderLayout: Layout {
    var spacing: CGFloat

    private func controlSizes(_ subviews: Subviews) -> (filter: CGSize, actions: CGSize) {
        guard subviews.count >= 3 else { return (.zero, .zero) }
        return (subviews[1].sizeThatFits(.unspecified), subviews[2].sizeThatFits(.unspecified))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard subviews.count >= 3 else { return .zero }
        let width = proposal.width ?? 720
        let controls = controlSizes(subviews)
        let oneRow = width >= 230 + controls.filter.width + controls.actions.width + spacing * 2
        let identityWidth = oneRow
            ? max(220, width - controls.filter.width - controls.actions.width - spacing * 2)
            : width
        let identity = subviews[0].sizeThatFits(ProposedViewSize(width: identityWidth, height: nil))
        if oneRow {
            return CGSize(width: width, height: max(identity.height, controls.filter.height, controls.actions.height))
        }
        return CGSize(
            width: width,
            height: identity.height + spacing + max(controls.filter.height, controls.actions.height)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 3 else { return }
        let controls = controlSizes(subviews)
        let oneRow = bounds.width >= 230 + controls.filter.width + controls.actions.width + spacing * 2
        if oneRow {
            let identityWidth = max(
                220,
                bounds.width - controls.filter.width - controls.actions.width - spacing * 2
            )
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: identityWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - controls.actions.width - spacing, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: controls.filter.width, height: controls.filter.height)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                proposal: ProposedViewSize(width: controls.actions.width, height: controls.actions.height)
            )
            return
        }

        let identity = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: identity.height)
        )
        let controlsY = bounds.minY + identity.height + spacing
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: controlsY), anchor: .topLeading,
            proposal: ProposedViewSize(width: controls.filter.width, height: controls.filter.height)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: controlsY), anchor: .topTrailing,
            proposal: ProposedViewSize(width: controls.actions.width, height: controls.actions.height)
        )
    }
}

/// Responsive composer with one instance of every stateful field. It has four deliberate
/// modes: one row, title plus controls, a narrow three-row form, and an emergency layout
/// for very small panes. No row is ever placed wider than its available bounds.
private struct PlannerComposerLayout: Layout {
    var spacing: CGFloat

    private enum Mode { case oneRow, twoRows, threeRows, fourRows }

    private struct Metrics {
        let width: CGFloat
        let sizes: [CGSize]
        let controlsWidth: CGFloat
        let trailingWidth: CGFloat
        let dateTimeWidth: CGFloat
        let mode: Mode
    }

    private func measurements(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Metrics {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        let width = proposal.width ?? naturalWidth
        guard sizes.count >= 5 else {
            return Metrics(
                width: width, sizes: sizes, controlsWidth: 0,
                trailingWidth: 0, dateTimeWidth: 0, mode: .oneRow
            )
        }
        let controlsWidth = sizes[1...4].map(\.width).reduce(0, +) + spacing * 3
        let trailingWidth = sizes[2...4].map(\.width).reduce(0, +) + spacing * 2
        let dateTimeWidth = sizes[2].width + spacing + sizes[3].width
        let mode: Mode
        if width >= controlsWidth + spacing + 220 { mode = .oneRow }
        else if width >= controlsWidth { mode = .twoRows }
        else if width >= trailingWidth { mode = .threeRows }
        else { mode = .fourRows }
        return Metrics(
            width: width, sizes: sizes, controlsWidth: controlsWidth,
            trailingWidth: trailingWidth, dateTimeWidth: dateTimeWidth, mode: mode
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let m = measurements(proposal, subviews)
        guard subviews.count >= 5 else {
            let height = m.sizes.map(\.height).max() ?? 0
            return CGSize(width: m.width, height: height)
        }
        let titleWidth = m.mode == .oneRow
            ? max(190, m.width - m.controlsWidth - spacing)
            : m.width
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        let controlsHeight = m.sizes[1...4].map(\.height).max() ?? 0
        switch m.mode {
        case .oneRow:
            return CGSize(width: m.width, height: max(title.height, controlsHeight))
        case .twoRows:
            return CGSize(width: m.width, height: title.height + spacing + controlsHeight)
        case .threeRows:
            return CGSize(
                width: m.width,
                height: title.height + spacing + m.sizes[1].height + spacing
                    + m.sizes[2...4].map(\.height).max()!
            )
        case .fourRows:
            return CGSize(
                width: m.width,
                height: title.height + spacing + m.sizes[1].height + spacing
                    + max(m.sizes[2].height, m.sizes[3].height) + spacing + m.sizes[4].height
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let m = measurements(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        guard subviews.count >= 5 else {
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: m.sizes[index].width, height: bounds.height)
                )
                x += m.sizes[index].width + spacing
            }
            return
        }

        let titleWidth = m.mode == .oneRow
            ? max(190, bounds.width - m.controlsWidth - spacing)
            : bounds.width
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        if m.mode == .oneRow {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: titleWidth, height: bounds.height)
            )
            placeRow(indices: Array(1...4), from: bounds.maxX - m.controlsWidth,
                     centerY: bounds.midY, metrics: m, subviews: subviews)
            return
        }

        subviews[0].place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: title.height)
        )
        let secondY = bounds.minY + title.height + spacing
        if m.mode == .twoRows {
            placeRow(indices: Array(1...4), from: bounds.maxX - m.controlsWidth,
                     topY: secondY, metrics: m, subviews: subviews)
            return
        }

        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: secondY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: m.sizes[1].height)
        )
        let thirdY = secondY + m.sizes[1].height + spacing
        if m.mode == .threeRows {
            placeRow(indices: Array(2...4), from: bounds.maxX - m.trailingWidth,
                     topY: thirdY, metrics: m, subviews: subviews)
            return
        }

        placeRow(indices: [2, 3], from: bounds.minX, topY: thirdY,
                 metrics: m, subviews: subviews)
        let fourthY = thirdY + max(m.sizes[2].height, m.sizes[3].height) + spacing
        subviews[4].place(
            at: CGPoint(x: bounds.maxX, y: fourthY), anchor: .topTrailing,
            proposal: ProposedViewSize(width: m.sizes[4].width, height: m.sizes[4].height)
        )
    }

    private func placeRow(indices: [Int], from startX: CGFloat, topY: CGFloat? = nil,
                          centerY: CGFloat? = nil, metrics: Metrics, subviews: Subviews) {
        var x = startX
        for index in indices {
            let size = metrics.sizes[index]
            if let centerY {
                subviews[index].place(
                    at: CGPoint(x: x, y: centerY), anchor: .leading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
            } else {
                subviews[index].place(
                    at: CGPoint(x: x, y: topY ?? 0), anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
            }
            x += size.width + spacing
        }
    }
}
