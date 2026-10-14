import Foundation

struct WeeklyProgressAgentResult: Equatable {
    let sessionID: String
    let finalMessage: String
}

protocol WeeklyProgressAgentRunning {
    var provider: AgentProvider { get }
    func start(prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult
    func resume(sessionID: String, prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult
}

extension WeeklyProgressAgentRunning {
    var provider: AgentProvider { .codex }
}

enum CodexWeeklyProgressCommand {
    static let model = CodexModels.weeklyProgress
    static let reasoningEffort = "high"

    static func initialArguments(directory: URL, finalMessageURL: URL) -> [String] {
        arguments(conversation: nil, directory: directory, finalMessageURL: finalMessageURL)
    }

    static func resumeArguments(sessionID: String, finalMessageURL: URL) -> [String] {
        arguments(conversation: AgentConversation(provider: .codex, id: sessionID),
            directory: FileManager.default.temporaryDirectory, finalMessageURL: finalMessageURL)
    }

    private static func arguments(conversation: AgentConversation?, directory: URL, finalMessageURL: URL) -> [String] {
        AgentCLIRunner.arguments(AgentGenerationRequest(provider: .codex, purpose: .weeklyProgress, prompt: "", conversation: conversation),
            directory: directory, finalURL: finalMessageURL, exportURL: finalMessageURL,
            promptURL: finalMessageURL, configURL: finalMessageURL)
    }

    static func sessionID(in jsonl: String) -> String? {
        AgentCLIRunner.codexSessionID(in: jsonl)
    }
}

/// A report keeps its original provider for its entire durable conversation.
/// Every turn uses the same bounded, cancellable CLI contract as other features.
struct CLIAgentWeeklyProgressAgent: WeeklyProgressAgentRunning {
    let provider: AgentProvider
    let executableURL: URL?
    let timeout: TimeInterval

    init(provider: AgentProvider, executableURL: URL? = nil, timeout: TimeInterval = 3 * 60 * 60) {
        self.provider = provider
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func start(prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        try await run(sessionID: nil, prompt: prompt, directory: directory, stageName: stageName)
    }

    func resume(sessionID: String, prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        try await run(sessionID: sessionID, prompt: prompt, directory: directory, stageName: stageName)
    }

    private func run(
        sessionID: String?,
        prompt: String,
        directory: URL,
        stageName: String
    ) async throws -> WeeklyProgressAgentResult {
        let agentDir = directory.appendingPathComponent("agent", isDirectory: true)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try Data(prompt.utf8).write(
            to: agentDir.appendingPathComponent(stageName + "-prompt.md"),
            options: .atomic
        )
        do {
            let result = try await AgentCLIRunner(executableOverride: executableURL).run(AgentGenerationRequest(
                provider: provider, purpose: .weeklyProgress, prompt: prompt,
                conversation: sessionID.map { AgentConversation(provider: provider, id: $0) },
                directory: directory, timeout: timeout, diagnosticsPrefix: agentDir.appendingPathComponent(stageName)
            ))
            guard let conversation = result.conversation else { throw AgentCLIError.invalidConversation }
            try Data(result.text.utf8).write(to: agentDir.appendingPathComponent(stageName + "-final.txt"), options: .atomic)
            try JSONEncoder().encode(conversation).write(to: agentDir.appendingPathComponent(stageName + "-conversation.json"), options: .atomic)
            return WeeklyProgressAgentResult(sessionID: conversation.id, finalMessage: result.text)
        } catch {
            try? Data(error.localizedDescription.utf8).write(to: agentDir.appendingPathComponent(stageName + ".stderr.log"), options: .atomic)
            throw error
        }
    }
}

enum WeeklyProgressPipelineError: LocalizedError {
    case missingOutput(String)
    case auditDidNotPass(Int)
    case obsoletePromptRevision

    var errorDescription: String? {
        switch self {
        case .missingOutput(let name): return "The weekly-progress agent did not create \(name)."
        case .auditDidNotPass(let attempts):
            return "The deck still failed its audit after \(attempts) passes."
        case .obsoletePromptRevision:
            return "This version was started with an earlier prompt contract. Generate a new review so it replays the reference-session instructions from the beginning."
        }
    }
}

private struct WeeklyProgressAuditMarker: Decodable {
    let passed: Bool
}

enum WeeklyProgressPowerPointInspection {
    /// PowerPoint files are ZIP containers. Counting the canonical slide XML
    /// entries gives the deterministic render cardinality without loading Office.
    static func slideCount(at deckURL: URL) -> Int? {
        guard let entries = archiveEntries(at: deckURL) else { return nil }
        let slides = Set(entries.compactMap { value -> Int? in
                let prefix = "ppt/slides/slide"
                let suffix = ".xml"
                guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
                return Int(value.dropFirst(prefix.count).dropLast(suffix.count))
            })
        return slides.isEmpty ? nil : slides.count
    }

    static func visibleTextRuns(at deckURL: URL) -> [WeeklyProgressPowerPointTextRun]? {
        guard let entries = archiveEntries(at: deckURL) else { return nil }
        let visibleXML = entries.filter { entry in
            guard entry.hasSuffix(".xml") else { return false }
            return entry.hasPrefix("ppt/slides/slide")
                || entry.hasPrefix("ppt/charts/chart")
                || entry.hasPrefix("ppt/diagrams/data")
                || entry.hasPrefix("ppt/diagrams/drawing")
        }.sorted(by: archiveOrder)

        var result: [WeeklyProgressPowerPointTextRun] = []
        for entry in visibleXML {
            guard let data = unzipData(deckURL: deckURL, entry: entry) else { return nil }
            let parser = WeeklyProgressPowerPointTextParser(source: entry)
            guard parser.parse(data) else { return nil }
            result.append(contentsOf: parser.runs)
        }
        return result
    }

    static func hasCompleteRender(deckURL: URL, renderDirectory: URL) -> Bool {
        guard let count = slideCount(at: deckURL), count > 0 else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: renderDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let rendered = Set(files.compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            guard url.pathExtension.lowercased() == "png", name.hasPrefix("slide-") else {
                return nil
            }
            return Int(name.dropFirst("slide-".count))
        })
        return Set(1...count).isSubset(of: rendered)
    }

    private static func archiveEntries(at deckURL: URL) -> [String]? {
        guard FileManager.default.fileExists(atPath: deckURL.path),
              let data = runUnzip(arguments: ["-Z1", deckURL.path]) else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    private static func unzipData(deckURL: URL, entry: String) -> Data? {
        runUnzip(arguments: ["-p", deckURL.path, entry])
    }

    private static func runUnzip(arguments: [String]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func archiveOrder(_ left: String, _ right: String) -> Bool {
        let lhs = archiveRank(left)
        let rhs = archiveRank(right)
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.number != rhs.number { return lhs.number < rhs.number }
        return left < right
    }

    private static func archiveRank(_ entry: String) -> (kind: Int, number: Int) {
        let kind: Int
        if entry.hasPrefix("ppt/slides/slide") { kind = 0 }
        else if entry.hasPrefix("ppt/charts/chart") { kind = 1 }
        else { kind = 2 }
        let digits = entry.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed()
        return (kind, Int(String(digits)) ?? Int.max)
    }
}

struct WeeklyProgressPowerPointTextRun: Codable, Hashable {
    let source: String
    let text: String
}

struct WeeklyProgressLanguageIssue: Codable, Hashable {
    let source: String
    let rule: String
    let excerpt: String
}

struct WeeklyProgressLanguageAudit: Codable, Hashable {
    let passed: Bool
    let textRunCount: Int
    let issues: [WeeklyProgressLanguageIssue]
}

enum WeeklyProgressLanguageInspection {
    private static let discouragedTerms = [
        "trajectory", "conditioning", "gains", "spending",
    ]

    static func audit(deckURL: URL) -> WeeklyProgressLanguageAudit {
        guard let runs = WeeklyProgressPowerPointInspection.visibleTextRuns(at: deckURL) else {
            return WeeklyProgressLanguageAudit(
                passed: false,
                textRunCount: 0,
                issues: [WeeklyProgressLanguageIssue(
                    source: deckURL.lastPathComponent,
                    rule: "PowerPoint text extraction",
                    excerpt: "Argus could not read the visible PowerPoint text."
                )]
            )
        }
        guard !runs.isEmpty else {
            return WeeklyProgressLanguageAudit(
                passed: false,
                textRunCount: 0,
                issues: [WeeklyProgressLanguageIssue(
                    source: deckURL.lastPathComponent,
                    rule: "Visible slide text",
                    excerpt: "The PowerPoint contains no readable visible text."
                )]
            )
        }

        let grouped = Dictionary(grouping: runs, by: \.source)
        let orderedSources = grouped.keys.sorted(by: sourceOrder)
        var issues: [WeeklyProgressLanguageIssue] = []
        var definedTerms: Set<String> = []

        for source in orderedSources {
            let text = (grouped[source] ?? []).map(\.text).joined(separator: " ")
            let normalized = text.replacingOccurrences(of: "\u{00a0}", with: " ")
            appendCharacterIssue("—", rule: "Em dash", source: source, text: normalized, to: &issues)
            if normalized.contains("--") {
                appendUnique(
                    WeeklyProgressLanguageIssue(
                        source: source,
                        rule: "Double hyphen",
                        excerpt: excerpt(normalized)
                    ),
                    to: &issues
                )
            }
            appendCharacterIssue(":", rule: "Colon", source: source, text: normalized, to: &issues)
            appendCharacterIssue(";", rule: "Semicolon", source: source, text: normalized, to: &issues)

            let contrastPatterns = [
                #"\bnot\b[^.!?]{0,100}\bbut\b"#,
                #",\s*not\b"#,
                #"\bnot\s+(?:merely|just|only)\b"#,
            ]
            if contrastPatterns.contains(where: { containsPattern($0, in: normalized) }) {
                appendUnique(
                    WeeklyProgressLanguageIssue(
                        source: source,
                        rule: "Rhetorical contrast formula",
                        excerpt: excerpt(normalized)
                    ),
                    to: &issues
                )
            }

            for term in discouragedTerms where containsWord(term, in: normalized) {
                if definitionExists(for: term, in: normalized) {
                    definedTerms.insert(term)
                } else if !definedTerms.contains(term) {
                    appendUnique(
                        WeeklyProgressLanguageIssue(
                            source: source,
                            rule: "Unexplained compressed term: \(term)",
                            excerpt: excerpt(normalized)
                        ),
                        to: &issues
                    )
                }
            }
        }

        return WeeklyProgressLanguageAudit(
            passed: issues.isEmpty,
            textRunCount: runs.count,
            issues: issues
        )
    }

    private static func appendCharacterIssue(
        _ character: Character,
        rule: String,
        source: String,
        text: String,
        to issues: inout [WeeklyProgressLanguageIssue]
    ) {
        guard text.contains(character) else { return }
        appendUnique(
            WeeklyProgressLanguageIssue(source: source, rule: rule, excerpt: excerpt(text)),
            to: &issues
        )
    }

    private static func definitionExists(for term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return [
            #"\b"# + escaped + #"\b\s+(?:means|refers\s+to|is\s+defined\s+as|denotes|describes|measures)\b"#,
            #"\b(?:define|defined)\s+"# + escaped + #"\b"#,
        ].contains { containsPattern($0, in: text) }
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        containsPattern(#"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#, in: text)
    }

    private static func containsPattern(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func appendUnique(
        _ issue: WeeklyProgressLanguageIssue,
        to issues: inout [WeeklyProgressLanguageIssue]
    ) {
        if !issues.contains(issue) { issues.append(issue) }
    }

    private static func excerpt(_ text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(singleLine.prefix(240))
    }

    private static func sourceOrder(_ left: String, _ right: String) -> Bool {
        let lhs = sourceRank(left)
        let rhs = sourceRank(right)
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.number != rhs.number { return lhs.number < rhs.number }
        return left < right
    }

    private static func sourceRank(_ source: String) -> (kind: Int, number: Int) {
        let kind = source.hasPrefix("ppt/slides/slide") ? 0 : 1
        let digits = source.reversed().drop { !$0.isNumber }.prefix { $0.isNumber }.reversed()
        return (kind, Int(String(digits)) ?? Int.max)
    }
}

private final class WeeklyProgressPowerPointTextParser: NSObject, XMLParserDelegate {
    let source: String
    private(set) var runs: [WeeklyProgressPowerPointTextRun] = []
    private var collectingText = false
    private var buffer = ""
    private var chartStringCacheDepth = 0

    init(source: String) { self.source = source }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        if name == "c:strCache" || name == "c:multiLvlStrCache" {
            chartStringCacheDepth += 1
        }
        let isDrawingText = name == "a:t" || name == "t" || elementName == "a:t"
        let isChartString = chartStringCacheDepth > 0 && (name == "c:v" || elementName == "c:v")
        guard isDrawingText || isChartString else { return }
        collectingText = true
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        let isDrawingText = name == "a:t" || name == "t" || elementName == "a:t"
        let isChartString = chartStringCacheDepth > 0 && (name == "c:v" || elementName == "c:v")
        if collectingText && (isDrawingText || isChartString) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                runs.append(WeeklyProgressPowerPointTextRun(source: source, text: text))
            }
            collectingText = false
            buffer = ""
        }
        if name == "c:strCache" || name == "c:multiLvlStrCache" {
            chartStringCacheDepth = max(0, chartStringCacheDepth - 1)
        }
    }
}

/// Evidence-first, multi-turn generation. The on-disk state file is updated at
/// every boundary so a UI can observe progress without coupling itself to Codex.
actor WeeklyProgressPipeline {
    let store: WeeklyProgressDiskStore
    let collector: WeeklyProgressEvidenceCollector
    let artifactRootURL: URL
    let agent: (any WeeklyProgressAgentRunning)?
    /// Additional machine-guided repairs allowed after replaying every original
    /// correction turn from the reference session.
    let maximumAuditPasses: Int

    init(
        store: WeeklyProgressDiskStore = WeeklyProgressDiskStore(),
        journalDirectory: URL = ActivityJournal.dirURL,
        artifactRootURL: URL = ArtifactStore.defaultRootURL,
        agent: (any WeeklyProgressAgentRunning)? = nil,
        maximumAuditPasses: Int = 3
    ) {
        self.store = store
        self.collector = WeeklyProgressEvidenceCollector(journalDirectory: journalDirectory)
        self.artifactRootURL = artifactRootURL
        self.agent = agent
        self.maximumAuditPasses = max(1, maximumAuditPasses)
    }

    func generate(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        remoteRequestID: String? = nil
    )
        async throws -> WeeklyProgressGeneration {
        let generation = try prepare(
            project: project,
            week: week,
            remoteRequestID: remoteRequestID
        )
        return try await resume(generationDirectory: generation.directory)
    }

    /// Creates the durable identity before the long-running agent work starts.
    /// Remote callers can therefore receive a generation id immediately and
    /// safely reconnect while the pipeline continues on this Mac.
    func prepare(
        project: WeeklyProgressProject,
        week: WeeklyProgressWeek,
        remoteRequestID: String? = nil
    ) throws -> WeeklyProgressGeneration {
        var generation = try store.createGeneration(
            project: project,
            week: week,
            remoteRequestID: remoteRequestID
        )
        let provider = agent?.provider ?? AgentTaskPurpose.weeklyProgress.selectedProvider()
        generation.manifest.agentProvider = provider
        generation.manifest.model = AgentTaskPurpose.weeklyProgress.model(for: provider) ?? "configured"
        generation.manifest.reasoningEffort = provider == .codex ? AgentTaskPurpose.weeklyProgress.reasoningEffort : "configured"
        try store.write(generation.manifest, in: generation.directory)
        try WeeklyProgressJSON.write(generation.manifest, to: generation.directory.appendingPathComponent("request.json"))
        return generation
    }

    /// Continue an interrupted or explicitly retried generation from its durable
    /// file boundary. Each call allows another bounded set of audit repairs.
    func resume(generationDirectory: URL) async throws -> WeeklyProgressGeneration {
        var generation = WeeklyProgressGeneration(
            directory: generationDirectory,
            manifest: try store.load(from: generationDirectory)
        )
        if generation.manifest.stage == .complete { return generation }
        guard generation.manifest.promptRevision == WeeklyProgressPrompts.revision else {
            throw WeeklyProgressPipelineError.obsoletePromptRevision
        }
        do {
            let evidenceURL = generationDirectory.appendingPathComponent("evidence/journal.jsonl")
            if generation.manifest.evidence == nil
                || !FileManager.default.fileExists(atPath: evidenceURL.path) {
                let evidence = try collector.collect(
                    project: generation.manifest.project,
                    week: generation.manifest.week,
                    into: generationDirectory.appendingPathComponent("evidence", isDirectory: true)
                )
                generation.manifest.evidence = evidence
            }
            generation.manifest.error = nil
            try persist(&generation, stage: .reconstructingResearch)
        } catch {
            generation.manifest.error = error.localizedDescription
            try? persist(&generation, stage: .failed)
            throw error
        }
        return try await continueGeneration(generation)
    }

    private func continueGeneration(_ source: WeeklyProgressGeneration)
        async throws -> WeeklyProgressGeneration {
        var generation = source
        let provider = generation.manifest.agentProvider ?? .codex
        let agent = self.agent ?? CLIAgentWeeklyProgressAgent(provider: provider)
        guard agent.provider == provider else { throw AgentCLIError.providerMismatch }
        var sessionID = generation.manifest.conversation?.id
        let priorReview = store.latestCompletedGeneration(
            projectID: generation.manifest.project.id,
            before: generation.manifest.week
        )
        let artifactReport = try? await ArtifactDiskStore(rootURL: artifactRootURL).loadReport()
        let artifactReferences = WeeklyProgressPrompts.artifactReferences(
            artifactReport?.records ?? [],
            rootURL: artifactRootURL,
            project: generation.manifest.project,
            week: generation.manifest.week
        )
        do {
            if !(exists("research-report.md", in: generation.directory)
                && exists("evidence-ledger.json", in: generation.directory)) {
                try persist(&generation, stage: .reconstructingResearch)
                let result: WeeklyProgressAgentResult
                if let sessionID {
                    result = try await agent.resume(
                        sessionID: sessionID,
                        prompt: WeeklyProgressPrompts.reconstructResearch(
                            project: generation.manifest.project,
                            week: generation.manifest.week,
                            artifactReferences: artifactReferences,
                            priorReview: priorReview
                        ),
                        in: generation.directory,
                        stageName: uniqueStageName("01-research-resume", in: generation.directory)
                    )
                } else {
                    result = try await agent.start(
                        prompt: WeeklyProgressPrompts.reconstructResearch(
                            project: generation.manifest.project,
                            week: generation.manifest.week,
                            artifactReferences: artifactReferences,
                            priorReview: priorReview
                        ),
                        in: generation.directory,
                        stageName: "01-research"
                    )
                }
                sessionID = result.sessionID
                generation.manifest.recordConversation(result.sessionID, provider: provider)
                try persist(&generation, stage: .reconstructingResearch)
                try require("research-report.md", in: generation.directory)
                try require("evidence-ledger.json", in: generation.directory)
            }
            generation.manifest.outputs["researchReport"] = "research-report.md"
            generation.manifest.outputs["evidenceLedger"] = "evidence-ledger.json"

            if !exists("draft.pptx", in: generation.directory) {
                try persist(&generation, stage: .draftingSlides)
                let result = try await runTurn(
                    agent: agent,
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.draftSlides(
                        project: generation.manifest.project,
                        week: generation.manifest.week,
                        priorReview: priorReview
                    ),
                    directory: generation.directory,
                    stageName: uniqueStageName("02-draft", in: generation.directory)
                )
                sessionID = result.sessionID
                generation.manifest.recordConversation(result.sessionID, provider: provider)
                try persist(&generation, stage: .draftingSlides)
                try require("draft.pptx", in: generation.directory)
            }
            generation.manifest.outputs["draftDeck"] = "draft.pptx"

            let requiredCorrections = WeeklyProgressPrompts.requiredReferenceCorrectionCount
            if generation.manifest.auditPasses >= requiredCorrections,
               auditPassed(in: generation.directory) {
                return try complete(generation)
            }

            while generation.manifest.auditPasses < requiredCorrections {
                let pass = generation.manifest.auditPasses + 1
                try persist(&generation, stage: .auditingSlides)
                let result = try await runTurn(
                    agent: agent,
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.referenceCorrection(pass: pass),
                    directory: generation.directory,
                    stageName: String(format: "03-reference-correction-%02d", pass)
                )
                sessionID = result.sessionID
                generation.manifest.recordConversation(result.sessionID, provider: provider)
                generation.manifest.auditPasses = pass
                try persist(&generation, stage: .auditingSlides)
                _ = auditPassed(in: generation.directory)
            }

            if auditPassed(in: generation.directory) {
                return try complete(generation)
            }

            for _ in 0..<maximumAuditPasses {
                let pass = generation.manifest.auditPasses + 1
                try persist(&generation, stage: .auditingSlides)
                let result = try await runTurn(
                    agent: agent,
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.repairSlides(pass: pass),
                    directory: generation.directory,
                    stageName: String(format: "04-validation-repair-%02d", pass)
                )
                sessionID = result.sessionID
                generation.manifest.recordConversation(result.sessionID, provider: provider)
                generation.manifest.auditPasses = pass
                try persist(&generation, stage: .auditingSlides)
                if auditPassed(in: generation.directory) {
                    return try complete(generation)
                }
            }
            throw WeeklyProgressPipelineError.auditDidNotPass(generation.manifest.auditPasses)
        } catch {
            generation.manifest.error = error.localizedDescription
            try? persist(&generation, stage: .failed)
            throw error
        }
    }

    private func runTurn(
        agent: any WeeklyProgressAgentRunning,
        sessionID: String?,
        prompt: String,
        directory: URL,
        stageName: String
    ) async throws -> WeeklyProgressAgentResult {
        if let sessionID {
            return try await agent.resume(
                sessionID: sessionID,
                prompt: prompt,
                in: directory,
                stageName: stageName
            )
        }
        let restoredPrompt = """
        This is a restored weekly-progress generation. Read the existing request, evidence, report,
        ledger, deck, and audit files in this directory before continuing.

        \(prompt)
        """
        return try await agent.start(
            prompt: restoredPrompt,
            in: directory,
            stageName: stageName
        )
    }

    private func complete(_ source: WeeklyProgressGeneration) throws -> WeeklyProgressGeneration {
        var generation = source
        generation.manifest.outputs["finalDeck"] = "weekly-progress.pptx"
        generation.manifest.outputs["audit"] = "audit.json"
        generation.manifest.outputs["languageAudit"] = "language-audit.json"
        generation.manifest.outputs["render"] = "render/final"
        generation.manifest.error = nil
        try persist(&generation, stage: .complete)
        return generation
    }

    private func persist(
        _ generation: inout WeeklyProgressGeneration,
        stage: WeeklyProgressStage
    ) throws {
        generation.manifest.stage = stage
        generation.manifest.updatedAt = Date()
        try store.write(generation.manifest, in: generation.directory)
    }

    private func require(_ relativePath: String, in directory: URL) throws {
        guard exists(relativePath, in: directory) else {
            throw WeeklyProgressPipelineError.missingOutput(relativePath)
        }
    }

    private func exists(_ relativePath: String, in directory: URL) -> Bool {
        let url = directory.appendingPathComponent(relativePath)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    private func uniqueStageName(_ base: String, in directory: URL) -> String {
        let agentDirectory = directory.appendingPathComponent("agent", isDirectory: true)
        if !FileManager.default.fileExists(
            atPath: agentDirectory.appendingPathComponent(base + ".jsonl").path
        ) { return base }
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: agentDirectory.appendingPathComponent("\(base)-\(suffix).jsonl").path
        ) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func auditPassed(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("audit.json")
        let deck = directory.appendingPathComponent("weekly-progress.pptx")
        let render = directory.appendingPathComponent("render/final", isDirectory: true)
        let languageAudit = WeeklyProgressLanguageInspection.audit(deckURL: deck)
        try? WeeklyProgressJSON.write(
            languageAudit,
            to: directory.appendingPathComponent("language-audit.json")
        )
        guard FileManager.default.fileExists(atPath: url.path),
              (try? WeeklyProgressJSON.read(WeeklyProgressAuditMarker.self, from: url).passed) == true,
              languageAudit.passed,
              WeeklyProgressPowerPointInspection.hasCompleteRender(
                deckURL: deck,
                renderDirectory: render
              ) else {
            return false
        }
        return true
    }
}
