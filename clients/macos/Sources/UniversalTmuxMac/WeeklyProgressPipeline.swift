import Foundation

struct WeeklyProgressAgentResult: Equatable {
    let sessionID: String
    let finalMessage: String
}

protocol WeeklyProgressAgentRunning {
    func start(prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult
    func resume(sessionID: String, prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult
}

enum CodexWeeklyProgressCommand {
    static let model = "gpt-5.6-sol"
    static let reasoningEffort = "xhigh"

    static func initialArguments(directory: URL, finalMessageURL: URL) -> [String] {
        [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "workspace-write",
            "--color", "never",
            "-C", directory.path,
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
            "--json",
            "-o", finalMessageURL.path,
            "-",
        ]
    }

    static func resumeArguments(sessionID: String, finalMessageURL: URL) -> [String] {
        [
            "exec", "resume",
            "--skip-git-repo-check",
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
            "--json",
            "-o", finalMessageURL.path,
            sessionID,
            "-",
        ]
    }

    static func sessionID(in jsonl: String) -> String? {
        for line in jsonl.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "thread.started",
                  let sessionID = object["thread_id"] as? String,
                  !sessionID.isEmpty else { continue }
            return sessionID
        }
        return nil
    }
}

enum WeeklyProgressAgentError: LocalizedError {
    case executableMissing(String)
    case failed(stage: String, status: Int32, detail: String)
    case missingSessionID(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path): return "Codex CLI was not found at \(path)."
        case .failed(let stage, let status, let detail):
            return "Codex stage \(stage) exited with status \(status). \(detail)"
        case .missingSessionID(let stage): return "Codex stage \(stage) did not report a session ID."
        case .timedOut(let stage): return "Codex stage \(stage) exceeded its time limit."
        }
    }
}

/// Runs one durable multi-turn Codex conversation. The JSON event stream and
/// stderr for every turn are kept beside the generated report and deck.
struct CodexWeeklyProgressAgent: WeeklyProgressAgentRunning {
    let executableURL: URL
    let timeout: TimeInterval

    init(executableURL: URL = Self.defaultExecutableURL, timeout: TimeInterval = 3 * 60 * 60) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func start(prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        let finalURL = agentDirectory(directory).appendingPathComponent(stageName + "-final.txt")
        let output = try await run(
            arguments: CodexWeeklyProgressCommand.initialArguments(
                directory: directory,
                finalMessageURL: finalURL
            ),
            prompt: prompt,
            directory: directory,
            stageName: stageName
        )
        guard let sessionID = CodexWeeklyProgressCommand.sessionID(in: output) else {
            throw WeeklyProgressAgentError.missingSessionID(stageName)
        }
        return WeeklyProgressAgentResult(
            sessionID: sessionID,
            finalMessage: (try? String(contentsOf: finalURL, encoding: .utf8)) ?? ""
        )
    }

    func resume(sessionID: String, prompt: String, in directory: URL, stageName: String) async throws
        -> WeeklyProgressAgentResult {
        let finalURL = agentDirectory(directory).appendingPathComponent(stageName + "-final.txt")
        _ = try await run(
            arguments: CodexWeeklyProgressCommand.resumeArguments(
                sessionID: sessionID,
                finalMessageURL: finalURL
            ),
            prompt: prompt,
            directory: directory,
            stageName: stageName
        )
        return WeeklyProgressAgentResult(
            sessionID: sessionID,
            finalMessage: (try? String(contentsOf: finalURL, encoding: .utf8)) ?? ""
        )
    }

