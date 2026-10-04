import Foundation

// Weekly Progress wire contract. The Mac app (WeeklyProgressRemoteService) is
// the only provider; its broker relays `/weekly-progress/*` opaquely
// (internal/weeklyprogressbridge). Same shapes the Android client parses.

struct WeeklyProgressProject: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let panelCount: Int
    let workspaceCount: Int
    let updatedAt: String

    enum CodingKeys: String, CodingKey { case id, name, panelCount, workspaceCount, updatedAt }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        panelCount = try c.decodeIfPresent(Int.self, forKey: .panelCount) ?? 0
        workspaceCount = try c.decodeIfPresent(Int.self, forKey: .workspaceCount) ?? 0
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    /// "3 panels · 1 folder", as on Android.
    var sourceSummary: String {
        var parts: [String] = []
        if panelCount > 0 { parts.append("\(panelCount) \(panelCount == 1 ? "panel" : "panels")") }
        if workspaceCount > 0 { parts.append("\(workspaceCount) \(workspaceCount == 1 ? "folder" : "folders")") }
        return parts.isEmpty ? "Configured on the Mac" : parts.joined(separator: " · ")
    }
}

struct WeeklyProgressGeneration: Decodable, Identifiable, Hashable {
    let id: String
    let projectID: String
    let projectName: String
    /// `yyyy-MM-dd`, the Monday of the week in the Mac's time zone.
    let weekStart: String
    let weekEndExclusive: String
    let createdAt: String
    let updatedAt: String
    let stage: String
    let state: String
    let auditPasses: Int
    let slideCount: Int
    let hasDeck: Bool
    let hasReport: Bool
    let evidenceEventCount: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, projectID, projectName, weekStart, weekEndExclusive, createdAt, updatedAt, stage, state
        case auditPasses, slideCount, hasDeck, hasReport, evidenceEventCount, error
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectID = try c.decode(String.self, forKey: .projectID)
        projectName = try c.decode(String.self, forKey: .projectName)
        weekStart = try c.decode(String.self, forKey: .weekStart)
        weekEndExclusive = try c.decode(String.self, forKey: .weekEndExclusive)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        auditPasses = try c.decodeIfPresent(Int.self, forKey: .auditPasses) ?? 0
        slideCount = try c.decodeIfPresent(Int.self, forKey: .slideCount) ?? 0
        hasDeck = try c.decodeIfPresent(Bool.self, forKey: .hasDeck) ?? false
        hasReport = try c.decodeIfPresent(Bool.self, forKey: .hasReport) ?? false
        evidenceEventCount = try c.decodeIfPresent(Int.self, forKey: .evidenceEventCount)
        let rawError = try c.decodeIfPresent(String.self, forKey: .error)?.trimmingCharacters(in: .whitespacesAndNewlines)
        error = rawError?.isEmpty == false ? rawError : nil
    }

    var isActive: Bool { state == "active" }
    var isComplete: Bool { state == "complete" }
    var canResume: Bool { state == "interrupted" || state == "failed" }

    /// Orders versions by creation time (ISO8601), falling back to the raw string.
    var createdDate: Date { WeeklyProgressTime.parse(createdAt) ?? .distantPast }

    /// Identifies the rendered assets of this generation: a resumed or audited
    /// run rewrites its slides, and only then does `updatedAt` move.
    var assetRevision: String { updatedAt.isEmpty ? "initial" : updatedAt }
}

struct WeeklyProgressActiveOperation: Decodable, Hashable {
    let generationID: String
    let projectID: String
    let projectName: String
    let weekStart: String
    let stage: String
    let startedAt: String

    enum CodingKeys: String, CodingKey { case generationID, projectID, projectName, weekStart, stage, startedAt }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        generationID = try c.decode(String.self, forKey: .generationID)
        projectID = try c.decode(String.self, forKey: .projectID)
        projectName = try c.decode(String.self, forKey: .projectName)
        weekStart = try c.decode(String.self, forKey: .weekStart)
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt) ?? ""
    }
}

struct WeeklyProgressCatalog: Decodable, Equatable {
    var generatedAt: String = ""
    var projects: [WeeklyProgressProject] = []
    var generations: [WeeklyProgressGeneration] = []
    var activeOperation: WeeklyProgressActiveOperation?

    init() {}

