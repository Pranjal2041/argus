import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class ConsumptionUsageTests: XCTestCase {
    private func source(_ provider: IntegrationID, used: Double = 2331.999656, unit: String = "ACUs") -> UsageSource {
        UsageSource(id: provider.rawValue, integration: provider, account: "Work", observedAt: .now,
            payload: .consumption(ConsumptionUsage(used: used, unit: unit)), origin: .live,
            accountIdentity: "reader@example.test")
    }

    @MainActor
    func testConsumptionIsVisibleAcrossProvidersWithoutQuotaOrWarnings() {
        let sources = [source(.devin), source(.openaiAPI, used: 15.5, unit: "credits")]
        let overview = UsageOverview(sources: sources + sources)
        XCTAssertEqual(overview.readingSources.map(\.id), sources.map(\.id))
        XCTAssertEqual(overview.consumptionSources.count, 2)
        XCTAssertTrue(overview.quotaProviders.isEmpty)
        XCTAssertTrue(overview.statusSources.isEmpty)
        XCTAssertTrue(CompactSummary(sources: sources).statusSources.isEmpty)
        XCTAssertTrue(UsageMeasurement.readings(sources, now: .now, maxAge: 300, includeModelLimits: true).isEmpty)
        let cards = UsageController.summary(sources)
        XCTAssertEqual(cards.map(\.value), ["2,332", "15.5"])
        XCTAssertEqual(cards.map(\.detail), ["ACUs used", "credits used"])
        XCTAssertEqual(cards.map(\.sourceID), sources.map { Optional($0.id) })
        XCTAssertTrue(cards.allSatisfy { $0.remaining == nil })
    }

    @MainActor
    func testZeroIsAMeasurementAndCachedTotalsStayExplicitlyCached() {
        var zero = source(.devin, used: 0)
        XCTAssertEqual(UsageController.summary([zero]).first?.value, "0")
        XCTAssertEqual(zero.connectionStatusTitle, "Connected")
        zero.isStale = true
        XCTAssertEqual(UsageOverview(sources: [zero]).consumptionSources.count, 1)
        XCTAssertTrue(CompactSummary(sources: [zero]).statusSources.isEmpty)
        let card = UsageController.summary([zero]).first
        XCTAssertEqual(card?.value, "0")
        XCTAssertEqual(card?.detail, "ACUs used · Cached")
        for value in [-1.0, .infinity, .nan] {
            let invalid = source(.devin, used: value)
            XCTAssertFalse(invalid.hasOverviewReading)
            XCTAssertEqual(UsageOverview(sources: [invalid]).statusSources.count, 1)
            XCTAssertEqual(UsageController.summary([invalid]).first?.value, "Unavailable")
        }
    }

    func testQuotaAndConsumptionAccountsDoNotDuplicateOrShareCoverage() {
        let consumed = source(.devin)
        let quota = UsageSource(id: "quota", integration: .devin, account: "Self serve", observedAt: .now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 20, durationMinutes: 10080)])))
        let unknown = UsageSource(id: "unknown", integration: .devin, account: "Offline", observedAt: .now,
            payload: .unavailable(UnavailableUsage(title: "Unavailable", message: "No reading")))
        let sources = [consumed, quota, unknown]
        let overview = UsageOverview(sources: sources)
        XCTAssertEqual(overview.quotaAccounts(.devin).map(\.id), ["quota", "unknown"])
        XCTAssertEqual(overview.consumptionSources.map(\.id), [consumed.id])
        XCTAssertTrue(overview.statusSources.isEmpty)
        XCTAssertEqual(QuotaAggregate.mainReadings(sources: sources, integration: .devin).first?.totalAccounts, 2)
        let invalid = source(.devin, used: -1)
        XCTAssertEqual(UsageOverview(sources: [invalid, quota]).statusSources.map(\.id), [invalid.id])
        XCTAssertEqual(CompactSummary(sources: [invalid, quota]).statusSources.map(\.id), [invalid.id])
    }

    func testProviderPeriodDatesRetainTimeZoneAndExclusiveEnd() {
        let period = ConsumptionPeriod(start: JSONValue.string("2026-12-15T00:00:00+09:00").date!,
            end: JSONValue.string("2027-01-15T00:00:00+09:00").date!, timeZoneOffsetSeconds: 9 * 3600)
        XCTAssertEqual(period.label, "Dec 15, 2026 – Jan 14, 2027")
    }

    @MainActor
    func testConsumptionPreservesCardOrderAcrossStatusTransitions() {
        let consumed = source(.devin), other = source(.openaiAPI, used: 25, unit: "credits")
        var unknown = consumed
        unknown.payload = .unavailable(UnavailableUsage(title: "Unavailable", message: "No reading"))
        var order = UsageCardOrder()
        let before = UsageController.summary([unknown, other])
        XCTAssertTrue(order.move(other.id, relativeTo: before[0].id, placement: .before, cards: before))
        let after = UsageController.summary([consumed, other])
        XCTAssertEqual(order.arranged(after).map(\.sourceID), [other.id, consumed.id])
    }

    func testNewConsumptionAndExistingQuotaPayloadsRoundTripTogether() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-consumption-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let consumed = source(.devin)
        let quota = UsageSource(id: "quota", integration: .codex, account: "Personal", observedAt: .now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 20, durationMinutes: 10080)])), origin: .live)
        let cache = SnapshotCache(url: directory.appendingPathComponent("cache.json"))
        try cache.save([consumed, quota])
        let restored = cache.load()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first?.consumption?.used, consumed.consumption?.used)
        XCTAssertEqual(restored.last?.quota?.weeklyWindow?.remainingPercent, 80)
        XCTAssertTrue(restored.allSatisfy(\.isStale))
    }
}
