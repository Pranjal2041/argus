import Foundation

/// Every provider owns its fetching and normalization in its own folder.
/// The UI only knows the shared UsageSource model.
@available(macOS 14.0, *)
protocol UsageIntegration: Sendable {
    var id: IntegrationID { get }
    var descriptor: IntegrationDescriptor? { get }
    func fetchSources() async throws -> [UsageSource]
}

@available(macOS 14.0, *)
extension UsageIntegration { var descriptor: IntegrationDescriptor? { nil } }

@available(macOS 14.0, *)
struct IntegrationResult: Sendable {
    var integration: IntegrationID
    var sources: [UsageSource]
    var error: String?
    var descriptor: IntegrationDescriptor?
    var needsAuthentication = false
    var errorTitle = "Unavailable"
}

@available(macOS 14.0, *)
struct IntegrationRegistry: Sendable {
    let adapters: [any UsageIntegration]
    var origin: SourceOrigin = .demo
    var configuration: IntegrationConfiguration?
    var fetchCoordinator = IntegrationFetchCoordinator()

    static func configured() -> IntegrationRegistry {
        do { return live(try IntegrationConfiguration.load()) }
        catch { return IntegrationRegistry(adapters: [ConfigurationFailure()], origin: .live) }
    }

    static func live(_ configuration: IntegrationConfiguration, client: any HTTPClient = URLSessionHTTPClient(), runner: any CommandRunning = CommandRunner()) -> IntegrationRegistry {
        let executables = configuration.executables
        let adapters: [any UsageIntegration] = configuration.sources.filter(\.enabled).map { source in
            switch source.integration {
            case .daytona: return LiveDaytonaIntegration(configuration: source, client: client)
            case .modal: return LiveModalIntegration(configuration: source, executable: executables.uvx, runner: runner)
            case .openaiAPI: return LiveOpenAIIntegration(configuration: source, client: client)
            case .codex: return LiveCodexIntegration(configuration: source, executable: executables.codex)
            case .claude: return LiveClaudeIntegration(configuration: source, client: client)
            case .devin: return LiveDevinIntegration(configuration: source, executable: executables.devin, runner: runner, client: client)
            case .macStorage: return LiveMacStorageIntegration(configuration: source)
            case .windowsStorage: return LiveWindowsStorageIntegration(configuration: source, executable: executables.ut, runner: runner)
            }
        }
        return IntegrationRegistry(adapters: adapters, origin: .live, configuration: configuration)
    }

    static let demo = IntegrationRegistry(adapters: [
        DaytonaIntegration(), ModalIntegration(), OpenAIIntegration(),
        CodexIntegration(), ClaudeIntegration(), DevinIntegration(), MacStorageIntegration(), WindowsStorageIntegration(),
    ])

    func fetchAll(onResult: @escaping @Sendable (IntegrationResult) async -> Void = { _ in }) async -> [IntegrationResult] {
        await withTaskGroup(of: IntegrationResult.self) { group in
            for adapter in adapters {
                group.addTask {
                    await fetchCoordinator.fetch(adapter)
                }
            }
            var results: [IntegrationResult] = []
            for await result in group {
                results.append(result)
                await onResult(result)
            }
            return results.sorted { a, b in
                let left = IntegrationID.allCases.firstIndex(of: a.integration)!
                let right = IntegrationID.allCases.firstIndex(of: b.integration)!
                return left == right ? (a.descriptor?.sourceID ?? "") < (b.descriptor?.sourceID ?? "") : left < right
            }
        }
    }
}

@available(macOS 14.0, *)
private struct ConfigurationFailure: UsageIntegration {
    let id = IntegrationID.macStorage
    var descriptor: IntegrationDescriptor? { IntegrationDescriptor(sourceID: "configuration", integration: id, label: "Configuration") }
    func fetchSources() async throws -> [UsageSource] {
        throw IntegrationError.configuration("The integration configuration could not be loaded. Fix integrations.json and reload Connections.")
    }
}

@available(macOS 14.0, *)
enum DemoData {
    static let scenarioTime = Date.now
    static func ago(_ minutes: Double) -> Date { scenarioTime.addingTimeInterval(-minutes * 60) }
    static func later(_ hours: Double) -> Date { scenarioTime.addingTimeInterval(hours * 3600) }
    static func response(_ sources: [UsageSource]) async throws -> [UsageSource] {
        try await Task.sleep(for: .milliseconds(280))
        return sources
    }
}
