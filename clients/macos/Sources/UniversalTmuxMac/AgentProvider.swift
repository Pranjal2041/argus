import Foundation

/// Provider metadata and format validation live at one boundary. Feature UIs
/// enumerate this catalog instead of maintaining Claude/Codex-only lists.
enum AgentProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, devin

    var id: String { rawValue }
    var displayName: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .devin: return "Devin" }
    }
    func isValidSessionID(_ value: String) -> Bool {
        switch self {
        case .claude, .codex: return UUID(uuidString: value) != nil
        case .devin: return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil
        }
    }
}

enum AgentTaskPurpose: String, CaseIterable, Identifiable {
    case status, artifactTitle, gitInsight, wrappedPersona, weeklyProgress
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .status: return "Session summaries"
        case .artifactTitle: return "Artifact titles"
        case .gitInsight: return "Git insights"
        case .wrappedPersona: return "Wrapped finale"
        case .weeklyProgress: return "Weekly progress"
        }
    }
    var defaultProvider: AgentProvider {
        switch self { case .gitInsight, .wrappedPersona: return .claude; default: return .codex }
    }
    var preferenceKey: String { "ut.agentProvider." + rawValue }
    var needsConversation: Bool { self == .status || self == .weeklyProgress }
    var writesWorkspace: Bool { self == .weeklyProgress }
    var supportedProviders: [AgentProvider] {
        // Workspace generation requires an OS-contained unattended executor.
        // Text-only tasks are supported by every registered CLI adapter.
        writesWorkspace ? [.codex, .devin] : AgentProvider.allCases
    }
    func selectedProvider(defaults: UserDefaults = .standard) -> AgentProvider {
        guard let selected = defaults.string(forKey: preferenceKey).flatMap(AgentProvider.init(rawValue:)),
              supportedProviders.contains(selected) else { return defaultProvider }
        return selected
    }
    func model(for provider: AgentProvider) -> String? {
        switch provider {
        case .codex: return self == .weeklyProgress ? CodexModels.weeklyProgress : CodexModels.luna
        case .claude: return self == .gitInsight || self == .weeklyProgress ? "sonnet" : "haiku"
        case .devin: return nil // Use the user's configured Devin model, not a cross-provider alias.
        }
    }
    var reasoningEffort: String { self == .artifactTitle || self == .wrappedPersona ? "medium" : "high" }
}

struct AgentConversation: Codable, Equatable, Sendable {
    let provider: AgentProvider
    let id: String

    init(provider: AgentProvider, id: String) {
        self.provider = provider
        self.id = provider == .devin ? id : id.lowercased()
    }
}
