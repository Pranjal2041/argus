import SwiftUI

/// Planner is deliberately a rolling list of finish lines, not a general calendar.
/// The interface keeps one invariant visible everywhere: earlier deadlines come first.
struct PlannerView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    @State private var anchorDay = Calendar.current.startOfDay(for: Date())
    @State private var draftTitle = ""
    @State private var draftProject = ""
    @State private var draftDeadline = PlannerView.defaultDeadline()
    @State private var draftHasExactTime = true
    @State private var editingCommitment: PlannerCommitment?
    @State private var highlightedID: UUID?
    @FocusState private var titleFocused: Bool

    private let calendar = Calendar.current

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    private static func defaultDeadline() -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: tomorrow) ?? tomorrow
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
        return Array(Set(live + retained)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var visibleOpenCount: Int {
        state.plannerCommitments.lazy.filter { commitment in
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
            let overdue = state.plannerCommitments.filter {
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
            let commitments = state.plannerCommitments.filter {
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
            }
            Spacer()
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
        if visibleOpenCount == 0 { return "No open commitments in this 7-day horizon" }
        return "\(visibleOpenCount) open commitment\(visibleOpenCount == 1 ? "" : "s") · ordered by deadline"
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
            composerControls
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface.opacity(0.55))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
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

    private var composerControls: some View {
        HStack(spacing: 9) {
            projectField
                .frame(width: 154)

            DatePicker("", selection: $draftDeadline, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .font(cf(11))
                .fixedSize()

            Button { draftHasExactTime.toggle() } label: {
                Image(systemName: draftHasExactTime ? "clock.fill" : "sunset")
                    .font(cf(11, .medium))
                    .foregroundStyle(draftHasExactTime ? Theme.accent : Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .help(draftHasExactTime ? "Use an end-of-day deadline" : "Use an exact time")

            Group {
                if draftHasExactTime {
                    DatePicker("", selection: $draftDeadline, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .font(cf(11))
                } else {
                    Text("End of day")
                        .font(cf(11, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 76)
                }
            }
            .fixedSize()

            Button("Plan") { addCommitment() }
                .font(cf(12, .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.current.isLight ? SwiftUI.Color.white : Theme.appBackground)
                .padding(.horizontal, 14)
                .frame(minWidth: 58, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .opacity(canAdd ? 1 : 0.42)
                .disabled(!canAdd)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var projectField: some View {
        HStack(spacing: 4) {
            TextField("Project", text: $draftProject)
                .textFieldStyle(.plain)
                .font(cf(11))
                .foregroundStyle(draftProject.isEmpty ? Theme.textTertiary : Theme.accent)
                .lineLimit(1)
            if !knownProjects.isEmpty {
                Menu {
                    Button("No project") { draftProject = "" }
                    Divider()
                    ForEach(knownProjects, id: \.self) { project in
                        Button(project) { draftProject = project }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(cf(9, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.appBackground.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
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
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(countLabel(open: counts.open, done: counts.done))
                        .font(cf(9.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
            bySettingHour: components.hour ?? 12,
            minute: components.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
        titleFocused = true
    }

    private func counts(on day: Date) -> (open: Int, done: Int, hasOverdue: Bool) {
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let commitments = state.plannerCommitments.filter { $0.deadline >= day && $0.deadline < next }
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
        HStack(alignment: .top, spacing: 0) {
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
            .frame(width: 128, alignment: .leading)
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
                    TextField("What will you finish?", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(cf(14))
                }
                plannerEditorField("Project (optional)") {
                    HStack(spacing: 7) {
                        TextField("Project", text: $project)
                            .textFieldStyle(.roundedBorder)
                            .font(cf(14))
                        if !knownProjects.isEmpty {
                            Menu {
                                Button("No project") { project = "" }
                                Divider()
                                ForEach(knownProjects, id: \.self) { value in
                                    Button(value) { project = value }
                                }
                            } label: {
                                Image(systemName: "chevron.down").font(cf(11, .semibold))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                }
                plannerEditorField("Deadline") {
                    HStack(spacing: 12) {
                        DatePicker("Date", selection: $deadline, displayedComponents: .date)
                            .datePickerStyle(.field)
                        Toggle("Exact time", isOn: $hasExactTime)
                            .toggleStyle(.switch)
                            .font(cf(12))
                        if hasExactTime {
                            DatePicker("Time", selection: $deadline, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.field)
                        } else {
                            Text("By end of day")
                                .font(cf(12, .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(18)

            Spacer()
            Divider()
            HStack {
                Button("Delete", role: .destructive) {
                    state.deletePlannerCommitment(commitment.id)
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    state.updatePlannerCommitment(
                        commitment.id,
                        title: title,
                        project: project,
                        deadline: deadline,
                        hasExactTime: hasExactTime
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 540, height: 365)
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

/// Keeps the composer compact at normal Argus widths without allowing controls to
/// collapse when the sidebar leaves a narrow detail pane. The same subviews are laid out
/// once—horizontal when they fit, title above controls when they do not—so focus and
/// DatePicker state remain stable during window resizing.
private struct PlannerComposerLayout: Layout {
    var spacing: CGFloat

    private func measurements(_ proposal: ProposedViewSize,
                              _ subviews: Subviews) -> (width: CGFloat, controls: CGSize, horizontal: Bool) {
        let controls = subviews.count > 1 ? subviews[1].sizeThatFits(.unspecified) : .zero
        let naturalTitle = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        let naturalWidth = naturalTitle.width + spacing + controls.width
        let width = proposal.width ?? naturalWidth
        let horizontal = width >= controls.width + spacing + 230
        return (width, controls, horizontal)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let m = measurements(proposal, subviews)
        if subviews.count == 1 {
            return subviews[0].sizeThatFits(ProposedViewSize(width: m.width, height: proposal.height))
        }
        if m.horizontal {
            let titleWidth = max(190, m.width - m.controls.width - spacing)
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
            return CGSize(width: m.width, height: max(title.height, m.controls.height))
        }
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: m.width, height: nil))
        return CGSize(width: m.width, height: title.height + spacing + m.controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let m = measurements(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        if m.horizontal {
            let titleWidth = max(190, bounds.width - m.controls.width - spacing)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: titleWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: m.controls.width, height: bounds.height)
            )
        } else {
            let title = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: title.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + title.height + spacing),
                anchor: .topTrailing,
                proposal: ProposedViewSize(width: m.controls.width, height: m.controls.height)
            )
        }
    }
}
