@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class CompactSummaryTests: XCTestCase {
    private func source(_ id: String, _ integration: IntegrationID, _ payload: UsagePayload, stale: Bool = false) -> UsageSource {
        UsageSource(id: id, integration: integration, account: id, observedAt: .now, payload: payload, isStale: stale)
    }
    private func compute(spent: Double?, count: Int = 0) -> ComputeUsage {
        ComputeUsage(resources: (0..<count).map { ComputeResource(id: "\($0)", name: "Sandbox", state: .running, kind: "Sandbox") },
                     spent: spent, dailySpend: [])
    }

    func testEveryProviderKeepsItsOwnLabeledSpendAndDeduplicatesSourceIDs() {
        let daytona = source("daytona", .daytona, .compute(compute(spent: 1667.28)))
        let modal = source("modal", .modal, .compute(compute(spent: 10)))
        let openai = source("openai", .openaiAPI, .spend(SpendUsage(spent: 7.20, today: 1, dailySpend: [], breakdown: [])))
        let summary = CompactSummary(sources: [daytona, modal, openai, daytona])
        let readings = summary.providerReadings
        XCTAssertEqual(readings.map(\.id), ["daytona", "modal", "openai"])
        XCTAssertEqual(readings.map(\.integration), [.daytona, .modal, .openaiAPI])
        XCTAssertEqual(readings.map(\.account), ["daytona", "modal", "openai"])
        XCTAssertEqual(readings.map(\.spentUSD), [1667.28, 10, 7.20])
        XCTAssertNil(readings.last?.runningCount)
        XCTAssertNil(readings.last?.resourceNoun)
    }

    func testMissingCachedAndInvalidSpendAreNotZeroButRealZeroIsShown() {
        let missing = source("missing", .daytona, .compute(compute(spent: nil)))
        let cached = source("cached", .modal, .compute(compute(spent: 12)), stale: true)
        let invalid = source("invalid", .modal, .compute(compute(spent: .infinity)))
        let empty = CompactSummary(sources: [missing, cached, invalid])
        XCTAssertEqual(empty.providerReadings.map(\.id), ["missing", "invalid"])
        XCTAssertTrue(empty.providerReadings.allSatisfy { $0.spentUSD == nil })
        XCTAssertEqual(CompactSummary(sources: [source("zero", .modal, .compute(compute(spent: 0)))]).providerReadings.first?.spentUSD, 0)
    }

    func testRunningSandboxesAreSeparateFromModalContainersAndExcludeCached() {
        let sources = [source("d1", .daytona, .compute(compute(spent: nil, count: 2))),
                       source("d2", .daytona, .compute(compute(spent: nil, count: 1))),
                       source("cached", .daytona, .compute(compute(spent: nil, count: 9)), stale: true),
                       source("modal", .modal, .compute(compute(spent: nil, count: 4)))]
        let summary = CompactSummary(sources: sources)
        XCTAssertEqual(summary.providerReadings.map(\.runningCount), [2, 1, 4])
        XCTAssertEqual(summary.providerReadings.map(\.resourceNoun), ["sandboxes", "sandboxes", "containers"])
        XCTAssertTrue(CompactSummary(sources: []).providerReadings.isEmpty)
        XCTAssertEqual(CompactSummary(sources: [source("zero", .daytona, .compute(compute(spent: nil)))]).providerReadings.first?.runningCount, 0)
    }

    func testModalWorkspacesRemainSeparateWithTheirOwnSpendAndRunningCount() {
        let summary = CompactSummary(sources: [
            source("Fable", .modal, .compute(compute(spent: 2470, count: 3))),
            source("B300", .modal, .compute(compute(spent: 279, count: 0)))
        ])
        XCTAssertEqual(summary.providerReadings.map(\.account), ["Fable", "B300"])
        XCTAssertEqual(summary.providerReadings.map(\.spentUSD), [2470, 279])
        XCTAssertEqual(summary.providerReadings.map(\.runningCount), [3, 0])
    }

    func testCompactCodexUsesMainWeeklyRemainingNotMostUsedOrSecondaryWindows() {
        let quota = QuotaUsage(windows: [QuotaWindow(label: "5-hour", usedPercent: 100, durationMinutes: 300),
                                         QuotaWindow(label: "Weekly", usedPercent: 20, durationMinutes: 10080)],
                               additionalBuckets: [QuotaBucket(id: "spark", name: "Spark", windows: [QuotaWindow(label: "Weekly", usedPercent: 100, durationMinutes: 10080)])])
        let summary = CompactSummary(sources: [source("one", .codex, .quota(quota)), source("two", .codex, .quota(quota), stale: true)])
        XCTAssertEqual(summary.weeklyQuota?.remainingPercent, 80)
        XCTAssertEqual(summary.weeklyQuota?.accountCount, 1)
        XCTAssertEqual(summary.weeklyQuota?.totalAccounts, 2)
        XCTAssertEqual(summary.codexAccounts.count, 1)
    }

    func testDeviceDrivesStaySeparateAreNotDuplicatedAndOfflineReadingsRetained() {
        let c = StorageDrive(id: "C", name: "C", usedGB: 100, capacityGB: 500, breakdown: [], historyGB: [])
        let d = StorageDrive(id: "D", name: "D", usedGB: 200, capacityGB: 1000, breakdown: [], historyGB: [])
        let storage = StorageUsage(online: false, drives: [c, d, c])
        let drives = CompactSummary.storageDrives(storage)
        XCTAssertEqual(drives.map(\.id), ["C", "D"])
        XCTAssertEqual(drives.map(\.capacityGB), [500, 1000])
        XCTAssertEqual(drives.map(\.freeGB), [400, 800])
        let device = source("pc", .windowsStorage, .storage(storage), stale: true)
        let empty = source("empty", .macStorage, .storage(StorageUsage(online: true, drives: [])))
        XCTAssertEqual(CompactSummary(sources: [device, empty]).devices.map(\.id), ["pc"])
    }

    func testClaudeWeeklySummaryKeepsTenAccountsInOrderAndSeparateFromCodex() throws {
        let accounts = (0..<10).map { index in
            source("claude-\(index)", .claude, .quota(QuotaUsage(windows: [
                QuotaWindow(label: "5-hour", usedPercent: 100, durationMinutes: 300),
                QuotaWindow(label: "Weekly", usedPercent: Double(index * 10), durationMinutes: 10080),
            ], additionalBuckets: [QuotaBucket(id: "sonnet", name: "Sonnet", windows: [
                QuotaWindow(label: "Weekly", usedPercent: 100, durationMinutes: 10080),
            ])])))
        }
        let codex = source("codex", .codex, .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 1, durationMinutes: 10080)])))
        let summary = CompactSummary(sources: accounts + [codex, accounts[0]])
        XCTAssertEqual(summary.claudeAccounts.map(\.id), accounts.map(\.id))
        let aggregate = try XCTUnwrap(summary.claudeWeeklyQuota)
        XCTAssertEqual(aggregate.remainingPercent, 55)
        XCTAssertEqual(aggregate.accountCount, 10)
        XCTAssertEqual(aggregate.totalAccounts, 10)
        XCTAssertEqual(summary.weeklyQuota?.remainingPercent, 99)
    }

    func testClaudeKeepsCachedAndMissingAccountsVisibleWithoutAveragingThem() throws {
        let quota = QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 40, durationMinutes: 10080)])
        let live = source("live", .claude, .quota(quota))
        let cached = source("cached", .claude, .quota(quota), stale: true)
        let missing = source("missing", .claude, .quota(QuotaUsage(windows: [QuotaWindow(label: "5-hour", usedPercent: 0, durationMinutes: 300)])))
        let summary = CompactSummary(sources: [live, cached, missing])
        XCTAssertEqual(summary.claudeAccounts.map(\.id), ["live", "cached", "missing"])
        XCTAssertEqual(summary.claudeWeeklyQuota?.remainingPercent, 60)
        XCTAssertEqual(summary.claudeWeeklyQuota?.accountCount, 1)
        XCTAssertEqual(summary.claudeWeeklyQuota?.totalAccounts, 3)
        XCTAssertNil(CompactSummary(sources: [cached, missing]).claudeWeeklyQuota)
        XCTAssertNil(CompactSummary(sources: []).claudeWeeklyQuota)
    }
}
