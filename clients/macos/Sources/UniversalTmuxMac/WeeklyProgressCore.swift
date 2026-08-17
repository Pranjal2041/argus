import Foundation

// MARK: - Project and calendar identity

/// One panel included in a research project. Omitting `machineID` deliberately
/// matches the named panel on every machine, which is useful when a Babel job
/// moves between nodes while its shared filesystem and research identity stay
/// the same.
struct WeeklyProgressPanelSelector: Codable, Hashable, Identifiable {
    var id: String { (machineID ?? "*") + "|" + session.lowercased() }
    var session: String
    var machineID: String?

    init(session: String, machineID: String? = nil) {
        self.session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMachine = machineID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.machineID = cleanMachine?.isEmpty == false ? cleanMachine : nil
    }
}

/// A stable research project can span panels, machines, and working copies.
/// Membership is explicit rather than inferred from one session or folder name.
struct WeeklyProgressProject: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var panels: [WeeklyProgressPanelSelector]
    var workspaceRoots: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        panels: [WeeklyProgressPanelSelector],
        workspaceRoots: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.panels = Self.uniqued(panels.filter { !$0.session.isEmpty })
        self.workspaceRoots = Self.uniquedStrings(
            workspaceRoots.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private static func uniqued(_ values: [WeeklyProgressPanelSelector]) -> [WeeklyProgressPanelSelector] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private static func uniquedStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter {
            seen.insert($0.folding(options: [.caseInsensitive], locale: .current)).inserted
        }
    }
}

/// A half-open local-time week. Monday is included and the following Monday is
/// excluded, so Sunday events at any time remain inside the requested week.
struct WeeklyProgressWeek: Codable, Hashable {
    let start: Date
    let endExclusive: Date

    init(start: Date, calendar: Calendar = WeeklyProgressWeek.calendar()) {
        let day = calendar.startOfDay(for: start)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        self.start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
        self.endExclusive = calendar.date(byAdding: .day, value: 7, to: self.start)
            ?? self.start.addingTimeInterval(7 * 86_400)
    }

    init(containing date: Date, calendar: Calendar = WeeklyProgressWeek.calendar()) {
        self.init(start: date, calendar: calendar)
    }

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = timeZone
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    var storageKey: String { Self.dayFormatter.string(from: start) }

    private static let dayFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = .current
        value.dateFormat = "yyyy-MM-dd"
        return value
    }()
}

// MARK: - Evidence selection