    enum CodingKeys: String, CodingKey { case generatedAt, projects, generations, activeOperation }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        projects = try c.decodeIfPresent([WeeklyProgressProject].self, forKey: .projects) ?? []
        generations = try c.decodeIfPresent([WeeklyProgressGeneration].self, forKey: .generations) ?? []
        activeOperation = try c.decodeIfPresent(WeeklyProgressActiveOperation.self, forKey: .activeOperation)
    }

    static func decode(_ data: Data) throws -> WeeklyProgressCatalog {
        try JSONDecoder().decode(WeeklyProgressCatalog.self, from: data)
    }
}

// MARK: Stages

enum WeeklyProgressStage {
    /// The four working stages, in order, for the progress banner.
    static let steps = ["collectingEvidence", "reconstructingResearch", "draftingSlides", "auditingSlides"]

    static func title(_ stage: String) -> String {
        switch stage {
        case "collectingEvidence": return "Collecting evidence"
        case "reconstructingResearch": return "Reconstructing research"
        case "draftingSlides": return "Building slides"
        case "auditingSlides": return "Checking slides"
        case "complete": return "Ready"
        case "failed": return "Needs attention"
        default: return "Preparing"
        }
    }

    /// Index of the stage among `steps` (0 for unknown/preparing).
    static func index(_ stage: String) -> Int { steps.firstIndex(of: stage) ?? 0 }

    static func stateTitle(_ state: String) -> String {
        switch state {
        case "active": return "IN PROGRESS"
        case "complete": return "READY"
        case "failed": return "FAILED"
        case "interrupted": return "INTERRUPTED"
        default: return state.uppercased()
        }
    }
}

// MARK: Time and weeks

enum WeeklyProgressTime {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        return plain.date(from: raw) ?? fractional.date(from: raw)
    }
}

/// Weeks are Monday-based and named by their Monday as `yyyy-MM-dd` in local
/// time (the Mac's convention). All math goes through a Gregorian calendar so
/// DST transitions and the device's own calendar settings don't skew a week.
enum WeeklyProgressWeek {
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    /// Midnight of the Monday on or before `date`.
    static func monday(containing date: Date, calendar: Calendar = calendar()) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)   // 1 = Sunday … 7 = Saturday
        let back = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -back, to: day) ?? day
    }

    static func key(for date: Date, calendar: Calendar = calendar()) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    static func date(fromKey key: String, calendar: Calendar = calendar()) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func currentKey(now: Date = Date(), calendar: Calendar = calendar()) -> String {
        key(for: monday(containing: now, calendar: calendar), calendar: calendar)
    }

    /// The Monday `weeks` weeks away from the week named by `key`.
    static func shift(_ key: String, by weeks: Int, calendar: Calendar = calendar()) -> String {
        let start = date(fromKey: key, calendar: calendar).map { monday(containing: $0, calendar: calendar) }
            ?? monday(containing: Date(), calendar: calendar)
        let moved = calendar.date(byAdding: .day, value: 7 * weeks, to: start) ?? start
        return Self.key(for: moved, calendar: calendar)
    }

    /// "Sep 28 – Oct 4, 2026".
    static func rangeTitle(_ key: String, calendar: Calendar = calendar(), locale: Locale = .current) -> String {
        guard let start = date(fromKey: key, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 6, to: start) else { return key }
        let f = DateIntervalFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: start, to: end)
    }
}

// MARK: Shelves

/// Which reviews a given selection shows. Kept free of UI so every view (and
/// the tests) agrees on what "the review for this week" means.
enum WeeklyProgressShelf {
    static func newestFirst(_ a: WeeklyProgressGeneration, _ b: WeeklyProgressGeneration) -> Bool {
        a.createdDate != b.createdDate ? a.createdDate > b.createdDate : a.createdAt > b.createdAt
    }

    /// One card per project for `week`: the newest version, except that a
    /// replacement review is persisted before it has slides — keep the
    /// previous readable edition on the shelf while the banner shows the run.
    static func allProjects(_ generations: [WeeklyProgressGeneration], week: String) -> [WeeklyProgressGeneration] {
        let byProject = Dictionary(grouping: generations.filter { $0.weekStart == week }, by: \.projectID)
        return byProject.values.compactMap { versions -> WeeklyProgressGeneration? in
            let sorted = versions.sorted(by: newestFirst)
            guard let newest = sorted.first else { return nil }
            if newest.isActive && newest.slideCount == 0 {
                return sorted.first { $0.slideCount > 0 } ?? newest
            }
            return newest
        }
        .sorted {
            let order = $0.projectName.localizedCaseInsensitiveCompare($1.projectName)
            return order == .orderedSame ? $0.projectID < $1.projectID : order == .orderedAscending
        }
    }

