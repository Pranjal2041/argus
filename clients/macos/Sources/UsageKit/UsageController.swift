import Combine
import SwiftUI

@available(macOS 14.0, *)
@MainActor
public enum UsageBrowser {
    public static var open: @MainActor @Sendable (URL) -> Bool = { _ in false }
}

@available(macOS 14.0, *)
public struct UsageGlance: Identifiable {
    public var id: String
    public var title: String
    public var value: String
    public var detail: String
    public var symbol: String
    public var remaining: Double?
    public var sourceID: String?
}

@available(macOS 14.0, *)
@MainActor
public final class UsageController: ObservableObject {
    let store: UsageStore
    let defaults: UserDefaults
    @Published public private(set) var warnings: [UsageWarning] = []
    @Published public private(set) var glances: [UsageGlance] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var refreshing = false
    @Published public private(set) var connectionIssueCount = 0
    @Published public var showSettings = false
    @Published var policy: UsageAlertPolicy { didSet { savePolicy(); reconcile() } }
    @Published var refreshSeconds: Double {
        didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    var engine: UsageAlertEngine
    private var refreshTask: Task<Void, Never>?
    private static let policyKey = "warningPolicy.v1"
    private static let dismissalKey = "warningDismissals.v1"

    public convenience init(demo: Bool = false) {
        let defaults = UserDefaults(suiteName: demo ? "argus.usage.preview" : "dev.universaltmux.usage")!
        defaults.register(defaults: ["appearance": "system"])
        var importError: String?
        if !demo && !CommandLine.arguments.contains("--usage-config") {
            do {
                _ = try UsageMigration.importIfNeeded(from: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Usage"), to: IntegrationConfiguration.directory)
                var config = try IntegrationConfiguration.load()
                if !config.sources.contains(where: { $0.integration == .devin }),
                   FileManager.default.isExecutableFile(atPath: config.executables.devin),
                   FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devin/credentials.toml").path) {
                    config.sources.append(SourceConfiguration(id: "devin-\(UUID().uuidString.lowercased())", integration: .devin, label: "Devin account"))
                    try config.save()
                }
            } catch { importError = "The existing Usage configuration could not be imported. Its files are unchanged. Check Connections before adding accounts." }
        }
        self.init(store: UsageStore(registry: demo ? .demo : .configured(), defaults: defaults), defaults: defaults)
        if let importError { store.configurationError = importError }
    }

    init(store: UsageStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
        policy = defaults.data(forKey: Self.policyKey).flatMap { try? JSONDecoder().decode(UsageAlertPolicy.self, from: $0) } ?? UsageAlertPolicy()
        engine = UsageAlertEngine(dismissals: defaults.data(forKey: Self.dismissalKey).flatMap {
            try? JSONDecoder().decode([String: UsageAlertEngine.Dismissal].self, from: $0)
        } ?? [:])
        let savedInterval = defaults.double(forKey: "refreshSeconds")
        refreshSeconds = savedInterval > 0 ? min(3600, max(60, savedInterval)) : store.refreshInterval
        store.readingsChanged = { [weak self] in self?.reconcile() }
        reconcile()
    }

    public func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                store.now = .now
                if Date().timeIntervalSince(store.lastRefresh ?? .distantPast) >= refreshSeconds { await refresh() }
                else { reconcile() }
            }
        }
    }

    public func stop() { refreshTask?.cancel(); refreshTask = nil }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await store.refresh()
        reconcile()
    }

    public func open(sourceID: String? = nil) {
        store.page = "Overview"
        store.selectedCategory = nil
        store.selection = sourceID.map { DetailSelection(sourceID: $0) }
    }

    public func openConnections() { store.page = "Connections"; store.selection = nil }
    public func search() { store.showSearch = true }
    public func addConnection() { store.showNewConnection() }

    public func open(_ warning: UsageWarning) {
        open(sourceID: warning.sourceID)
        store.selection = DetailSelection(sourceID: warning.sourceID, driveID: warning.driveID)
    }

    public func dismiss(_ warning: UsageWarning, snooze: Bool = false) {
        engine.dismiss(warning, until: snooze ? Date().addingTimeInterval(max(1, policy.snoozeHours) * 3600) : nil)
        reconcile()
    }

    func restoreDismissed() { engine.dismissals = [:]; reconcile() }

    func reconcile(now: Date = .now) {
        let maxAge = max(300, refreshSeconds * 3)
        let readings = UsageMeasurement.readings(store.sources, now: now, maxAge: maxAge, includeModelLimits: policy.includeModelLimits)
        warnings = engine.evaluate(readings, policy: policy, now: now)
        // An old reading remains inspectable, but must not masquerade as a live
        // aggregate just because the app slept instead of receiving an error.
        let sources = store.sources.map { source in
            var result = source
            if now.timeIntervalSince(source.observedAt) > maxAge { result.isStale = true }
            return result
        }
        glances = Self.summary(sources)
        connectionIssueCount = store.failures.count
        lastRefresh = store.lastRefresh
        if let data = try? JSONEncoder().encode(engine.dismissals) { defaults.set(data, forKey: Self.dismissalKey) }
    }

    private func savePolicy() {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: Self.policyKey) }
    }

    static func summary(_ sources: [UsageSource]) -> [UsageGlance] {
        var rows: [UsageGlance] = []
        for provider in IntegrationID.allCases where sources.contains(where: { $0.integration == provider && $0.quota != nil }) {
            let readings = QuotaAggregate.mainReadings(sources: sources, integration: provider)
            if let quota = readings.first(where: { $0.durationMinutes == 10080 || ($0.durationMinutes == nil && $0.label.lowercased() == "weekly") }) ?? readings.first {
                rows.append(UsageGlance(id: "quota-" + provider.rawValue, title: provider.name,
                    value: UsageFormat.percent(quota.remainingPercent), detail: "\(quota.label) left · \(quota.accountCount)/\(quota.totalAccounts) accounts · average",
                    symbol: provider.symbol, remaining: quota.remainingPercent))
            } else {
                rows.append(UsageGlance(id: "quota-" + provider.rawValue, title: provider.name,
                    value: "Cached", detail: "Open Usage for account readings", symbol: provider.symbol))
            }
        }
        let summary = CompactSummary(sources: sources)
        for row in summary.providerReadings {
            rows.append(UsageGlance(id: row.id, title: "\(row.integration.name) · \(row.account)",
                value: row.spentUSD.map { UsageFormat.money($0) } ?? "\(row.runningCount ?? 0) running",
                detail: row.runningCount.map { "\($0) \(row.resourceNoun ?? "resources") · month to date" } ?? "Month to date",
                symbol: row.integration.symbol, sourceID: row.id))
        }
        for source in summary.devices {
            for drive in source.storage.map(CompactSummary.storageDrives) ?? [] {
                rows.append(UsageGlance(id: UsageMeasurement.identity([source.id, drive.id]), title: source.account,
                    value: UsageFormat.storage(drive.freeGB) + " free", detail: drive.name + (source.isStale ? " · cached" : ""),
                    symbol: "externaldrive", sourceID: source.id))
            }
        }
        return rows
    }
}
