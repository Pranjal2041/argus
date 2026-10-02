import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageOverviewTests: XCTestCase {
    private func unavailable(_ integration: IntegrationID) -> UsageSource {
        UsageSource(id: integration.rawValue, integration: integration, account: "Work", observedAt: .now,
            payload: .unavailable(UnavailableUsage(title: "Unavailable", message: "Usage could not be read.")),
            origin: .live, accountIdentity: "person@example.test")
    }

    func testEveryProviderRemainsVisibleWithoutInventingMeasurements() {
        let sources = IntegrationID.allCases.map(unavailable)
        let overview = UsageOverview(sources: sources + sources)
        XCTAssertEqual(overview.sources.count, sources.count)
        XCTAssertEqual(overview.statusSources.map(\.id), sources.map(\.id))
        XCTAssertTrue(overview.readingSources.isEmpty)
        XCTAssertTrue(overview.quotaProviders.isEmpty)
        XCTAssertEqual(CompactSummary(sources: sources).statusSources.map(\.id), sources.map(\.id))
        XCTAssertTrue(QuotaAggregate.mainReadings(sources: sources).isEmpty)
        XCTAssertTrue(UsageMeasurement.readings(sources, now: .now, maxAge: 300, includeModelLimits: true).isEmpty)
        XCTAssertTrue(sources.allSatisfy { $0.readingStatusTitle == "Usage unavailable" && $0.connectionStatusTitle == "Unavailable" })
    }

    func testMixedQuotaAccountsAppearOnceAndKeepMissingAccountsInCoverage() {
        for provider in [IntegrationID.codex, .claude, .devin] {
            let missing = unavailable(provider)
            let reporting = UsageSource(id: "reporting", integration: provider, account: "Personal", observedAt: .now,
                payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 25, durationMinutes: 10080)])))
            let overview = UsageOverview(sources: [missing, reporting])
            XCTAssertEqual(overview.quotaProviders, [provider])
            XCTAssertEqual(overview.quotaAccounts(provider).map(\.id), [missing.id, reporting.id])
            XCTAssertTrue(overview.statusSources.isEmpty, "The missing account is already in the provider card")
            XCTAssertTrue(CompactSummary(sources: overview.sources).statusSources.isEmpty)
            let aggregate = QuotaAggregate.mainReadings(sources: overview.quotaAccounts(provider), integration: provider).first
            XCTAssertEqual(aggregate?.totalAccounts, 2)
            XCTAssertEqual(aggregate?.accountCount, 1)
            XCTAssertEqual(aggregate?.remainingPercent, 75)
        }
    }

    func testEmptyQuotaAndCachedCloudAccountGetStatusInsteadOfDisappearing() {
        var empty = unavailable(.devin)
        empty.payload = .quota(QuotaUsage(windows: []))
        XCTAssertEqual(UsageOverview(sources: [empty]).statusSources.map(\.id), [empty.id])
        XCTAssertEqual(CompactSummary(sources: [empty]).statusSources.map(\.id), [empty.id])
        var cached = unavailable(.modal)
        cached.payload = .compute(ComputeUsage(resources: [], spent: 12, dailySpend: []))
        cached.isStale = true
        XCTAssertTrue(UsageOverview(sources: [cached]).statusSources.isEmpty, "The full dashboard retains the cached reading")
        XCTAssertEqual(CompactSummary(sources: [cached]).statusSources.map(\.id), [cached.id])
        XCTAssertEqual(cached.readingStatusTitle, "Cached usage")
    }

    func testAuthenticationAndUsageFailuresHaveDifferentStatuses() {
        var source = unavailable(.devin)
        XCTAssertEqual(source.connectionStatusTitle, "Unavailable")
        source.payload = .unavailable(UnavailableUsage(title: "Connect account", message: "Expired login", needsAuthentication: true))
        XCTAssertEqual(source.readingStatusTitle, "Sign-in required")
        XCTAssertEqual(source.connectionStatusTitle, "Sign in")
        source.payload = .unavailable(UnavailableUsage(title: "Setup required", message: "Missing executable"))
        XCTAssertEqual(source.connectionStatusTitle, "Setup required")
    }

    @MainActor
    func testCommandCenterKeepsProviderIdentityAndAccountNavigationWithoutQuota() {
        let sources = [unavailable(.devin), unavailable(.openaiAPI)]
        let glances = UsageController.summary(sources)
        XCTAssertEqual(glances.count, 2)
        XCTAssertEqual(glances.map(\.sourceID), sources.map { Optional($0.id) })
        XCTAssertTrue(glances.allSatisfy { $0.remaining == nil && $0.value == "Unavailable" })
        XCTAssertTrue(glances.allSatisfy { $0.detail.contains("person@example.test") && $0.detail.contains("Usage unavailable") })
    }

    @MainActor
    func testSavedAccountsSurviveNoReadingRefreshAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-overview-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "argus.overview.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sources = [IntegrationID.devin, .openaiAPI].map { provider in
            var source = SourceConfiguration(id: provider.rawValue, integration: provider, label: "Work")
            source.accountIdentity = "person@example.test"
            return source
        }
        let config = IntegrationConfiguration(sources: sources)
        let registry = IntegrationRegistry(adapters: sources.map(NoReadingIntegration.init), origin: .live, configuration: config)
        let cache = SnapshotCache(url: directory.appendingPathComponent("readings.json"))
        let store = UsageStore(registry: registry, defaults: defaults, cache: cache)
        XCTAssertEqual(store.sources.map(\.id), sources.map(\.id))
        XCTAssertTrue(store.sources.allSatisfy { $0.accountIdentity != nil && $0.readingStatusTitle == "Checking usage" })
        await store.refresh()
        XCTAssertEqual(store.sources.map(\.id), sources.map(\.id))
        XCTAssertTrue(store.sources.allSatisfy { $0.accountIdentity != nil && $0.readingStatusTitle == "Usage unavailable" })
        XCTAssertTrue(cache.load().isEmpty, "No successful measurement is fabricated for the reading cache")
        let restored = UsageStore(registry: registry, defaults: defaults, cache: cache)
        XCTAssertEqual(restored.sources.map(\.id), sources.map(\.id))
        XCTAssertEqual(UsageController.summary(restored.sources).count, 2)
    }
}

@available(macOS 14.0, *)
private struct NoReadingIntegration: UsageIntegration {
    let configuration: SourceConfiguration
    var id: IntegrationID { configuration.integration }
    var descriptor: IntegrationDescriptor? { configuration.descriptor }
    func fetchSources() async throws -> [UsageSource] {
        throw IntegrationError.unavailable("Usage could not be read.")
    }
}