    private func run(
        arguments: [String],
        prompt: String,
        directory: URL,
        stageName: String
    ) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WeeklyProgressAgentError.executableMissing(executableURL.path)
        }
        let agentDir = agentDirectory(directory)
        try FileManager.default.createDirectory(at: agentDir, withIntermediateDirectories: true)
        try Data(prompt.utf8).write(
            to: agentDir.appendingPathComponent(stageName + "-prompt.md"),
            options: .atomic
        )
        let outputURL = agentDir.appendingPathComponent(stageName + ".jsonl")
        let errorURL = agentDir.appendingPathComponent(stageName + ".stderr.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let status = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                let additions = [
                    "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                ]
                let currentPath = environment["PATH"] ?? ""
                environment["PATH"] = (additions + [currentPath]).filter { !$0.isEmpty }
                    .joined(separator: ":")
                process.environment = environment
                let input = Pipe()
                process.standardInput = input
                guard let output = try? FileHandle(forWritingTo: outputURL),
                      let errors = try? FileHandle(forWritingTo: errorURL) else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    try? output.close(); try? errors.close()
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    input.fileHandleForWriting.write(Data(prompt.utf8))
                    try? input.fileHandleForWriting.close()
                }
                let timeoutLock = NSLock()
                var didTimeOut = false
                let killer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timeoutLock.lock()
                    didTimeOut = true
                    timeoutLock.unlock()
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeout,
                    execute: killer
                )
                process.waitUntilExit()
                killer.cancel()
                timeoutLock.lock()
                let wasTimedOut = didTimeOut
                timeoutLock.unlock()
                try? output.close(); try? errors.close()
                if wasTimedOut {
                    continuation.resume(throwing: WeeklyProgressAgentError.timedOut(stageName))
                } else {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        guard status == 0 else {
            let detail = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WeeklyProgressAgentError.failed(
                stage: stageName,
                status: status,
                detail: String(detail.suffix(2_000))
            )
        }
        return output
    }

    private func agentDirectory(_ generationDirectory: URL) -> URL {
        generationDirectory.appendingPathComponent("agent", isDirectory: true)
    }

    static let defaultExecutableURL: URL = {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let path = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path.isEmpty ? candidates[0] : path)
    }()
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
    let agent: any WeeklyProgressAgentRunning
    /// Additional machine-guided repairs allowed after replaying every original
    /// correction turn from the reference session.
    let maximumAuditPasses: Int

    init(
        store: WeeklyProgressDiskStore = WeeklyProgressDiskStore(),
        journalDirectory: URL = ActivityJournal.dirURL,
        agent: any WeeklyProgressAgentRunning = CodexWeeklyProgressAgent(),
        maximumAuditPasses: Int = 3
    ) {
        self.store = store
        self.collector = WeeklyProgressEvidenceCollector(journalDirectory: journalDirectory)
        self.agent = agent
        self.maximumAuditPasses = max(1, maximumAuditPasses)
    }

    func generate(project: WeeklyProgressProject, week: WeeklyProgressWeek)
        async throws -> WeeklyProgressGeneration {
        var generation = try store.createGeneration(project: project, week: week)
        do {
            let evidence = try collector.collect(
                project: project,
                week: week,
                into: generation.directory.appendingPathComponent("evidence", isDirectory: true)
            )
            generation.manifest.evidence = evidence
            try persist(&generation, stage: .reconstructingResearch)
        } catch {
            generation.manifest.error = error.localizedDescription
            try? persist(&generation, stage: .failed)
            throw error
        }
        return try await continueGeneration(generation)
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
        var sessionID = generation.manifest.codexSessionID
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
                            week: generation.manifest.week
                        ),
                        in: generation.directory,
                        stageName: uniqueStageName("01-research-resume", in: generation.directory)
                    )
                } else {
                    result = try await agent.start(
                        prompt: WeeklyProgressPrompts.reconstructResearch(
                            project: generation.manifest.project,
                            week: generation.manifest.week
                        ),
                        in: generation.directory,
                        stageName: "01-research"
                    )
                }
                sessionID = result.sessionID
                generation.manifest.codexSessionID = result.sessionID
                try persist(&generation, stage: .reconstructingResearch)
                try require("research-report.md", in: generation.directory)
                try require("evidence-ledger.json", in: generation.directory)
            }
            generation.manifest.outputs["researchReport"] = "research-report.md"
            generation.manifest.outputs["evidenceLedger"] = "evidence-ledger.json"

            if !exists("draft.pptx", in: generation.directory) {
                try persist(&generation, stage: .draftingSlides)
                let result = try await runTurn(
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.draftSlides(
                        project: generation.manifest.project,
                        week: generation.manifest.week
                    ),
                    directory: generation.directory,
                    stageName: uniqueStageName("02-draft", in: generation.directory)
                )
                sessionID = result.sessionID
                generation.manifest.codexSessionID = result.sessionID
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
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.referenceCorrection(pass: pass),
                    directory: generation.directory,
                    stageName: String(format: "03-reference-correction-%02d", pass)
                )
                sessionID = result.sessionID
                generation.manifest.codexSessionID = result.sessionID
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
                    sessionID: sessionID,
                    prompt: WeeklyProgressPrompts.repairSlides(pass: pass),
                    directory: generation.directory,
                    stageName: String(format: "04-validation-repair-%02d", pass)
                )
                sessionID = result.sessionID
                generation.manifest.codexSessionID = result.sessionID
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
