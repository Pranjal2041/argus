import Foundation
import Observation

@available(macOS 14.0, *)
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .light: "sun.max"; case .dark: "moon"; case .system: "circle.lefthalf.filled" }
    }
}

@MainActor
@available(macOS 14.0, *)
enum AppPreferences {
    static let isUITesting = CommandLine.arguments.contains("--ui-testing")
    static let useDemoData = CommandLine.arguments.contains("--demo")
        || (isUITesting && !CommandLine.arguments.contains("--live"))
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
    static let defaults: UserDefaults = {
        if isUITesting {
            let name = "com.pranjal.usage.uitests"
            let value = UserDefaults(suiteName: name)!
            if CommandLine.arguments.contains("--reset-preferences") { value.removePersistentDomain(forName: name) }
            return value
        }
        return .standard
    }()
}

@available(macOS 14.0, *)
struct SearchResult: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var integration: IntegrationID
    var selection: DetailSelection
}

@available(macOS 14.0, *)
enum DashboardLogic {
    static func attention(in sources: [UsageSource]) -> [AttentionItem] {
        sources.flatMap { source -> [AttentionItem] in
            if let quota = source.quota {
                guard let window = quota.allWindows.max(by: { $0.usedPercent < $1.usedPercent }), window.usedPercent >= 90 else { return [] }
                return [AttentionItem(id: source.id, title: "\(source.name) \(source.account)", detail: "\(UsageFormat.percent(window.remainingPercent)) \(window.label.lowercased()) remaining", selection: DetailSelection(sourceID: source.id), category: source.category)]
            }
            if let storage = source.storage {
                return storage.drives.filter { $0.usedPercent >= 90 }.map { drive in
                    AttentionItem(id: source.id + drive.id, title: "\(source.account) · \(drive.name.components(separatedBy: " · ").first ?? drive.name)", detail: "\(UsageFormat.storage(drive.freeGB)) free", selection: DetailSelection(sourceID: source.id, driveID: drive.id), category: source.category)
                }
            }
            if let spend = source.spend, let budget = spend.budget, budget > 0, spend.spent / budget >= 0.9 {
                return [AttentionItem(id: source.id, title: "\(source.name) \(source.account)", detail: "\(UsageFormat.percent(spend.spent / budget * 100)) of budget", selection: DetailSelection(sourceID: source.id), category: source.category)]
            }
            return []
        }
    }

    static func search(_ query: String, in sources: [UsageSource]) -> [SearchResult] {
        let rows = sources.flatMap { source -> [SearchResult] in
            let account = SearchResult(id: source.id, title: source.storage == nil ? "\(source.name) · \(source.account)" : source.account, subtitle: source.integration.detail, integration: source.integration, selection: DetailSelection(sourceID: source.id))
            let drives = source.storage?.drives.map { drive in
                SearchResult(id: source.id + drive.id, title: "\(source.account) · \(drive.name)", subtitle: "\(UsageFormat.storage(drive.freeGB)) free of \(UsageFormat.storage(drive.capacityGB))", integration: source.integration, selection: DetailSelection(sourceID: source.id, driveID: drive.id))
            } ?? []
            return [account] + drives
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? rows : rows.filter { ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(term) }
    }
}

@MainActor @Observable
@available(macOS 14.0, *)
final class UsageStore {
    var sources: [UsageSource] = []
    var failures: [IntegrationResult] = []
    var refreshing = false
    var didLoad = false
    var now = Date.now
    var lastRefresh: Date?
    var readingsChanged: (() -> Void)?
    var selectedCategory: SourceCategory?
    var selection: DetailSelection?
    var page = "Overview"
    var showSearch = false
    var showAddSource = false
    var events: [ActivityEvent] = []
    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    private(set) var addedSources: [AddedSource]
    private let defaults: UserDefaults
    private var registry: IntegrationRegistry
    private let cache: SnapshotCache?
    private let connections: ConnectionRepository
    var connectionDraft: ConnectionDraft?
    var connectionSaveError: String?
    var savingConnection = false
    var authorizingCredentialID: String?
    var configurationError: String?
    var loginMessage: String?
    var loginInstructions: CodexLoginInstructions?
    var loginMethod: CodexLoginMethod = .browser
    var loginSourceID: String?
    var claudeLoginFlow: ClaudeLoginFlow?
    var claudeAuthorizationCode = ""
    private var claudeOriginalReference: String?
    private var loginTask: Task<Void, Never>?

