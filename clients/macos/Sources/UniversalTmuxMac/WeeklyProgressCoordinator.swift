import Foundation

struct WeeklyProgressOperationSnapshot: Equatable {
    let generationID: UUID
    let projectID: UUID
    let projectName: String
    let weekStart: Date
    let stage: WeeklyProgressStage
    let startedAt: Date
}

struct WeeklyProgressCoordinatorSnapshot {
    let operation: WeeklyProgressOperationSnapshot?
    let lastError: String?
    let revision: UInt64
}

enum WeeklyProgressCoordinatorError: LocalizedError {
    case projectNotFound
    case generationNotFound
    case busy(WeeklyProgressOperationSnapshot)
    case invalidRequestID

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "The selected Weekly Progress project no longer exists."
        case .generationNotFound:
            return "The selected Weekly Progress generation no longer exists."
        case let .busy(operation):
            return "A review for \(operation.projectName) is already running."
        case .invalidRequestID:
            return "The request id is missing or invalid."
        }
    }
}

/// The single execution owner shared by the macOS page and remote clients.
/// Files remain authoritative; this actor only serializes expensive work and
/// exposes a small live-operation snapshot alongside the durable manifests.
actor WeeklyProgressCoordinator {
    let store: WeeklyProgressDiskStore
    private let pipeline: WeeklyProgressPipeline
    private var operationTask: Task<Void, Never>?
    private var activeOperation: WeeklyProgressOperationSnapshot?
    private var activeGenerationDirectory: URL?
    private var lastError: String?
    private var revision: UInt64 = 0
    private var transientRequests: [String: UUID] = [:]

    init(
        store: WeeklyProgressDiskStore = WeeklyProgressDiskStore(),
        pipeline: WeeklyProgressPipeline? = nil
    ) {
        self.store = store
        self.pipeline = pipeline ?? WeeklyProgressPipeline(store: store)
    }

    func snapshot() -> WeeklyProgressCoordinatorSnapshot {
        var operation = activeOperation
        if var current = operation,
           let directory = activeGenerationDirectory,
           let manifest = try? store.load(from: directory) {
            current = WeeklyProgressOperationSnapshot(
                generationID: current.generationID,
                projectID: current.projectID,
                projectName: current.projectName,
                weekStart: current.weekStart,
                stage: manifest.stage,
                startedAt: current.startedAt
            )
            activeOperation = current
            operation = current
        }
        return WeeklyProgressCoordinatorSnapshot(
            operation: operation,
            lastError: lastError,
            revision: revision
        )
    }

    /// Starts a new version and returns after its durable manifest exists, not
    /// after Codex finishes. Reusing requestID always resolves to the first
    /// generation, including after Argus itself has restarted.
    func start(
        projectID: UUID,
        week: WeeklyProgressWeek,
        requestID: String
    ) async throws -> WeeklyProgressGeneration {
        let cleanRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRequestID.isEmpty, cleanRequestID.count <= 160 else {
            throw WeeklyProgressCoordinatorError.invalidRequestID
        }
        if let existing = store.allGenerations().first(where: {
            $0.manifest.remoteRequestID == cleanRequestID
        }) {
            return existing
        }
        if let activeOperation {
            throw WeeklyProgressCoordinatorError.busy(activeOperation)
        }
        guard let project = store.loadProjects().first(where: { $0.id == projectID }) else {
            throw WeeklyProgressCoordinatorError.projectNotFound
        }

        let generation = try await pipeline.prepare(
            project: project,
            week: week,
            remoteRequestID: cleanRequestID
        )
        launch(generation, action: "generate")
        return generation
    }

    func resume(generationID: UUID, requestID: String) async throws -> WeeklyProgressGeneration {
        let cleanRequestID = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRequestID.isEmpty, cleanRequestID.count <= 160 else {
            throw WeeklyProgressCoordinatorError.invalidRequestID
        }
        if let remembered = transientRequests[cleanRequestID],
           let existing = generation(id: remembered) {
            return existing
        }
        guard let generation = generation(id: generationID) else {
            throw WeeklyProgressCoordinatorError.generationNotFound
        }
        if generation.manifest.stage == .complete {
            transientRequests[cleanRequestID] = generationID
            return generation
        }
        if let activeOperation {
            if activeOperation.generationID == generationID {
                transientRequests[cleanRequestID] = generationID
                return generation
            }
            throw WeeklyProgressCoordinatorError.busy(activeOperation)
        }
        transientRequests[cleanRequestID] = generationID
        launch(generation, action: "resume")
        return generation
    }

    func generation(id: UUID) -> WeeklyProgressGeneration? {
        store.allGenerations().first { $0.manifest.id == id }
    }

    private func launch(_ generation: WeeklyProgressGeneration, action: String) {
        lastError = nil
        revision &+= 1
        activeOperation = WeeklyProgressOperationSnapshot(
            generationID: generation.manifest.id,
            projectID: generation.manifest.project.id,
            projectName: generation.manifest.project.name,
            weekStart: generation.manifest.week.start,
            stage: generation.manifest.stage,
            startedAt: Date()
        )
        activeGenerationDirectory = generation.directory
        journal(action: action, generation: generation, error: nil)
        let directory = generation.directory
        operationTask = Task { [weak self, pipeline] in
            do {
                let completed = try await pipeline.resume(generationDirectory: directory)
                await self?.finish(completed, error: nil)
            } catch {
                await self?.finish(generation, error: error.localizedDescription)
            }
        }
    }

    private func finish(_ generation: WeeklyProgressGeneration, error: String?) {
        lastError = error
        activeOperation = nil
        activeGenerationDirectory = nil
        operationTask = nil
        revision &+= 1
        let latest = self.generation(id: generation.manifest.id) ?? generation
        journal(action: error == nil ? "complete" : "failed", generation: latest, error: error)
    }

    private func journal(action: String, generation: WeeklyProgressGeneration, error: String?) {
        var fields: [String: Any] = [
            "action": action,
            "project": generation.manifest.project.name,
            "projectID": generation.manifest.project.id.uuidString,
            "week": generation.manifest.week.storageKey,
            "generationID": generation.manifest.id.uuidString,
            "model": generation.manifest.model,
            "reasoningEffort": generation.manifest.reasoningEffort,
            "promptRevision": generation.manifest.promptRevision ?? "",
        ]
        if let error { fields["error"] = error }
        Task { @MainActor in
            ActivityJournal.shared.log("weeklyProgress", fields)
        }
    }
}
