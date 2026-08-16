import AppKit
import Foundation
import SwiftUI

enum WeeklyProgressWeekNavigation {
    static func current(now: Date = Date(), calendar: Calendar = WeeklyProgressWeek.calendar())
        -> WeeklyProgressWeek {
        WeeklyProgressWeek(containing: now, calendar: calendar)
    }

    static func shifted(
        _ week: WeeklyProgressWeek,
        byWeeks amount: Int,
        calendar: Calendar = WeeklyProgressWeek.calendar()
    ) -> WeeklyProgressWeek {
        let start = calendar.date(byAdding: .day, value: amount * 7, to: week.start) ?? week.start
        return WeeklyProgressWeek(start: start, calendar: calendar)
    }

    static func isCurrent(
        _ week: WeeklyProgressWeek,
        now: Date = Date(),
        calendar: Calendar = WeeklyProgressWeek.calendar()
    ) -> Bool {
        current(now: now, calendar: calendar).start == week.start
    }
}

enum WeeklyProgressStagePresentation {
    static let activeStages: [WeeklyProgressStage] = [
        .collectingEvidence,
        .reconstructingResearch,
        .draftingSlides,
        .auditingSlides,
    ]

    static func title(_ stage: WeeklyProgressStage) -> String {
        switch stage {
        case .collectingEvidence: return "Collecting evidence"
        case .reconstructingResearch: return "Reconstructing research"
        case .draftingSlides: return "Building slides"
        case .auditingSlides: return "Checking slides"
        case .complete: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    static func completedSteps(for stage: WeeklyProgressStage) -> Int {
        switch stage {
        case .collectingEvidence: return 0
        case .reconstructingResearch: return 1
        case .draftingSlides: return 2
        case .auditingSlides: return 3
        case .complete: return 4
        case .failed: return 0
        }
    }
}

enum WeeklyProgressBrowseMode: String, CaseIterable, Identifiable {
    case selectedWeek = "Selected week"
    case calendarList = "Calendar list"

    var id: String { rawValue }
}

struct WeeklyProgressDeckEntry: Identifiable {
    let latest: WeeklyProgressGeneration
    let latestComplete: WeeklyProgressGeneration?
    let versionCount: Int

    var id: UUID { latest.manifest.id }
}

struct WeeklyProgressCalendarSection: Identifiable {
    let week: WeeklyProgressWeek
    let entries: [WeeklyProgressDeckEntry]

    var id: Date { week.start }
}

/// Builds the same project/week catalog for the aggregate gallery and the
/// per-project calendar. Multiple immutable versions remain available in the
/// normal week view; collection views show the newest state and retain the
/// newest completed deck for reading while a replacement is in flight.
enum WeeklyProgressGenerationCatalog {
    static func entries(
        for week: WeeklyProgressWeek,
        in generations: [WeeklyProgressGeneration]
    ) -> [WeeklyProgressDeckEntry] {
        entries(in: generations.filter { $0.manifest.week.start == week.start })
    }

    static func calendarSections(
        in generations: [WeeklyProgressGeneration]
    ) -> [WeeklyProgressCalendarSection] {
        let grouped = Dictionary(grouping: generations) { $0.manifest.week.start }
        return grouped.keys.sorted(by: >).compactMap { start in
            guard let versions = grouped[start], let sample = versions.first else { return nil }
            return WeeklyProgressCalendarSection(
                week: sample.manifest.week,
                entries: entries(in: versions)
            )
        }
    }

    private static func entries(
        in generations: [WeeklyProgressGeneration]
    ) -> [WeeklyProgressDeckEntry] {
        Dictionary(grouping: generations) { $0.manifest.project.id }
            .values
            .compactMap { versions -> WeeklyProgressDeckEntry? in
                let sorted = versions.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
                guard let latest = sorted.first else { return nil }
                return WeeklyProgressDeckEntry(
                    latest: latest,
                    latestComplete: sorted.first { $0.manifest.stage == .complete },
                    versionCount: sorted.count
                )
            }
            .sorted {
                let comparison = $0.latest.manifest.project.name.localizedCaseInsensitiveCompare(
                    $1.latest.manifest.project.name
                )
                if comparison == .orderedSame {
                    return $0.latest.manifest.createdAt > $1.latest.manifest.createdAt
                }
                return comparison == .orderedAscending
            }
    }
}

enum WeeklyProgressSlideCatalog {
    static func urls(for generation: WeeklyProgressGeneration) -> [URL] {
        let directory = generation.directory.appendingPathComponent("render/final", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { $0.pathExtension.lowercased() == "png" && slideNumber($0) != nil }
            .sorted { (slideNumber($0) ?? 0) < (slideNumber($1) ?? 0) }
    }

    static func slideNumber(_ url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        guard name.hasPrefix("slide-") else { return nil }
        return Int(name.dropFirst("slide-".count))
    }
}

/// App-lifetime owner for the manual Weekly Progress workflow. Generation does not
/// belong to the view: closing the page leaves the Codex run alive, and reopening it
/// simply reloads the durable state written by `WeeklyProgressPipeline`.
@MainActor
final class WeeklyProgressController: ObservableObject {
    @Published private(set) var projects: [WeeklyProgressProject] = []
    @Published var selectedProjectID: UUID? {
        didSet {
            guard selectedProjectID != oldValue else { return }
            if !AppState.isRunningTests {
                UserDefaults.standard.set(
                    selectedProjectID?.uuidString ?? Self.allProjectsSelection,
                    forKey: Self.selectedProjectDefaultsKey
                )
            }
            reloadGenerations()
        }
    }
    @Published var selectedWeek: WeeklyProgressWeek
    @Published private(set) var generations: [WeeklyProgressGeneration] = []
    @Published private(set) var operationProjectID: UUID?
    @Published private(set) var operationWeekStart: Date?
    @Published private(set) var operationGenerationID: UUID?
    @Published private(set) var isGenerating = false
    @Published var errorMessage: String?

    private static let selectedProjectDefaultsKey = "ut.weeklyProgress.selectedProject"
    private static let allProjectsSelection = "all"
    private let store: WeeklyProgressDiskStore
    private let pipeline: WeeklyProgressPipeline
    private var operation: Task<Void, Never>?

    init(
        store: WeeklyProgressDiskStore = WeeklyProgressDiskStore(),
        pipeline: WeeklyProgressPipeline? = nil,
        now: Date = Date()
    ) {
        self.store = store
        self.pipeline = pipeline ?? WeeklyProgressPipeline(store: store)
        selectedWeek = WeeklyProgressWeekNavigation.current(now: now)
        projects = store.loadProjects()
        let storedSelection = AppState.isRunningTests ? nil
            : UserDefaults.standard.string(forKey: Self.selectedProjectDefaultsKey)
        let restored = storedSelection.flatMap(UUID.init(uuidString:))
        if storedSelection == Self.allProjectsSelection {
            selectedProjectID = nil
        } else {
            selectedProjectID = projects.contains(where: { $0.id == restored })
                ? restored
                : projects.first?.id
        }
        reloadGenerations()
    }

    var selectedProject: WeeklyProgressProject? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var selectedWeekGenerations: [WeeklyProgressGeneration] {
        generations.filter { $0.manifest.week.start == selectedWeek.start }
    }

    var latestSelectedWeekGeneration: WeeklyProgressGeneration? {
        selectedWeekGenerations.first
    }

    func reload() {
        let selected = selectedProjectID
        projects = store.loadProjects()
        if selected == nil {
            reloadGenerations()
        } else if let selected, projects.contains(where: { $0.id == selected }) {
            selectedProjectID = selected
        } else {
            selectedProjectID = nil
        }
        reloadGenerations()
    }

    func selectAllProjects() {
        selectedProjectID = nil
    }

    func selectProject(_ id: UUID) {
        selectedProjectID = id
    }

    func selectWeek(_ week: WeeklyProgressWeek) {
        selectedWeek = week
        reloadGenerations()
    }

    func moveWeek(by amount: Int) {
        selectWeek(WeeklyProgressWeekNavigation.shifted(selectedWeek, byWeeks: amount))
    }

    func saveProject(_ project: WeeklyProgressProject) throws {
        var updated = project
        updated.updatedAt = Date()
        try store.saveProject(updated)
        ActivityJournal.shared.log("weeklyProgressProject", [
            "action": projects.contains(where: { $0.id == project.id }) ? "edit" : "create",
            "project": updated.name,
            "projectID": updated.id.uuidString,
            "panels": updated.panels.map(\.session),
            "workspaceRoots": updated.workspaceRoots,
        ])
        projects = store.loadProjects()
        selectedProjectID = updated.id
        reloadGenerations()
    }

    func generateSelectedWeek() {
        guard operation == nil, let project = selectedProject else { return }
        let week = selectedWeek
        beginOperation(projectID: project.id, week: week, generationID: nil)
        ActivityJournal.shared.log("weeklyProgress", journalFields(
            project: project,
            week: week,
            action: "generate"
        ))
        operation = Task { [weak self] in
            guard let self else { return }
            let poller = self.makePoller(projectID: project.id, week: week)
            do {
                let generation = try await self.pipeline.generate(project: project, week: week)
                poller.cancel()
                self.finishOperation(generation: generation, error: nil)
                ActivityJournal.shared.log("weeklyProgress", self.journalFields(
                    project: project,
                    week: week,
                    action: "complete",
                    generationID: generation.manifest.id
                ))
            } catch {
                poller.cancel()
                self.finishOperation(generation: nil, error: error.localizedDescription)
                ActivityJournal.shared.log("weeklyProgress", self.journalFields(
                    project: project,
                    week: week,
                    action: "failed",
                    error: error.localizedDescription
                ))
            }
        }
    }

    func resume(_ generation: WeeklyProgressGeneration) {
        guard operation == nil else { return }
        let project = generation.manifest.project
        let week = generation.manifest.week
        beginOperation(
            projectID: project.id,
            week: week,
            generationID: generation.manifest.id
        )
        ActivityJournal.shared.log("weeklyProgress", journalFields(
            project: project,
            week: week,
            action: "resume",
            generationID: generation.manifest.id
        ))
        operation = Task { [weak self] in
            guard let self else { return }
            let poller = self.makePoller(projectID: project.id, week: week)
            do {
                let completed = try await self.pipeline.resume(
                    generationDirectory: generation.directory
                )
                poller.cancel()
                self.finishOperation(generation: completed, error: nil)
                ActivityJournal.shared.log("weeklyProgress", self.journalFields(
                    project: project,
                    week: week,
                    action: "complete",
                    generationID: completed.manifest.id
                ))
            } catch {
                poller.cancel()
                self.finishOperation(generation: nil, error: error.localizedDescription)
                ActivityJournal.shared.log("weeklyProgress", self.journalFields(
                    project: project,
                    week: week,
                    action: "failed",
                    generationID: generation.manifest.id,
                    error: error.localizedDescription
                ))
            }
        }
    }

    func isOperating(projectID: UUID, week: WeeklyProgressWeek) -> Bool {
        isGenerating && operationProjectID == projectID && operationWeekStart == week.start
    }

    func reveal(_ generation: WeeklyProgressGeneration) {
        NSWorkspace.shared.activateFileViewerSelecting([generation.directory])
    }

    func openDeck(_ generation: WeeklyProgressGeneration) {
        let deck = generation.directory.appendingPathComponent("weekly-progress.pptx")
        guard FileManager.default.fileExists(atPath: deck.path) else {
            errorMessage = "The finished PowerPoint could not be found."
            return
        }
        NSWorkspace.shared.open(deck)
    }

    private func reloadGenerations() {
        if let selectedProjectID {
            generations = store.generations(projectID: selectedProjectID)
        } else {
            generations = store.allGenerations(projects: projects)
        }
    }

    private func beginOperation(projectID: UUID, week: WeeklyProgressWeek, generationID: UUID?) {
        errorMessage = nil
        operationProjectID = projectID
        operationWeekStart = week.start
        operationGenerationID = generationID
        isGenerating = true
        reloadGenerations()
    }

    private func finishOperation(generation: WeeklyProgressGeneration?, error: String?) {
        if let generation { operationGenerationID = generation.manifest.id }
        errorMessage = error
        reloadGenerations()
        isGenerating = false
        operationProjectID = nil
        operationWeekStart = nil
        operationGenerationID = nil
        operation = nil
    }

    private func makePoller(projectID: UUID, week: WeeklyProgressWeek) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.selectedProjectID == nil || self.selectedProjectID == projectID {
                    self.reloadGenerations()
                    if self.operationGenerationID == nil {
                        self.operationGenerationID = self.generations.first(where: {
                            $0.manifest.week.start == week.start
                                && $0.manifest.stage != .complete
                                && $0.manifest.stage != .failed
                        })?.manifest.id
                    }
                }
            }
        }
    }

    private func journalFields(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        action: String,
        generationID: UUID? = nil,
        error: String? = nil
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "action": action,
            "project": project.name,
            "projectID": project.id.uuidString,
            "week": week.storageKey,
            "model": CodexWeeklyProgressCommand.model,
            "reasoningEffort": CodexWeeklyProgressCommand.reasoningEffort,
            "promptRevision": WeeklyProgressPrompts.revision,
        ]
        if let generationID { fields["generationID"] = generationID.uuidString }
        if let error { fields["error"] = error }
        return fields
    }
}