    init(registry: IntegrationRegistry = .demo, defaults: UserDefaults = AppPreferences.defaults, cache: SnapshotCache? = nil, connections: ConnectionRepository = .init()) {
        self.registry = registry
        self.defaults = defaults
        self.connections = connections
        let defaultCache = AppPreferences.isUITesting
            ? SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-ui-\(UUID()).json"))
            : SnapshotCache()
        self.cache = registry.origin == .live ? (cache ?? defaultCache) : nil
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        if let data = defaults.data(forKey: "addedSources"), let saved = try? JSONDecoder().decode([AddedSource].self, from: data) {
            addedSources = saved
        } else { addedSources = [] }
        events = registry.origin == .demo ? [
            ActivityEvent(title: "Research is approaching its weekly limit", detail: "Codex · Research · 8% remaining", date: DemoData.ago(4), symbol: "exclamationmark.triangle", category: .ai, isWarning: true, selection: DetailSelection(sourceID: "codex-research")),
            ActivityEvent(title: "Projects drive is nearly full", detail: "Windows PC · D: · 80 GB available", date: DemoData.ago(18), symbol: "externaldrive", category: .devices, isWarning: true, selection: DetailSelection(sourceID: "windows-pc", driveID: "d-projects")),
            ActivityEvent(title: "Two sandboxes are idle", detail: "Daytona · Personal · $0.07/h combined", date: DemoData.ago(26), symbol: "shippingbox", category: .cloud, selection: DetailSelection(sourceID: "daytona-personal")),
            ActivityEvent(title: "MacBook Pro reported new storage usage", detail: "Macintosh HD · 360 GB available", date: DemoData.ago(42), symbol: "laptopcomputer", category: .devices, selection: DetailSelection(sourceID: "macbook-pro")),
        ] : []
        if registry.origin == .live {
            let allowed = Set(registry.adapters.compactMap { $0.descriptor?.sourceID })
            sources = self.cache?.load().filter { allowed.contains($0.id) } ?? []
        }
    }

    var isDemo: Bool { registry.origin == .demo }
    var configuration: IntegrationConfiguration? { registry.configuration }
    var refreshInterval: Double { max(60, min(3600, configuration?.refreshIntervalSeconds ?? 120)) }

    var filteredSources: [UsageSource] { sources.filter { selectedCategory == nil || $0.category == selectedCategory } }
    var attention: [AttentionItem] { DashboardLogic.attention(in: filteredSources) }
    var selectedSource: UsageSource? { sources.first { $0.id == selection?.sourceID } }
    var filteredEvents: [ActivityEvent] { events.filter { selectedCategory == nil || $0.category == selectedCategory || $0.category == nil } }

    func sources(for integration: IntegrationID) -> [UsageSource] {
        filteredSources.filter { $0.integration == integration }
    }

    func refresh(sourceID: String? = nil) async {
        guard !refreshing, authorizingCredentialID == nil else { return }
        refreshing = true
        defer { refreshing = false }
        let fetching = sourceID.map { id in
            IntegrationRegistry(adapters: registry.adapters.filter { $0.descriptor?.sourceID == id }, origin: registry.origin, configuration: registry.configuration)
        } ?? registry
        let results = await fetching.fetchAll()
        var fresh: [UsageSource] = sourceID == nil ? [] : sources.filter { $0.id != sourceID }
        for result in results {
            if result.error == nil { fresh.append(contentsOf: result.sources) }
            else if let descriptor = result.descriptor {
                if var previous = sources.first(where: { $0.id == descriptor.sourceID && $0.unavailable == nil }) {
                    previous.isStale = true
                    if var storage = previous.storage { storage.online = false; previous.payload = .storage(storage) }
                    fresh.append(previous)
                } else {
                    fresh.append(UsageSource(id: descriptor.sourceID, integration: descriptor.integration, account: descriptor.label,
                                             observedAt: .now, payload: .unavailable(UnavailableUsage(
                                                title: result.errorTitle,
                                                message: result.error ?? "The source is unavailable.", needsAuthentication: result.needsAuthentication)), origin: .live))
                }
            } else { fresh.append(contentsOf: sources.filter { $0.integration == result.integration && !isAdded($0.id) }) }
        }
        for config in isDemo && sourceID == nil ? addedSources : [] {
            if var template = fresh.first(where: { $0.integration == config.integration }) {
                template.id = config.id
                template.account = config.label
                fresh.append(template)
            }
        }
        let order = Dictionary(uniqueKeysWithValues: (configuration?.sources ?? []).enumerated().map { ($0.element.id, $0.offset) })
        sources = isDemo ? fresh : fresh.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        failures = (sourceID == nil ? [] : failures.filter { $0.descriptor?.sourceID != sourceID }) + results.filter { $0.error != nil }
        now = .now
        lastRefresh = now
        if didLoad || !isDemo {
            let refreshed = results.flatMap(\.sources).count
            events.insert(ActivityEvent(title: failures.isEmpty ? "Sources refreshed" : "Some sources need attention", detail: "\(refreshed) \(isDemo ? "demo" : "live") sources updated · \(failures.count) unavailable", date: now, symbol: "arrow.clockwise", isWarning: !failures.isEmpty), at: 0)
        }
        if !isDemo {
            do { try cache?.save(sources) }
            catch { configurationError = "Live data loaded, but the local reading cache could not be saved." }
        }
        events = Array(events.prefix(100))
        didLoad = true
        readingsChanged?()
    }