enum WeeklyProgressEvidenceFilter {
    static func includes(_ event: [String: Any], project: WeeklyProgressProject) -> Bool {
        if let label = nonempty(event["project"] as? String),
           label.compare(project.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }

        if let session = nonempty(event["session"] as? String) {
            let machineID = nonempty(event["machineID"] as? String)
            if project.panels.contains(where: { selector in
                guard selector.session.compare(
                    session,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame else { return false }
                guard let expected = selector.machineID else { return true }
                return machineID?.compare(
                    expected,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                return true
            }
        }

        if let folder = nonempty(event["folder"] as? String) {
            return project.workspaceRoots.contains { contains(folder, within: $0) }
        }
        return false
    }

    /// Handles Unix paths and Windows drive paths without asking the host OS to
    /// interpret a remote machine's syntax.
    static func contains(_ candidate: String, within root: String) -> Bool {
        let candidatePath = normalizedPath(candidate)
        let rootPath = normalizedPath(root)
        guard !candidatePath.isEmpty, !rootPath.isEmpty else { return false }
        if candidatePath == rootPath { return true }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func normalizedPath(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while value.contains("//") { value = value.replacingOccurrences(of: "//", with: "/") }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        if value.count >= 2, value[value.index(after: value.startIndex)] == ":" {
            value = value.lowercased()
        }
        return value
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clean.isEmpty else { return nil }
        return clean
    }
}

struct WeeklyProgressEvidenceSummary: Codable, Hashable {
    var eventCount: Int
    var byteCount: Int
    var sourceFiles: [String]
    var kinds: [String: Int]
    var sessions: [String: Int]
    var machines: [String: Int]
    var folders: [String]
}

enum WeeklyProgressEvidenceError: LocalizedError {
    case noProjectIdentity
    case noEvidence

    var errorDescription: String? {
        switch self {
        case .noProjectIdentity:
            return "The project needs at least one panel or workspace root."
        case .noEvidence:
            return "No Activity Journal events matched this project and week."
        }
    }
}

struct WeeklyProgressEvidenceCollector {
    let journalDirectory: URL
    var calendar: Calendar = WeeklyProgressWeek.calendar()

    func collect(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        into evidenceDirectory: URL
    ) throws -> WeeklyProgressEvidenceSummary {
        guard !project.panels.isEmpty || !project.workspaceRoots.isEmpty else {
            throw WeeklyProgressEvidenceError.noProjectIdentity
        }
        try FileManager.default.createDirectory(
            at: evidenceDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = evidenceDirectory.appendingPathComponent("journal.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var eventCount = 0
        var byteCount = 0
        var sourceFiles: [String] = []
        var kinds: [String: Int] = [:]
        var sessions: [String: Int] = [:]
        var machines: [String: Int] = [:]
        var folders: Set<String> = []

        for fileURL in journalFiles(for: week) {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            var usedFile = false
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(rawLine).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      date(event["ts"] as? String).map({ $0 >= week.start && $0 < week.endExclusive }) == true,
                      WeeklyProgressEvidenceFilter.includes(event, project: project),
                      let encoded = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                else { continue }

                try output.write(contentsOf: encoded)
                try output.write(contentsOf: Data([0x0a]))
                eventCount += 1
                byteCount += encoded.count + 1
                usedFile = true
                if let kind = event["kind"] as? String { kinds[kind, default: 0] += 1 }
                if let session = event["session"] as? String { sessions[session, default: 0] += 1 }
                if let machine = (event["machine"] as? String) ?? (event["machineID"] as? String) {
                    machines[machine, default: 0] += 1
                }
                if let folder = event["folder"] as? String, !folder.isEmpty { folders.insert(folder) }
            }
            if usedFile { sourceFiles.append(fileURL.lastPathComponent) }
        }

        guard eventCount > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw WeeklyProgressEvidenceError.noEvidence
        }
        let summary = WeeklyProgressEvidenceSummary(
            eventCount: eventCount,
            byteCount: byteCount,
            sourceFiles: sourceFiles,
            kinds: kinds,
            sessions: sessions,
            machines: machines,
            folders: folders.sorted()
        )
        try WeeklyProgressJSON.write(summary, to: evidenceDirectory.appendingPathComponent("summary.json"))
        return summary
    }

    private func journalFiles(for week: WeeklyProgressWeek) -> [URL] {
        var files: [URL] = []
        var day = week.start
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        while day < week.endExclusive {
            files.append(journalDirectory.appendingPathComponent(formatter.string(from: day) + ".jsonl"))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? week.endExclusive
        }
        return files
    }

    private func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return Self.isoFractional.date(from: raw) ?? Self.isoPlain.date(from: raw)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

// MARK: - Durable generation record

enum WeeklyProgressStage: String, Codable {
    case collectingEvidence
    case reconstructingResearch
    case draftingSlides
    case auditingSlides
    case complete
    case failed
}

struct WeeklyProgressGenerationManifest: Codable, Hashable {
    var id: UUID
    var project: WeeklyProgressProject
    var week: WeeklyProgressWeek
    var createdAt: Date
    var updatedAt: Date
    var stage: WeeklyProgressStage
    var model: String
    var reasoningEffort: String
    var promptRevision: String?
    var codexSessionID: String?
    var auditPasses: Int
    var evidence: WeeklyProgressEvidenceSummary?
    var outputs: [String: String]
    var error: String?
    /// Idempotency key supplied by a remote client. Older manifests decode with
    /// nil, so this remains backwards-compatible with every existing review.
    var remoteRequestID: String?
}

struct WeeklyProgressGeneration {
    let directory: URL
    var manifest: WeeklyProgressGenerationManifest
}

struct WeeklyProgressDiskStore {
    static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Argus/weekly-progress", isDirectory: true)
    }

    let rootURL: URL

    init(rootURL: URL = Self.defaultRootURL) { self.rootURL = rootURL }

    func saveProject(_ project: WeeklyProgressProject) throws {
        try WeeklyProgressJSON.write(
            project,
            to: projectDirectory(project.id).appendingPathComponent("project.json")
        )
    }

    func loadProjects() -> [WeeklyProgressProject] {
        let projectsRoot = rootURL.appendingPathComponent("projects", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap {
            try? WeeklyProgressJSON.read(
                WeeklyProgressProject.self,
                from: $0.appendingPathComponent("project.json")
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// All immutable and in-flight versions, newest first. A future Argus view
    /// can render this directly without reverse-engineering directory names.
    func generations(projectID: UUID) -> [WeeklyProgressGeneration] {
        let weeksRoot = projectDirectory(projectID).appendingPathComponent("weeks", isDirectory: true)
        var result: [WeeklyProgressGeneration] = []
        // State lives at a fixed depth. Do not recursively enumerate generation
        // contents: evidence, agent traces, and slide renders can be large, and the UI
        // refreshes this catalog while one generation is active.
        for weekDirectory in childDirectories(of: weeksRoot) {
            let generationsRoot = weekDirectory.appendingPathComponent("generations", isDirectory: true)
            for generationDirectory in childDirectories(of: generationsRoot) {
                let stateURL = generationDirectory.appendingPathComponent("state.json")
                guard let manifest = try? WeeklyProgressJSON.read(
                    WeeklyProgressGenerationManifest.self,
                    from: stateURL
                ) else { continue }
                result.append(WeeklyProgressGeneration(
                    directory: generationDirectory,
                    manifest: manifest
                ))
            }
        }
        return result.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// The most recent finished review from a strictly earlier week. Same-week
    /// retries must not become their own historical context, and unfinished
    /// generations are never suitable as a terminology reference.
    func latestCompletedGeneration(
        projectID: UUID,
        before week: WeeklyProgressWeek
    ) -> WeeklyProgressGeneration? {
        generations(projectID: projectID)
            .filter {
                $0.manifest.stage == .complete
                    && $0.manifest.week.start < week.start
            }
            .max {
                ($0.manifest.week.start, $0.manifest.createdAt)
                    < ($1.manifest.week.start, $1.manifest.createdAt)
            }
    }

    /// The lightweight catalog for the virtual "All projects" view. This only
    /// reads each generation's fixed-depth state file; deck contents, renders,
    /// and evidence are left untouched until a visible row asks for them.
    func allGenerations(projects: [WeeklyProgressProject]? = nil) -> [WeeklyProgressGeneration] {
        let catalog = projects ?? loadProjects()
        return catalog.flatMap { generations(projectID: $0.id) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    func createGeneration(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        now: Date = Date(),
        id: UUID = UUID(),
        remoteRequestID: String? = nil
    ) throws -> WeeklyProgressGeneration {
        let projectDirectory = projectDirectory(project.id)
        let generationID = Self.generationFormatter.string(from: now)
            + "-" + String(id.uuidString.lowercased().prefix(8))
        let directory = projectDirectory
            .appendingPathComponent("weeks", isDirectory: true)
            .appendingPathComponent(week.storageKey, isDirectory: true)
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
        for child in ["evidence", "agent", "render"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(child, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try saveProject(project)

        let manifest = WeeklyProgressGenerationManifest(
            id: id,
            project: project,
            week: week,
            createdAt: now,
            updatedAt: now,
            stage: .collectingEvidence,
            model: CodexWeeklyProgressCommand.model,
            reasoningEffort: CodexWeeklyProgressCommand.reasoningEffort,
            promptRevision: WeeklyProgressPrompts.revision,
            codexSessionID: nil,
            auditPasses: 0,
            evidence: nil,
            outputs: [:],
            error: nil,
            remoteRequestID: remoteRequestID
        )
        try write(manifest, in: directory)
        try WeeklyProgressJSON.write(manifest, to: directory.appendingPathComponent("request.json"))
        return WeeklyProgressGeneration(directory: directory, manifest: manifest)
    }

    func write(_ manifest: WeeklyProgressGenerationManifest, in directory: URL) throws {
        try WeeklyProgressJSON.write(manifest, to: directory.appendingPathComponent("state.json"))
    }

    func load(from directory: URL) throws -> WeeklyProgressGenerationManifest {
        try WeeklyProgressJSON.read(
            WeeklyProgressGenerationManifest.self,
            from: directory.appendingPathComponent("state.json")
        )
    }

    private func projectDirectory(_ id: UUID) -> URL {
        rootURL
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func childDirectories(of parent: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static let generationFormatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)
        value.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return value
    }()
}

enum WeeklyProgressJSON {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

// MARK: - Agent instructions

enum WeeklyProgressPrompts {
    /// These are the user's actual instructions from the successful reference
    /// conversation. Do not paraphrase them. Generality belongs only in the
    /// operational context that maps LSD and its date range onto the selected run.
    static let referenceSessionID = "019f630d-5663-7722-bc65-5fd298a497ec"
    static let revision = "reference-session-019f630d-v2"
    static let requiredReferenceCorrectionCount = 3

    static let researchInstruction = """
    So the idea is that this is logs of all the tmux sessions that I've been using for the last few days. There are different
      categories for what is the message from an AI agent. Most of this is tmux sessions with an AI agent.

      There are different categories. Utterance means if I typed something. Oftentimes there is a bug where even partial things
      have been typed. The basic idea is that this is a log of every interaction that I've had with Claude or Codex agent over the
      last few days.

      Emphasis on the word interaction because it is possible that the agent says something and that was not captured. There are
      two things. One is regular capturing, and the other is whenever I type in something, then it's captured. Basically, there is
      this panel called LSD, and I want you to go through it in a temporal manner and try to understand what results we had, what I
      said, what the methodology was, what the observations were, and those kinds of things. Think about it as the history of my
      research work while working with an AI agent. It has all the things like results tables, important things, and everything.

      In research, you get some results, you change them, you get newer ones, maybe the agent was lying or maybe it made a mistake,
      I clarified it. Usually, my speaking becomes really important and those kinds of things. Keeping that in mind, please go
      through the whole conversations and all the data that is available for that specific panel and try to create a report of all
      the things that have been done over the last week. Right now your goal is just having all the information digested as to what
      things we did, what were the results, what experiments were done, what different settings, and those things. Basically,
      create a big research report as to what happened over the last week."
     actually last 2 weeks
    """

    static let slideInstruction = """
    cool! now if you were to create a set of presentation slides for say a student presenting in their weekly meeting, how
      you will create it? remember this is for professional PhD student in top university such as stanford or cmu, and is
      presenting their weekly updates to their PI. obviously few obvious things such as it should not be daily notes, but in proper
      order, etc. i hope it makes sense, what i mean by thise setting?? please think properly, and create the slides!"

    and remember as a student presenting to PI, engineering details, bugs fixed etc dont matter. those are minor things. keep slides research focussed not engineering focussed
    """

    static let readabilityCorrectionInstruction = """
    alright, few language instructions: never use em-dashes (--) or colons (:) or semi colons (-), write proper sentences. never use the style of "x, not y". always give proper context. i understand you had created the slides as one would present to their advisor, but think of it more progress report. massive violations, and missing details are there. massive context is missing before each slide. overall just think about it, are these slides self readable??? not at all. someone would just throw these away, reading the second slide. total marketing shitty language, no context, tons of missing experiments, and inferences, unscientific. so delete the slides now. and redo from scratch
    """

    static let fontCorrectionInstruction = """
    font size is too small. it is basically unreadable
    """

    static let languageCorrectionInstruction = """
    So I was going through the slides, and definitely there are big improvements, but the language is still shit. The language is still unscientific. The language is still marketing. The language uses lots of terms that are unexplained or unintroduced and unnecessary. I don't even know who the fuck uses those kinds of terms. Random words just pop out. I'm at loss of words right now for how pathetic the language is.

    That's not how you make slides. That's not how you fucking write anything, in fact. That's not how you write human-like writing. That's not how it works. Terrible, man. I mean, I don't know what kind of language is that. For example, randomly you will come up with some words like contrasting trajectories, conditioning, student gains, spending. These half phrases, these random words, I don't really understand, man. This is pathetic language. Pathetic. I mean, I don't know. If I could shout pathetic, that would also be underselling how bad your whole writing is.
    """

    static func reconstructResearch(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        artifactReferences: [String] = [],
        priorReview: WeeklyProgressGeneration? = nil
    ) -> String {
        let workspaces = project.workspaceRoots.isEmpty ? "none" : project.workspaceRoots.joined(separator: ", ")
        let panels = project.panels.isEmpty ? "none" : project.panels.map {
            "\($0.session) @ \($0.machineID ?? "machine from matching journal entries")"
        }.joined(separator: ", ")
        let artifacts = artifactReferences.isEmpty
            ? "No matching saved artifacts."
            : "Matching saved artifacts:\n" + artifactReferences.joined(separator: "\n")
        let prior = priorReview.map {
            "Previous report: \($0.directory.appendingPathComponent("research-report.md").path)\nPrevious slides: \($0.directory.appendingPathComponent("weekly-progress.pptx").path)\nUse them for terminology and brief context, never as new results."
        } ?? "No earlier completed review."

        return """
        This run is for the Argus project named \(project.name) and the reporting period
        \(periodDescription(week)). evidence/journal.jsonl contains its matching captured history.
        Workspace roots: \(workspaces). Selected panels: \(panels). Inspect local paths directly.
        Use `ut ls` to resolve a remote machine name when needed, then only read through
        `ut exec @<machine>`. Do not modify files, run project code, create sessions, or start jobs.
        Babel machines share one filesystem, so repeated data is one source, not separate experiments.
        \(artifacts)
        Saved artifacts indicate what the user considered important. \(prior)

        In the original instruction below, "LSD" means this selected project, and every relative
        date reference means the reporting period above.

        The following is the original user instruction from Codex session \(referenceSessionID).
        It is copied without rewriting.

        \(researchInstruction)

        Write the resulting report to research-report.md. Write evidence-ledger.json with the
        journal or workspace source for each material claim. Do not create slides in this turn.
        """
    }

    static func draftSlides(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        priorReview: WeeklyProgressGeneration? = nil
    ) -> String {
        """
        The completed research-report.md and evidence-ledger.json describe the \(project.name)
        project for \(periodDescription(week)). Use them and their underlying evidence.
        \(priorReview.map { "Use the earlier slides at \($0.directory.appendingPathComponent("weekly-progress.pptx").path) as the visual and terminology base. Add only a brief recap where useful, and never present old results as new." } ?? "")

        The following is the original user instruction from Codex session \(referenceSessionID).
        It is copied without rewriting.

        \(slideInstruction)

        Use the installed presentation tooling. Save the editable first version as draft.pptx.
        Do not create weekly-progress.pptx yet because the original correction turns follow.
        """
    }

    static func artifactReferences(
        _ records: [ArtifactRecord],
        rootURL: URL,
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek
    ) -> [String] {
        records.filter {
            $0.createdAt >= week.start && $0.createdAt < week.endExclusive
                && WeeklyProgressEvidenceFilter.includes([
                    "session": $0.panel.sessionName,
                    "machineID": $0.panel.machineID,
                    "folder": $0.panel.folder,
                ], project: project)
        }.sorted { $0.createdAt < $1.createdAt }.map {
            let path = rootURL.appendingPathComponent($0.relativePath).standardizedFileURL.path
            return "- \($0.filename) | \($0.createdAt.ISO8601Format()) | \($0.kind) | \($0.panel.sessionName) on \($0.panel.machineName) | \(path)"
        }
    }

    static func referenceCorrection(pass: Int) -> String {
        let boundedPass = min(max(pass, 1), requiredReferenceCorrectionCount)
        let instructions = (1...boundedPass).map { correctionInstruction($0) }.joined(
            separator: "\n\n"
        )
        return """
        Apply original correction turn \(boundedPass) to the actual PowerPoint. The original user
        instructions through this turn are repeated below, copied without rewriting and in their
        original order.

        \(instructions)

        Edit the PowerPoint itself rather than merely discussing it. Read draft.pptx on the first
        correction turn and weekly-progress.pptx on later turns. Save the corrected editable deck as
        weekly-progress.pptx. Replace render/final/ with a complete render of that deck. Write
        audit.json with this shape:
        {
          "passed": true,
          "checks": [{"name": "...", "passed": true, "evidence": "..."}],
          "issues": []
        }
        Set passed to true only after checking the actual deck and complete render against every
        original instruction above.
        """
    }

    static func repairSlides(pass: Int) -> String {
        """
        The deck still failed an objective validation after the original correction sequence. This
        is repair pass \(pass). Read audit.json and the Argus-generated language-audit.json. Fix
        every recorded issue in weekly-progress.pptx while continuing to follow the three original
        correction instructions below.

        \(readabilityCorrectionInstruction)

        \(fontCorrectionInstruction)

        \(languageCorrectionInstruction)

        Replace weekly-progress.pptx and render/final/ with the corrected editable deck and its
        complete render. Replace audit.json with a truthful result. Do not merely describe the
        changes.
        """
    }

    private static func correctionInstruction(_ pass: Int) -> String {
        switch pass {
        case 1: return readabilityCorrectionInstruction
        case 2: return fontCorrectionInstruction
        default: return languageCorrectionInstruction
        }
    }

    private static func periodDescription(_ week: WeeklyProgressWeek) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = WeeklyProgressWeek.calendar().timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let finalDay = week.endExclusive.addingTimeInterval(-1)
        return formatter.string(from: week.start) + " through " + formatter.string(from: finalDay)
    }
}
