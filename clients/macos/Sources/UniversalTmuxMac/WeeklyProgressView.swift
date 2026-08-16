import AppKit
import SwiftUI

private struct WeeklyProgressReaderSelection: Identifiable {
    let generation: WeeklyProgressGeneration
    var mode: WeeklyProgressReaderMode = .slides
    var initialSlide: Int = 0
    var id: UUID { generation.manifest.id }
}

/// Manual project-by-week research review. The page has one consequential action:
/// generate a deck for the week currently in the navigator.
struct WeeklyProgressView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var progress: WeeklyProgressController
    @AppStorage("ut.uiScale") private var uiScale = 1.0

    @State private var editorProject: WeeklyProgressProject?
    @State private var reader: WeeklyProgressReaderSelection?
    @State private var showWeekPicker = false
    @State private var pickedDate = Date()
    @State private var inspectedProjectID: UUID?
    @State private var browseMode: WeeklyProgressBrowseMode = .selectedWeek

    init(initialBrowseMode: WeeklyProgressBrowseMode = .selectedWeek) {
        _browseMode = State(initialValue: initialBrowseMode)
    }

    private func cf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * uiScale, weight: weight)
    }

    var body: some View {
        Group {
            if let reader {
                WeeklyProgressReaderView(
                    generation: reader.generation,
                    initialMode: reader.mode,
                    initialSlide: reader.initialSlide
                ) {
                    self.reader = nil
                    progress.reload()
                }
            } else {
                dashboard
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .onAppear { progress.reload() }
        .sheet(item: $editorProject) { project in
            WeeklyProgressProjectEditor(project: project) { updated in
                do {
                    try progress.saveProject(updated)
                    editorProject = nil
                } catch {
                    progress.errorMessage = error.localizedDescription
                }
            }
            .environmentObject(state)
        }
        .alert("Weekly Progress", isPresented: Binding(
            get: { progress.errorMessage != nil },
            set: { if !$0 { progress.errorMessage = nil } }
        )) {
            Button("OK") { progress.errorMessage = nil }
        } message: {
            Text(progress.errorMessage ?? "The operation could not be completed.")
        }
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            globalHeader
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                projectRail
                    .frame(width: 238)
                Divider().overlay(Theme.border)
                Group {
                    if progress.projects.isEmpty {
                        noProjects
                    } else if let project = progress.selectedProject {
                        projectWorkspace(project)
                    } else {
                        allProjectsWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var globalHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(cf(14, .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 31, height: 31)
            VStack(alignment: .leading, spacing: 1) {
                Text("Weekly Progress")
                    .font(cf(19, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Research reviews, one project and one week at a time")
                    .font(cf(11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Text("GPT-5.6 SOL · XHIGH")
                .font(cf(9.5, .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.surface.opacity(0.75)))
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            Button { state.showWeeklyProgress = false } label: {
                Image(systemName: "xmark")
                    .font(cf(13, .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help("Close Weekly Progress")
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECTS")
                    .font(cf(10.5, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { createProject() } label: {
                    Image(systemName: "plus")
                        .font(cf(11, .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("New project")
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 4) {
                    allProjectsButton
                    Divider().overlay(Theme.border).padding(.horizontal, 8).padding(.vertical, 3)
                    ForEach(progress.projects) { project in
                        projectButton(project)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            Button(action: createProject) {
                Label("New project", systemImage: "plus")
                    .font(cf(11.5, .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            .padding(12)
        }
        .background(Theme.sidebarBackground.opacity(0.72))
    }

    private var allProjectsButton: some View {
        let selected = progress.selectedProjectID == nil
        return Button {
            progress.selectAllProjects()
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? Theme.accent : Theme.border)
                    .frame(width: 3, height: 28)
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Theme.accent.opacity(0.13) : Theme.surface.opacity(0.48))
                    Image(systemName: "square.grid.2x2")
                        .font(cf(10.5, .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                }
                .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All")
                        .font(cf(12.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    Text("\(progress.projects.count) project\(progress.projects.count == 1 ? "" : "s")")
                        .font(cf(9.8))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.selection.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Browse weekly slides across every project")
    }

    private func projectButton(_ project: WeeklyProgressProject) -> some View {
        let selected = progress.selectedProjectID == project.id
        return HStack(spacing: 4) {
            Button {
                progress.selectProject(project.id)
            } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(selected ? Theme.accent : Theme.border)
                        .frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(cf(12.5, selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Text(projectSummary(project))
                            .font(cf(9.8))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                inspectedProjectID = inspectedProjectID == project.id ? nil : project.id
            } label: {
                Image(systemName: "info.circle")
                    .font(cf(11.5, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 25, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Inspect project sources")
            .popover(isPresented: Binding(
                get: { inspectedProjectID == project.id },
                set: { if !$0, inspectedProjectID == project.id { inspectedProjectID = nil } }
            ), arrowEdge: .trailing) {
                projectSourcesPopover(project)
            }

            if progress.isGenerating && progress.operationProjectID == project.id {
                ProgressView().controlSize(.mini).scaleEffect(0.75)
                    .frame(width: 18)
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.selection.opacity(0.9) : Color.clear)
        )
        .contextMenu {
            Button("Inspect Sources") { inspectedProjectID = project.id }
            Button("Edit Project…") { editorProject = project }
        }
    }

    private func projectSourcesPopover(_ project: WeeklyProgressProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(cf(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("Evidence sources")
                        .font(cf(10.2))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button("Edit") {
                    inspectedProjectID = nil
                    editorProject = project
                }
                .buttonStyle(.plain)
                .font(cf(10.8, .medium))
                .foregroundStyle(Theme.accent)
            }

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !project.panels.isEmpty {
                        sourceSectionTitle("PANELS", count: project.panels.count)
                        VStack(spacing: 0) {
                            ForEach(Array(project.panels.enumerated()), id: \.element.id) { index, panel in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "terminal")
                                        .font(cf(9.5, .medium))
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 15)
                                    Text(panel.session)
                                        .font(cf(11.5, .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(projectPanelScope(panel))
                                        .font(cf(9.7))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .frame(minHeight: 33)
                                if index < project.panels.count - 1 {
                                    Divider().overlay(Theme.border).padding(.leading, 33)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBackground.opacity(0.45)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                    }

                    if !project.workspaceRoots.isEmpty {
                        sourceSectionTitle("FOLDERS", count: project.workspaceRoots.count)
                        VStack(spacing: 0) {
                            ForEach(Array(project.workspaceRoots.enumerated()), id: \.offset) { index, path in
                                HStack(spacing: 9) {
                                    Image(systemName: "folder")
                                        .font(cf(9.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 15)
                                    Text(path)
                                        .font(cf(10.5))
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                                if index < project.workspaceRoots.count - 1 {
                                    Divider().overlay(Theme.border).padding(.leading, 33)
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarBackground.opacity(0.45)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
                    }
                }
            }
            .frame(maxHeight: 340)
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.appBackground)
    }

    private func sourceSectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(cf(9.5, .semibold))
                .tracking(0.6)
            Text(String(count))
                .font(cf(9.2, .medium))
        }
        .foregroundStyle(Theme.textTertiary)
    }

    private func projectPanelScope(_ panel: WeeklyProgressPanelSelector) -> String {
        guard let machineID = panel.machineID else { return "Across machines" }
        return state.machines.first(where: { $0.id == machineID })?.name ?? machineID
    }

    private func projectWorkspace(_ project: WeeklyProgressProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                projectHeader(project)
                if browseMode == .selectedWeek {
                    weekNavigator(project)
                    generationContent(project)
                } else {
                    collectionView(aggregate: false)
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func projectHeader(_ project: WeeklyProgressProject) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name)
                    .font(cf(25, .bold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 7) {
                    Label("\(project.panels.count) panel\(project.panels.count == 1 ? "" : "s")", systemImage: "terminal")
                    Text("·")
                    Label("\(project.workspaceRoots.count) folder\(project.workspaceRoots.count == 1 ? "" : "s")", systemImage: "folder")
                }
                .font(cf(11.5))
                .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            browseModeControl
            Button { editorProject = project } label: {
                Label("Edit project", systemImage: "slider.horizontal.3")
                    .font(cf(11.5, .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private var allProjectsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("All projects")
                            .font(cf(25, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Every weekly research deck, without combining or duplicating project data")
                            .font(cf(11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    browseModeControl
                }

                if browseMode == .selectedWeek {
                    weekNavigator(nil)
                }
                collectionView(aggregate: true)
            }
            .frame(maxWidth: 1180, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var browseModeControl: some View {
        HStack(spacing: 2) {
            ForEach(WeeklyProgressBrowseMode.allCases) { item in
                Button {
                    browseMode = item
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item == .selectedWeek ? "rectangle.stack" : "calendar")
                            .font(cf(9.8, .semibold))
                        Text(item.rawValue)
                            .font(cf(10.5, browseMode == item ? .semibold : .medium))
                    }
                    .foregroundStyle(browseMode == item ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(browseMode == item ? Theme.selection : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.65)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func collectionView(aggregate: Bool) -> some View {
        WeeklyProgressCollectionView(
            mode: browseMode,
            generations: progress.generations,
            selectedWeek: progress.selectedWeek,
            aggregate: aggregate,
            operationProjectID: progress.operationProjectID,
            operationWeekStart: progress.operationWeekStart,
            onRead: { generation, slide in
                reader = WeeklyProgressReaderSelection(
                    generation: generation,
                    initialSlide: slide
                )
            },
            onOpenWeek: { project, week in
                progress.selectProject(project.id)
                progress.selectWeek(week)
                browseMode = .selectedWeek
            },
            onOpenDeck: { progress.openDeck($0) },
            onReveal: { progress.reveal($0) }
        )
    }

    private func weekNavigator(_ project: WeeklyProgressProject?) -> some View {
        let isCurrent = WeeklyProgressWeekNavigation.isCurrent(progress.selectedWeek)
        let nextDisabled = progress.selectedWeek.start >= WeeklyProgressWeekNavigation.current().start
        let operating = project.map {
            progress.isOperating(projectID: $0.id, week: progress.selectedWeek)
        } ?? false
        return HStack(spacing: 10) {
            Button { progress.moveWeek(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            .help("Previous week")

            Button {
                pickedDate = progress.selectedWeek.start
                showWeekPicker = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "calendar")
                        .font(cf(11.5, .semibold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(weekRange(progress.selectedWeek))
                            .font(cf(12.5, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(isCurrent ? "This week" : "Monday through Sunday")
                            .font(cf(9.8))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.down")
                        .font(cf(8.5, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 11)
                .frame(height: 42)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
            .popover(isPresented: $showWeekPicker, arrowEdge: .bottom) {
                weekPicker
            }

            Button { progress.moveWeek(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(nextDisabled ? Theme.textTertiary.opacity(0.35) : Theme.textSecondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface.opacity(0.65)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            .disabled(nextDisabled)
            .help("Next week")

            if !isCurrent {
                Button("This week") {
                    progress.selectWeek(WeeklyProgressWeekNavigation.current())
                }
                .buttonStyle(.plain)
                .font(cf(11.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
            }

            Spacer()

            if project != nil {
                Button {
                    progress.generateSelectedWeek()
                } label: {
                    HStack(spacing: 7) {
                        if operating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(operating ? "Generating…" : "Generate review")
                    }
                    .font(cf(12, .semibold))
                    .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .disabled(progress.isGenerating)
                .opacity(progress.isGenerating ? 0.7 : 1)
                .help("Generate a new immutable version for this project and week")
            } else {
                let count = WeeklyProgressGenerationCatalog.entries(
                    for: progress.selectedWeek,
                    in: progress.generations
                ).count
                Text("\(count) project review\(count == 1 ? "" : "s")")
                    .font(cf(10.8, .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sidebarBackground.opacity(0.52)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var weekPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose any date in the week")
                .font(cf(12, .semibold))
                .foregroundStyle(Theme.textPrimary)
            DatePicker("", selection: $pickedDate, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Cancel") { showWeekPicker = false }
                Button("Choose week") {
                    progress.selectWeek(WeeklyProgressWeek(containing: pickedDate))
                    showWeekPicker = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(Theme.sidebarBackground)
    }

    @ViewBuilder
    private func generationContent(_ project: WeeklyProgressProject) -> some View {
        let versions = progress.selectedWeekGenerations
        if versions.isEmpty {
            if progress.isOperating(projectID: project.id, week: progress.selectedWeek) {
                pendingGenerationCard
            } else {
                emptyWeek
            }
        } else {
            latestGenerationCard(versions[0])
            if versions.count > 1 {
                versionsList(Array(versions.dropFirst()))
            }
        }
    }

    private var pendingGenerationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Starting this review")
                        .font(cf(16, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Preparing the evidence snapshot…")
                        .font(cf(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                ProgressView().controlSize(.small)
            }
            progressTrack(stage: .collectingEvidence)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface.opacity(0.46)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
    }

    private func latestGenerationCard(_ generation: WeeklyProgressGeneration) -> some View {
        let active = progress.operationGenerationID == generation.manifest.id
            || (progress.isOperating(
                projectID: generation.manifest.project.id,
                week: generation.manifest.week
            ) && generation.manifest.stage != .complete && generation.manifest.stage != .failed)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(stageColor(generation.manifest.stage, active: active))
                            .frame(width: 8, height: 8)
                        Text(WeeklyProgressStagePresentation.title(generation.manifest.stage))
                            .font(cf(16, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(generationSubtitle(generation, active: active))
                        .font(cf(11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                generationActions(generation, active: active)
            }

            if generation.manifest.stage == .complete {
                completedSummary(generation)
            } else {
                progressTrack(stage: generation.manifest.stage)
                if let error = generation.manifest.error, !error.isEmpty {
                    Text(error)
                        .font(cf(11.5))
                        .foregroundStyle(Theme.waiting)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.waiting.opacity(0.08)))
                }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface.opacity(0.46)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func generationActions(_ generation: WeeklyProgressGeneration, active: Bool) -> some View {
        if generation.manifest.stage == .complete {
            HStack(spacing: 8) {
                Button {
                    reader = WeeklyProgressReaderSelection(generation: generation)
                } label: {
                    Label("Read slides", systemImage: "rectangle.stack")
                        .font(cf(11.5, .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))

                Menu {
                    Button("Open PowerPoint") { progress.openDeck(generation) }
                    Button("Show in Finder") { progress.reveal(generation) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(cf(12, .semibold))
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        } else if active {
            ProgressView().controlSize(.small)
        } else if generation.manifest.promptRevision != WeeklyProgressPrompts.revision {
            Button {
                progress.generateSelectedWeek()
            } label: {
                Label("Generate new review", systemImage: "sparkles")
                    .font(cf(11.5, .semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            .disabled(progress.isGenerating)
        } else {
            Button {
                progress.resume(generation)
            } label: {
                Label(generation.manifest.stage == .failed ? "Retry" : "Resume", systemImage: "arrow.clockwise")
                    .font(cf(11.5, .semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
            .disabled(progress.isGenerating)
        }
    }

    private func completedSummary(_ generation: WeeklyProgressGeneration) -> some View {
        let evidence = generation.manifest.evidence?.eventCount ?? 0
        let currentContract = generation.manifest.promptRevision == WeeklyProgressPrompts.revision
            && generation.manifest.outputs["languageAudit"] != nil
        // The pipeline gate already proved that the render count matches the PPTX.
        // Count the tiny render directory here instead of launching `unzip` from a
        // SwiftUI body (which would synchronously block the main actor on every redraw).
        let slides = renderedSlideCount(generation)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                metric("JOURNAL EVENTS", value: "\(evidence)")
                Divider().overlay(Theme.border).frame(height: 38).padding(.horizontal, 22)
                metric("SLIDES", value: "\(slides)")
                Divider().overlay(Theme.border).frame(height: 38).padding(.horizontal, 22)
                metric("VERIFIED", value: currentContract ? "Yes" : "Earlier rules")
                Spacer()
                Button {
                    reader = WeeklyProgressReaderSelection(generation: generation, mode: .report)
                } label: {
                    Text("Open research report →")
                        .font(cf(11.5, .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            if !currentContract {
                Label(
                    "This version predates the reference-session prompt sequence and language checks. Generate a new review to apply them.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(cf(10.5, .medium))
                .foregroundStyle(Theme.waiting)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(cf(9, .semibold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            Text(value).font(cf(15, .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func progressTrack(stage: WeeklyProgressStage) -> some View {
        let completed = WeeklyProgressStagePresentation.completedSteps(for: stage)
        return HStack(spacing: 0) {
            ForEach(Array(WeeklyProgressStagePresentation.activeStages.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 0) {
                        Circle()
                            .fill(stepColor(index: index, completed: completed, failed: stage == .failed))
                            .frame(width: 9, height: 9)
                        if index < WeeklyProgressStagePresentation.activeStages.count - 1 {
                            Rectangle()
                                .fill(index < completed ? Theme.accent.opacity(0.72) : Theme.border)
                                .frame(height: 1)
                        }
                    }
                    Text(WeeklyProgressStagePresentation.title(item))
                        .font(cf(9.8, index == completed && stage != .complete ? .semibold : .regular))
                        .foregroundStyle(index <= completed ? Theme.textSecondary : Theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func versionsList(_ versions: [WeeklyProgressGeneration]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("EARLIER VERSIONS")
                .font(cf(10.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(versions.enumerated()), id: \.element.manifest.id) { index, generation in
                    HStack(spacing: 10) {
                        Circle().fill(stageColor(generation.manifest.stage, active: false))
                            .frame(width: 7, height: 7)
                        Text(shortTimestamp(generation.manifest.createdAt))
                            .font(cf(11.5, .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Text(WeeklyProgressStagePresentation.title(generation.manifest.stage))
                            .font(cf(10.5))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if generation.manifest.stage == .complete {
                            Button("Read") {
                                reader = WeeklyProgressReaderSelection(generation: generation)
                            }
                            .buttonStyle(.plain)
                            .font(cf(11, .medium))
                            .foregroundStyle(Theme.accent)
                        } else if generation.manifest.promptRevision == WeeklyProgressPrompts.revision {
                            Button("Resume") { progress.resume(generation) }
                                .buttonStyle(.plain)
                                .font(cf(11, .medium))
                                .foregroundStyle(Theme.accent)
                                .disabled(progress.isGenerating)
                        } else {
                            Button("Generate new") { progress.generateSelectedWeek() }
                                .buttonStyle(.plain)
                                .font(cf(11, .medium))
                                .foregroundStyle(Theme.accent)
                                .disabled(progress.isGenerating)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    if index < versions.count - 1 {
                        Divider().overlay(Theme.border).padding(.leading, 29)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.sidebarBackground.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private var emptyWeek: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.surface.opacity(0.65))
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(cf(22, .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 50, height: 50)
            Text("No review for this week")
                .font(cf(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Generate when you want a research summary. Nothing runs on a schedule.")
                .font(cf(11.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebarBackground.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.8), lineWidth: 1))
    }

    private var noProjects: some View {
        VStack(spacing: 13) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(cf(31, .light))
                .foregroundStyle(Theme.textTertiary)
            Text("Create your first research project")
                .font(cf(18, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Group the panels and folders that belong together. Then choose a week and generate its review.")
                .font(cf(12))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button(action: createProject) {
                Label("Create project", systemImage: "plus")
                    .font(cf(12, .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.current.isLight ? Color.white : Theme.appBackground)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createProject() {
        editorProject = WeeklyProgressProject(name: "", panels: [])
    }

    private func projectSummary(_ project: WeeklyProgressProject) -> String {
        let panels = "\(project.panels.count) panel\(project.panels.count == 1 ? "" : "s")"
        let folders = "\(project.workspaceRoots.count) folder\(project.workspaceRoots.count == 1 ? "" : "s")"
        if project.panels.isEmpty { return folders }
        if project.workspaceRoots.isEmpty { return panels }
        return panels + " · " + folders
    }

    private func weekRange(_ week: WeeklyProgressWeek) -> String {
        let end = Calendar.current.date(byAdding: .day, value: -1, to: week.endExclusive)
            ?? week.endExclusive
        let startFormatter = DateFormatter()
        startFormatter.dateFormat = "MMM d"
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "MMM d, yyyy"
        return startFormatter.string(from: week.start) + " – " + endFormatter.string(from: end)
    }

    private func shortTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    private func generationSubtitle(_ generation: WeeklyProgressGeneration, active: Bool) -> String {
        if active { return "This continues even if you leave this page." }
        if generation.manifest.stage == .complete {
            return "Generated " + shortTimestamp(generation.manifest.createdAt)
        }
        if generation.manifest.stage == .failed { return "The files are preserved; retry resumes this version." }
        return "This run was interrupted and can be resumed."
    }

    private func stageColor(_ stage: WeeklyProgressStage, active: Bool) -> Color {
        if active { return Theme.running }
        switch stage {
        case .complete: return Theme.attached
        case .failed: return Theme.waiting
        default: return Theme.textTertiary
        }
    }

    private func stepColor(index: Int, completed: Int, failed: Bool) -> Color {
        if failed && index == 0 { return Theme.waiting }
        if index < completed { return Theme.accent }
        if index == completed { return Theme.running }
        return Theme.border
    }

    private func renderedSlideCount(_ generation: WeeklyProgressGeneration) -> Int {
        let render = generation.directory.appendingPathComponent("render/final", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: render,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.lazy.filter {
            $0.pathExtension.lowercased() == "png"
                && $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix("slide-")
        }.count
    }
}