    func authorizeSavedCredential(_ sourceID: String) async {
        guard !refreshing, authorizingCredentialID == nil,
              let reference = configuration?.sources.first(where: { $0.id == sourceID })?.credentialReference else { return }
        authorizingCredentialID = sourceID
        loginMessage = "Approve Argus in the macOS Keychain dialog. Always Allow enables future background refreshes; no provider key needs replacing."
        do {
            try await Task.detached { try KeychainCredentialStore().authorize(reference: reference) }.value
            authorizingCredentialID = nil
            loginMessage = "Keychain authorization checked. Refreshing this connection…"
            await refresh(sourceID: sourceID)
            loginMessage = failures.contains { $0.descriptor?.sourceID == sourceID }
                ? "The check still needs attention; see this connection's message below."
                : "Saved key authorized. Connection refreshed."
        } catch {
            authorizingCredentialID = nil
            loginMessage = "Keychain authorization was not completed. Your saved key and other connections are unchanged."
        }
    }

    @discardableResult
    func addSource(_ integration: IntegrationID, label: String) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDemo, !name.isEmpty, var template = sources.first(where: { $0.integration == integration }) else { return false }
        let config = AddedSource(id: "\(integration.rawValue)-\(UUID().uuidString.lowercased())", integration: integration, label: name)
        addedSources.append(config)
        saveSources()
        template.id = config.id
        template.account = name
        sources.append(template)
        events.insert(ActivityEvent(title: "\(integration.name) source added", detail: "\(name) · Sample data", date: .now, symbol: "plus.circle", category: integration.category, selection: DetailSelection(sourceID: config.id)), at: 0)
        selectedCategory = nil
        selection = DetailSelection(sourceID: config.id)
        return true
    }

    func removeAddedSource(_ id: String) {
        guard isAdded(id) else { return }
        addedSources.removeAll { $0.id == id }
        sources.removeAll { $0.id == id }
        if selection?.sourceID == id { selection = nil }
        saveSources()
    }

    func isAdded(_ id: String) -> Bool { addedSources.contains { $0.id == id } }
    private func saveSources() {
        if let data = try? JSONEncoder().encode(addedSources) { defaults.set(data, forKey: "addedSources") }
    }

    func reloadConnections(sourceID: String? = nil) async {
        guard !isDemo, !refreshing else { return }
        do {
            registry = .live(try connections.load())
            configurationError = nil
            await refresh(sourceID: sourceID)
        } catch { configurationError = "Couldn't load integrations.json. Check its format and try again." }
    }

    func showNewConnection(_ integration: IntegrationID = .codex) {
        page = "Connections"; selection = nil; connectionSaveError = nil
        connectionDraft = ConnectionDraft(integration: integration)
    }

    func editConnection(_ source: SourceConfiguration) {
        connectionSaveError = nil
        connectionDraft = ConnectionDraft(source: source)
    }

    @discardableResult
    func saveConnection(_ draft: ConnectionDraft) async -> Bool {
        guard !isDemo, !refreshing, !savingConnection, loginSourceID == nil else {
            connectionSaveError = "Wait for the current connection check or sign-in to finish."
            return false
        }
        savingConnection = true; connectionSaveError = nil
        defer { savingConnection = false }
        do {
            let previous = configuration?.sources.first { $0.id == draft.sourceID }
            let saved = try connections.save(draft)
            registry = .live(try connections.load())
            let identityChanged = previous?.credentialReference != saved.credentialReference
                || previous?.credentialFile != saved.credentialFile || previous?.codexHome != saved.codexHome
                || previous?.environment != saved.environment || previous?.host != saved.host
                || previous?.mountPaths != saved.mountPaths
            if identityChanged || !saved.enabled { sources.removeAll { $0.id == saved.id } }
            else if let index = sources.firstIndex(where: { $0.id == saved.id }) { sources[index].account = saved.label }
            failures.removeAll { $0.descriptor?.sourceID == saved.id }
            do { try cache?.save(sources) }
            catch { configurationError = "Connection saved, but its local reading cache could not be updated." }
            connectionDraft = nil
            if draft.startsCodexLogin { connectCodex(saved.id, method: draft.codexLoginMethod) }
            else if draft.startsClaudeLogin { connectClaude(saved.id) }
            else if saved.enabled { await refresh(sourceID: saved.id) }
            return true
        } catch {
            connectionSaveError = (error as? IntegrationError)?.errorDescription ?? "Couldn't save the connection. Check the fields and try again."
            return false
        }
    }

