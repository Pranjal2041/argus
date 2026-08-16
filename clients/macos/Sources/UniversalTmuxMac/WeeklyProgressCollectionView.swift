import SwiftUI

/// Read-only browsing for the virtual All-projects collection and a project's
/// calendar history. Generation and editing stay in the focused week workspace.
struct WeeklyProgressCollectionView: View {
    let mode: WeeklyProgressBrowseMode
    let generations: [WeeklyProgressGeneration]
    let selectedWeek: WeeklyProgressWeek
    let aggregate: Bool
    let operationProjectID: UUID?
    let operationWeekStart: Date?
    let onRead: (WeeklyProgressGeneration, Int) -> Void
    let onOpenWeek: (WeeklyProgressProject, WeeklyProgressWeek) -> Void
    let onOpenDeck: (WeeklyProgressGeneration) -> Void
    let onReveal: (WeeklyProgressGeneration) -> Void

    @AppStorage("ut.uiScale") private var uiScale = 1.0

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Group {
            switch mode {
            case .selectedWeek:
                selectedWeekGallery
            case .calendarList:
                calendarList
            }
        }
    }

    @ViewBuilder
    private var selectedWeekGallery: some View {
        let entries = WeeklyProgressGenerationCatalog.entries(
            for: selectedWeek,
            in: generations
        )
        if entries.isEmpty {
            emptyState(
                icon: "rectangle.stack.badge.minus",
                title: aggregate ? "No project reviews this week" : "No review for this week",
                detail: aggregate
                    ? "Choose another week, or open a project to generate its first review."
                    : "Generate this week from the project workspace when you are ready."
            )
        } else {
            LazyVStack(spacing: 14) {
                ForEach(entries) { entry in
                    deckCard(entry, showWeekAction: aggregate)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarList: some View {
        let sections = WeeklyProgressGenerationCatalog.calendarSections(in: generations)
        if sections.isEmpty {
            emptyState(
                icon: "calendar.badge.exclamationmark",
                title: "No weekly reviews yet",
                detail: aggregate
                    ? "Finished reviews from every project will appear here by week."
                    : "This project's finished and in-progress reviews will appear here by week."
            )
        } else {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(cf(10.5, .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(aggregate ? "Every project, grouped Monday through Sunday" : "One review row for each recorded week")
                        .font(cf(10.8, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 2)

                LazyVStack(spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        calendarSection(section, isLast: index == sections.count - 1)
                    }
                }
            }
        }
    }

    private func calendarSection(
        _ section: WeeklyProgressCalendarSection,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(month(section.week.start))
                    .font(cf(9.5, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.accent)
                Text(day(section.week.start))
                    .font(cf(25, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(year(section.week.start))
                    .font(cf(9.8, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 58, alignment: .leading)

            VStack(spacing: 0) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Theme.appBackground, lineWidth: 2))
                if !isLast {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 10)

            VStack(alignment: .leading, spacing: 10) {
                Text(weekRange(section.week))
                    .font(cf(12.5, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 1)
                ForEach(section.entries) { entry in
                    deckCard(entry, showWeekAction: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func deckCard(
        _ entry: WeeklyProgressDeckEntry,
        showWeekAction: Bool
    ) -> some View {
        let latest = entry.latest
        let readable = entry.latestComplete
        let active = operationProjectID == latest.manifest.project.id
            && operationWeekStart == latest.manifest.week.start
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    onOpenWeek(latest.manifest.project, latest.manifest.week)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latest.manifest.project.name)
                            .font(cf(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(statusDetail(entry, active: active))
                            if entry.versionCount > 1 {
                                Text("·")
                                Text("\(entry.versionCount) versions")
                            }
                        }
                        .font(cf(10.4))
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                statusPill(latest.manifest.stage, active: active)

                if let readable {
                    Button {
                        onRead(readable, 0)
                    } label: {
                        Label("Read slides", systemImage: "rectangle.stack")
                            .font(cf(10.8, .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 29)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                } else if showWeekAction {
                    Button("Open week") {
                        onOpenWeek(latest.manifest.project, latest.manifest.week)
                    }
                    .buttonStyle(.plain)
                    .font(cf(10.8, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 29)
                }

                if let readable {
                    Menu {
                        Button("Open PowerPoint") { onOpenDeck(readable) }
                        Button("Show Files in Finder") { onReveal(readable) }
                        Button("Open Project Week") {
                            onOpenWeek(latest.manifest.project, latest.manifest.week)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(cf(11.5, .semibold))
                            .frame(width: 27, height: 29)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if let readable {
                if readable.manifest.id != latest.manifest.id {
                    Label(
                        "Showing the latest completed deck while a newer version is \(WeeklyProgressStagePresentation.title(latest.manifest.stage).lowercased()).",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(cf(9.8, .medium))
                    .foregroundStyle(Theme.textTertiary)
                }
                WeeklyProgressSlideStrip(generation: readable, onRead: onRead)
            } else {
                HStack(spacing: 9) {
                    if active {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: latest.manifest.stage == .failed
                              ? "exclamationmark.triangle" : "clock")
                            .foregroundStyle(latest.manifest.stage == .failed ? Theme.waiting : Theme.textTertiary)
                    }
                    Text(noDeckDetail(latest, active: active))
                        .font(cf(10.8))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBackground.opacity(0.44)))
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surface.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(active ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
        )
    }

    private func statusPill(_ stage: WeeklyProgressStage, active: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor(stage, active: active)).frame(width: 6, height: 6)
            Text(active ? "Generating" : WeeklyProgressStagePresentation.title(stage))
        }
        .font(cf(9.8, .semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(Theme.sidebarBackground.opacity(0.68)))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(cf(24, .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(cf(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(detail)
                .font(cf(11.2))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebarBackground.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func statusDetail(_ entry: WeeklyProgressDeckEntry, active: Bool) -> String {
        if active { return "Generating this review" }
        if entry.latest.manifest.stage == .complete {
            return "Generated " + shortTimestamp(entry.latest.manifest.createdAt)
        }
        if entry.latestComplete != nil {
            return "Updated " + shortTimestamp(entry.latest.manifest.updatedAt)
        }
        return WeeklyProgressStagePresentation.title(entry.latest.manifest.stage)
    }

    private func noDeckDetail(_ generation: WeeklyProgressGeneration, active: Bool) -> String {
        if active { return "The first readable deck will appear here as soon as it is verified." }
        if generation.manifest.stage == .failed {
            return "No completed deck yet. Open this project week to inspect or resume it."
        }
        return "This review has not produced a completed deck yet."
    }

    private func statusColor(_ stage: WeeklyProgressStage, active: Bool) -> Color {
        if active { return Theme.running }
        switch stage {
        case .complete: return Theme.attached
        case .failed: return Theme.waiting
        default: return Theme.textTertiary
        }
    }

    private func weekRange(_ week: WeeklyProgressWeek) -> String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: week.endExclusive)
            ?? week.endExclusive
        let start = DateFormatter(); start.dateFormat = "MMM d"
        let finish = DateFormatter(); finish.dateFormat = "MMM d, yyyy"
        return start.string(from: week.start) + " – " + finish.string(from: end)
    }

    private func shortTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private func month(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MMM"
        return formatter.string(from: date).uppercased()
    }

    private func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private func year(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }
}

private struct WeeklyProgressSlideStrip: View {
    let generation: WeeklyProgressGeneration
    let onRead: (WeeklyProgressGeneration, Int) -> Void

    @AppStorage("ut.uiScale") private var uiScale = 1.0
    @State private var slides: [URL] = []
    @State private var loaded = false

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Group {
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Loading slide previews…")
                        .font(cf(10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(height: 108)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if slides.isEmpty {
                Label("The deck is ready, but rendered slide previews are unavailable.", systemImage: "photo.on.rectangle.angled")
                    .font(cf(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: 56)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 10) {
                        ForEach(Array(slides.enumerated()), id: \.element) { index, url in
                            Button {
                                onRead(generation, index)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    WeeklyProgressLocalImage(url: url)
                                        .aspectRatio(16 / 9, contentMode: .fit)
                                        .frame(width: 174)
                                        .background(Color.black.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .strokeBorder(Theme.border, lineWidth: 1)
                                        )
                                    Text("\(index + 1)")
                                        .font(cf(9.4, .semibold))
                                        .foregroundStyle(Theme.textTertiary)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open slide \(index + 1)")
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(height: 120)
            }
        }
        .task(id: generation.manifest.id) {
            loaded = false
            let generation = generation
            slides = await Task.detached(priority: .utility) {
                WeeklyProgressSlideCatalog.urls(for: generation)
            }.value
            loaded = true
        }
    }
}
