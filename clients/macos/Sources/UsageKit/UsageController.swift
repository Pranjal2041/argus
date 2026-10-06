import Combine
import SwiftUI

@available(macOS 14.0, *)
@MainActor
public enum UsageBrowser {
    public static var open: @MainActor @Sendable (URL) -> Bool = { _ in false }
}

@available(macOS 14.0, *)
public struct UsageGlance: Identifiable, Codable {
    public var id: String
    public var title: String
    public var value: String
    public var detail: String
    public var symbol: String
    public var remaining: Double?
    public var sourceID: String?
    var ordering: UsageCardIdentity?
    enum CodingKeys: String, CodingKey { case id, title, value, detail, symbol, remaining, sourceID, ordering }
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
        didSet {
            defaults.set(refreshSeconds, forKey: "refreshSeconds")
            if !applyingSharedState { sharedSettingsChanged?() }
        }
    }
    var engine: UsageAlertEngine
    private var refreshTask: Task<Void, Never>?
    private var cardOrder: UsageCardOrder
    private static let policyKey = "warningPolicy.v1"
    private static let dismissalKey = "warningDismissals.v1"
    private static let cardOrderKey = "commandCenterCardOrder.v1"
    public var sharedSettingsChanged: (() -> Void)?
    public var sharedDismissalsChanged: (() -> Void)?
    public var remoteRefresh: ((String?) async -> Void)? {
        didSet { store.remoteRefresh = remoteRefresh }
    }
    public var remoteAccountRequest: ((Data) async throws -> Data)? {
        didSet {
            store.remoteAccountRequest = remoteAccountRequest.map { request in { value in
                let data = try await request(JSONSerialization.data(withJSONObject: value))
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
                return result
            } }
        }
    }
    public func handleAccountService(_ data: Data) async -> Data {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            return try JSONSerialization.data(withJSONObject: await store.handleAccountService(request))
        } catch { return (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])) ?? Data("{}".utf8) }
    }
    private var applyingSharedState = false
    private var presentationWorkspaceID: String?

    /// Missing publication is not deletion. Retain local readings when this
    /// installation becomes the host, and otherwise restore only this workspace.
    public func bindSharedWorkspace(_ id: String, isLocal: Bool) {
        guard !id.isEmpty, presentationWorkspaceID != id else { return }
        let adoptingLocal = presentationWorkspaceID == nil && isLocal
        presentationWorkspaceID = id
        if !adoptingLocal { clearSharedPresentation() }
        if let cached = defaults.data(forKey: "workspaceSnapshot.v1." + id) {
            try? applySharedSnapshot(cached)
        }
    }

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
        cardOrder = UsageCardOrder(keys: defaults.stringArray(forKey: Self.cardOrderKey) ?? [])
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
        if !applyingSharedState { sharedDismissalsChanged?() }
    }

    func restoreDismissed() { engine.dismissals = [:]; reconcile(); sharedDismissalsChanged?() }

    public var hasCustomCardOrder: Bool { !cardOrder.keys.isEmpty }

    @discardableResult
    public func moveGlance(_ id: String, relativeTo targetID: String, placement: UsageCardPlacement) -> Bool {
        guard cardOrder.move(id, relativeTo: targetID, placement: placement, cards: glances) else { return false }
        defaults.set(cardOrder.keys, forKey: Self.cardOrderKey)
        sharedSettingsChanged?()
        glances = cardOrder.arranged(glances)
        return true
    }

    @discardableResult
    public func moveGlance(_ id: String, by offset: Int) -> Bool {
        guard let index = glances.firstIndex(where: { $0.id == id }), offset != 0,
              glances.indices.contains(index + offset) else { return false }
        return moveGlance(id, relativeTo: glances[index + offset].id, placement: offset < 0 ? .before : .after)
    }

    public func resetCardOrder() {
        cardOrder = UsageCardOrder()
        defaults.removeObject(forKey: Self.cardOrderKey)
        sharedSettingsChanged?()
        reconcile()
    }

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
        glances = cardOrder.arranged(Self.summary(sources))
        connectionIssueCount = store.failures.count
        lastRefresh = store.lastRefresh
        if let data = try? JSONEncoder().encode(engine.dismissals) { defaults.set(data, forKey: Self.dismissalKey) }
    }

    private func savePolicy() {
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: Self.policyKey) }
        if !applyingSharedState { sharedSettingsChanged?() }
    }

    public func collectForWorkspace(sourceID: String? = nil) async {
        store.reloadCollectorConfiguration()
        await store.refresh(sourceID: sourceID)
        reconcile()
    }

    public var collectionInterval: Double { refreshSeconds }

    public func clearSharedPresentation() {
        applyingSharedState = true; defer { applyingSharedState = false }
        store.sources = []; store.failures = []; store.lastRefresh = nil
        store.remoteAccountConfiguration = nil; store.remoteAccountFields = [:]; store.loginSourceID = nil
        store.loginMessage = nil; store.loginInstructions = nil; store.remoteLoginIntegration = nil
        store.connectionDraft = nil; store.claudeAuthorizationCode = ""; store.devinAuthorizationCode = ""
        engine.dismissals = [:]; policy = UsageAlertPolicy(); cardOrder = UsageCardOrder()
        refreshSeconds = 120; reconcile()
    }

    public func sharedSnapshot() throws -> Data {
        try UsageWorkspaceWire.encoder.encode(UsageWorkspaceWire.Snapshot(
            version: 1, observedAt: .now, lastRefresh: store.lastRefresh,
            sources: store.sources, glances: glances, warnings: warnings,
            failures: store.failures.map { .init(integration: $0.integration, sourceID: $0.descriptor?.sourceID,
                                               message: $0.error ?? "Unavailable", needsAuthentication: $0.needsAuthentication,
                                               errorTitle: $0.errorTitle) },
            accounts: store.sources.map { source in
                .init(id: source.id, title: source.name, account: source.account, observedAt: source.observedAt,
                      stale: source.isStale, status: store.connectionStatus(sourceID: source.id).title,
                      notes: source.notes, cards: Self.summary([source]))
            }))
    }

    public func applySharedSnapshot(_ data: Data) throws {
        let snapshot = try UsageWorkspaceWire.decoder.decode(UsageWorkspaceWire.Snapshot.self, from: data)
        guard snapshot.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        store.sources = snapshot.sources; store.lastRefresh = snapshot.lastRefresh
        store.failures = snapshot.failures.map { failure in
            let descriptor = failure.sourceID.map { id in
                IntegrationDescriptor(sourceID: id, integration: failure.integration,
                    label: snapshot.sources.first { $0.id == id }?.account ?? id)
            }
            return .init(integration: failure.integration, sources: [], error: failure.message,
                  descriptor: descriptor, needsAuthentication: failure.needsAuthentication,
                  errorTitle: failure.errorTitle ?? (failure.needsAuthentication ? "Connect account" : "Unavailable"))
        }
        store.now = .now; store.didLoad = true
        reconcile()
        if let id = presentationWorkspaceID { defaults.set(data, forKey: "workspaceSnapshot.v1." + id) }
    }

    public func sharedSettings() throws -> Data {
        try UsageWorkspaceWire.encoder.encode(UsageWorkspaceWire.Settings(policy: policy, refreshSeconds: refreshSeconds, cardOrder: cardOrder.keys))
    }

    public func applySharedSettings(_ data: Data) throws {
        let settings = try UsageWorkspaceWire.decoder.decode(UsageWorkspaceWire.Settings.self, from: data)
        applyingSharedState = true; defer { applyingSharedState = false }
        policy = settings.policy; refreshSeconds = min(3600, max(60, settings.refreshSeconds))
        cardOrder = UsageCardOrder(keys: settings.cardOrder)
        defaults.set(cardOrder.keys, forKey: Self.cardOrderKey); reconcile()
    }

    public func sharedDismissals() throws -> Data { try UsageWorkspaceWire.encoder.encode(engine.dismissals) }
    public func applySharedDismissals(_ data: Data) throws {
        engine.dismissals = try UsageWorkspaceWire.decoder.decode([String: UsageAlertEngine.Dismissal].self, from: data)
        reconcile()
    }

    static func summary(_ sources: [UsageSource]) -> [UsageGlance] {
        var rows: [UsageGlance] = []
        let summary = CompactSummary(sources: sources)
        for source in summary.statusSources {
            rows.append(UsageGlance(id: "status-" + source.id, title: "\(source.name) · \(source.account)",
                value: source.connectionStatusTitle,
                detail: [source.readingStatusTitle, source.accountIdentity].compactMap { $0 }.joined(separator: " · "),
                symbol: source.integration.symbol, sourceID: source.id, ordering: .source(source.id)))
        }
        for source in summary.overview.consumptionSources {
            guard let consumption = source.consumption else { continue }
            rows.append(UsageGlance(id: source.id, title: "\(source.name) · \(source.account)",
                value: consumption.formattedAmount,
                detail: [consumption.usedLabel, consumption.period?.label, source.isStale ? "Cached" : nil].compactMap { $0 }.joined(separator: " · "),
                symbol: source.integration.symbol, sourceID: source.id, ordering: .source(source.id)))
        }
        for provider in summary.overview.quotaProviders {
            let readings = QuotaAggregate.mainReadings(sources: sources, integration: provider)
            if let quota = readings.first(where: { $0.durationMinutes == 10080 || ($0.durationMinutes == nil && $0.label.lowercased() == "weekly") }) ?? readings.first {
                rows.append(UsageGlance(id: "quota-" + provider.rawValue, title: provider.name,
                    value: UsageFormat.percent(quota.remainingPercent), detail: "\(quota.label) left · \(quota.accountCount)/\(quota.totalAccounts) accounts · average",
                    symbol: provider.symbol, remaining: quota.remainingPercent,
                    ordering: .group(sources: summary.overview.quotaAccounts(provider).map(\.id))))
            } else {
                rows.append(UsageGlance(id: "quota-" + provider.rawValue, title: provider.name,
                    value: "Cached", detail: "Open Usage for account readings", symbol: provider.symbol,
                    ordering: .group(sources: summary.overview.quotaAccounts(provider).map(\.id))))
            }
        }
        for row in summary.providerReadings {
            rows.append(UsageGlance(id: row.id, title: "\(row.integration.name) · \(row.account)",
                value: row.spentUSD.map { UsageFormat.money($0) } ?? "\(row.runningCount ?? 0) running",
                detail: row.runningCount.map { "\($0) \(row.resourceNoun ?? "resources") · month to date" } ?? "Month to date",
                symbol: row.integration.symbol, sourceID: row.id, ordering: .source(row.id)))
        }
        for source in summary.devices {
            for drive in source.storage.map(CompactSummary.storageDrives) ?? [] {
                rows.append(UsageGlance(id: UsageMeasurement.identity([source.id, drive.id]), title: source.account,
                    value: UsageFormat.storage(drive.freeGB) + " free", detail: drive.name + (source.isStale ? " · cached" : ""),
                    symbol: "externaldrive", sourceID: source.id, ordering: .drive(sourceID: source.id, driveID: drive.id)))
            }
        }
        return rows
    }
}