    func connectCodex(_ sourceID: String, method: CodexLoginMethod? = nil) {
        guard loginTask == nil, let config = configuration,
              let source = config.sources.first(where: { $0.id == sourceID && $0.integration == .codex }),
              let profile = source.codexHome else { return }
        loginSourceID = sourceID
        let selectedMethod = method ?? loginMethod
        loginInstructions = nil
        loginMessage = "Starting a private Codex sign-in…"
        loginTask = Task {
            defer { loginTask = nil; loginSourceID = nil; loginInstructions = nil }
            do {
                let existingEmails = Set(sources.filter { $0.id != sourceID && $0.integration == .codex }.compactMap(\.accountIdentity))
                let authenticator = CodexAuthenticator(executable: config.executables.codex)
                let login = try await authenticator.signIn(profile: profile, existingEmails: existingEmails, method: selectedMethod) { [weak self] instructions in
                    await MainActor.run {
                        self?.loginInstructions = instructions
                        self?.loginMessage = instructions.userCode != nil
                            ? "Open the authorization link and enter this code to connect \(source.label)."
                            : (instructions.browserOpened ? "Finish signing in to \(source.label) in UT Browser." : "UT Browser couldn't open automatically. Open or copy the sign-in link below.")
                    }
                }
                try CodexAuthenticator.save(login, sourceID: sourceID, originalProfile: profile, to: connections.url)
                loginMessage = "Connected. Refreshing the account's real limits…"
                while refreshing { try await Task.sleep(for: .milliseconds(50)) }
                sources.removeAll { $0.id == sourceID }
                await reloadConnections(sourceID: sourceID)
                loginMessage = "Account connected."
            } catch is CancellationError { loginMessage = "Sign-in cancelled. Existing logins are unchanged." }
            catch { loginMessage = (error as? IntegrationError)?.errorDescription ?? "Sign-in failed. Existing logins are unchanged." }
        }
    }

    func connectClaude(_ sourceID: String) {
        guard loginSourceID == nil, let source = configuration?.sources.first(where: { $0.id == sourceID && $0.integration == .claude }) else { return }
        do {
            let flow = try ClaudeLoginFlow()
            claudeLoginFlow = flow; claudeOriginalReference = source.credentialReference
            claudeAuthorizationCode = ""; loginSourceID = sourceID
            loginInstructions = CodexLoginInstructions(url: flow.url, userCode: nil, browserOpened: false)
            loginMessage = "Sign in to \(source.label) using the link below, then paste the complete authorization code."
        } catch { loginMessage = "Couldn't start Claude sign-in. Try again." }
    }

    func finishClaudeLogin() {
        guard loginTask == nil, let flow = claudeLoginFlow, let sourceID = loginSourceID,
              let source = configuration?.sources.first(where: { $0.id == sourceID && $0.integration == .claude }) else { return }
        let code = claudeAuthorizationCode
        let originalReference = claudeOriginalReference
        claudeAuthorizationCode = ""
        loginMessage = "Verifying this Claude account…"
        loginTask = Task {
            defer {
                loginTask = nil; loginSourceID = nil; loginInstructions = nil
                claudeLoginFlow = nil; claudeOriginalReference = nil
            }
            do {
                let client = URLSessionHTTPClient()
                let tokens = try await flow.exchange(code: code, client: client)
                let identified = try await LiveClaudeIntegration.identify(tokens, client: client)
                let usage = try await LiveClaudeIntegration.get("usage", token: identified["accessToken"] ?? "", client: client)
                _ = try LiveClaudeIntegration.normalize(usage, configuration: source, now: .now)
                try Task.checkCancellation()
                try ClaudeOAuth.save(identified, sourceID: sourceID, originalReference: originalReference, repository: connections)
                while refreshing { try await Task.sleep(for: .milliseconds(50)) }
                sources.removeAll { $0.id == sourceID }
                await reloadConnections(sourceID: sourceID)
                loginMessage = "Claude account connected."
            } catch is CancellationError { loginMessage = "Sign-in cancelled. Existing accounts are unchanged." }
            catch { loginMessage = (error as? IntegrationError)?.errorDescription ?? "Claude sign-in failed. Start a new sign-in and try again." }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        if claudeLoginFlow != nil && loginTask == nil {
            claudeLoginFlow = nil; claudeOriginalReference = nil; claudeAuthorizationCode = ""
            loginSourceID = nil; loginInstructions = nil; loginMessage = "Claude sign-in cancelled."
        }
    }

    func addCodexConnection(label: String) {
        showNewConnection(.codex)
        connectionDraft?.label = label
    }
}