    /// Every version of one project's review for `week`, newest first.
    static func project(_ generations: [WeeklyProgressGeneration], projectID: String, week: String) -> [WeeklyProgressGeneration] {
        generations.filter { $0.projectID == projectID && $0.weekStart == week }.sorted(by: newestFirst)
    }

    struct WeekSection: Identifiable, Equatable {
        let week: String
        let versions: [WeeklyProgressGeneration]
        var id: String { week }
    }

    /// One project's history grouped by week, newest week and version first.
    static func calendar(_ generations: [WeeklyProgressGeneration], projectID: String) -> [WeekSection] {
        Dictionary(grouping: generations.filter { $0.projectID == projectID }, by: \.weekStart)
            .map { WeekSection(week: $0.key, versions: $0.value.sorted(by: newestFirst)) }
            .sorted { $0.week > $1.week }
    }

    static func versionLabel(_ count: Int) -> String { count == 1 ? "1 version" : "\(count) versions" }
}

// MARK: Commands

/// Idempotency for generate/resume. A request id is persisted per action
/// before it is sent, so a retry after an ambiguous failure (the Mac may have
/// accepted the command) is deduplicated by the Mac instead of starting a
/// second expensive run.
struct WeeklyProgressRequestIDs {
    enum Action: Hashable {
        case generate(projectID: String, week: String)
        case resume(generationID: String)

        var storageKey: String {
            switch self {
            case let .generate(project, week): return "argus.weeklyProgress.request.generate:\(project):\(week)"
            case let .resume(generation): return "argus.weeklyProgress.resume.\(generation)"
            }
        }

        var prefix: String {
            switch self {
            case .generate: return "ios-"
            case .resume: return "ios-resume-"
            }
        }
    }

    let defaults: UserDefaults

    /// The stored id for `action`, minting and persisting one if needed.
    func id(for action: Action) -> String {
        if let existing = defaults.string(forKey: action.storageKey), !existing.isEmpty { return existing }
        let fresh = action.prefix + UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: action.storageKey)
        return fresh
    }

    /// Record the outcome; `status` is nil when no HTTP response arrived.
    func settle(_ action: Action, status: Int?) {
        if !Self.shouldKeep(status: status) { defaults.removeObject(forKey: action.storageKey) }
    }

    /// Keep the id whenever the Mac may have accepted (or may still accept)
    /// the same command: transport failures, 5xx, and 409 (busy). Success and
    /// any other 4xx are definitive, so the next attempt gets a fresh id.
    static func shouldKeep(status: Int?) -> Bool {
        guard let status else { return true }
        if (200..<300).contains(status) { return false }
        if status == 409 { return true }
        if (400..<500).contains(status) { return false }
        return true
    }
}

enum WeeklyProgressMessages {
    static let brokerUnavailable = "Your Mac broker is not available."
    static let providerMissing = "Open the updated Argus app on your Mac to use Weekly Progress."
    static let showingSaved = "The Mac is unavailable. Showing the last saved catalog."

    /// The banner text for a failed generate (`resume == false`) or resume.
    /// `status` is nil for transport failures; `serverError` is the body's `error`.
    static func commandFailure(resume: Bool, status: Int?, serverError: String?) -> String {
        let server = serverError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = server?.isEmpty == false ? server : nil
        switch status {
        case nil:
            return "The Mac could not be reached. Trying again is safe — it won't start a duplicate review."
        case 503?:
            // The broker answers 503 itself when the Mac app isn't registered.
            return resume ? "Open Argus on your Mac before resuming a review."
                          : "Open Argus on your Mac before starting a review."
        case 409?:
            return detail ?? "Another Weekly Progress review is already running on the Mac."
        default:
            return detail ?? (resume ? "The Mac could not resume this review." : "The Mac could not start this review.")
        }
    }
}

enum WeeklyProgressFiles {
    /// `<project>-week-of-<week>.pptx`, matching the Mac's download name.
    static func deckFilename(projectName: String, weekStart: String) -> String {
        "\(sanitize(projectName, fallback: "weekly-progress"))-week-of-\(sanitize(weekStart, fallback: "unknown")).pptx"
    }

    /// `[^A-Za-z0-9._-]+` → `-`, trimmed of dashes (the Mac's safeFilename).
    static func sanitize(_ raw: String, fallback: String) -> String {
        let cleaned = raw.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? fallback : cleaned
    }
}
