import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageAlertsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_900_000)
    func source(_ provider: IntegrationID = .codex, remaining: Double = 8, reset: Date? = nil) -> UsageSource {
        UsageSource(id: provider.rawValue, integration: provider, account: "Work", observedAt: now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 100 - remaining,
                resetsAt: reset, durationMinutes: 10080)])), origin: .live)
    }
    func readings(_ sources: [UsageSource], models: Bool = false) -> [UsageMeasurement] {
        UsageMeasurement.readings(sources, now: now, maxAge: 300, includeModelLimits: models)
    }

    func testAllAgentProvidersUseTheSameThresholdAndRemainSeparate() {
        var engine = UsageAlertEngine()
        let sources = [source(.codex), source(.claude), source(.devin)]
        let warnings = engine.evaluate(readings(sources), policy: .init(), now: now)
        XCTAssertEqual(warnings.count, 3)
        XCTAssertEqual(Set(warnings.map(\.sourceID)), Set(sources.map(\.id)))
        var policy = UsageAlertPolicy(); policy.quotaRemaining = 5
        XCTAssertTrue(engine.evaluate(readings(sources), policy: policy, now: now).isEmpty)
        policy.quotaRemaining = 10; policy.mutedSources = ["devin"]
        XCTAssertEqual(engine.evaluate(readings(sources), policy: policy, now: now).count, 2)
        policy.enabled = false
        XCTAssertTrue(engine.evaluate(readings(sources), policy: policy, now: now).isEmpty)
    }

    func testDismissalSurvivesRefreshRelaunchAndMissingReadingsButRearmsAtReset() throws {
        var engine = UsageAlertEngine()
        let reset = now.addingTimeInterval(600)
        let metrics = readings([source(reset: reset)])
        let warning = try XCTUnwrap(engine.evaluate(metrics, policy: .init(), now: now).first)
        engine.dismiss(warning)
        let saved = try JSONEncoder().encode(engine.dismissals)
        engine = UsageAlertEngine(dismissals: try JSONDecoder().decode([String: UsageAlertEngine.Dismissal].self, from: saved))
        XCTAssertTrue(engine.evaluate(metrics, policy: .init(), now: now).isEmpty)
        XCTAssertTrue(engine.evaluate([], policy: .init(), now: now).isEmpty)
        XCTAssertTrue(engine.evaluate(metrics, policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.evaluate(readings([source(reset: reset.addingTimeInterval(604800))]), policy: .init(), now: now).count, 1)
    }

    func testSnoozeExpiresAndCriticalEscalationBreaksDismissal() throws {
        var engine = UsageAlertEngine()
        let metrics = readings([source()])
        let warning = try XCTUnwrap(engine.evaluate(metrics, policy: .init(), now: now).first)
        engine.dismiss(warning, until: now.addingTimeInterval(60))
        XCTAssertTrue(engine.evaluate(metrics, policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.evaluate(metrics, policy: .init(), now: now.addingTimeInterval(61)).count, 1)
        engine.dismiss(warning)
        let critical = engine.evaluate(readings([source(remaining: 0)]), policy: .init(), now: now)
        XCTAssertEqual(critical.count, 1); XCTAssertTrue(critical[0].critical)
        engine.dismiss(critical[0])
        XCTAssertTrue(engine.evaluate(readings([source(remaining: 0)]), policy: .init(), now: now).isEmpty)
    }

    func testFreshRecoveryRearmsButStaleExpiredOrUnknownDataDoesNot() throws {
        var engine = UsageAlertEngine()
        engine.dismiss(try XCTUnwrap(engine.evaluate(readings([source()]), policy: .init(), now: now).first))
        var stale = source(remaining: 100); stale.isStale = true
        XCTAssertTrue(readings([stale]).isEmpty)
        _ = engine.evaluate(readings([stale]), policy: .init(), now: now)
        XCTAssertTrue(engine.evaluate(readings([source()]), policy: .init(), now: now).isEmpty)
        _ = engine.evaluate(readings([source(remaining: 100)]), policy: .init(), now: now)
        XCTAssertEqual(engine.evaluate(readings([source()]), policy: .init(), now: now).count, 1)
        var old = source(); old.observedAt = now.addingTimeInterval(-301)
        XCTAssertTrue(readings([old, source(reset: now.addingTimeInterval(-1)), source(remaining: .nan)]).isEmpty)
    }

    func testSecondaryModelWindowsAreOptInAndHaveIndependentKeys() {
        var item = source(remaining: 100)
        var quota = item.quota!
        quota.additionalBuckets = [QuotaBucket(id: "model-a", name: "Model A", windows: [QuotaWindow(label: "Weekly", usedPercent: 99, durationMinutes: 10080)])]
        item.payload = .quota(quota)
        var engine = UsageAlertEngine()
        XCTAssertTrue(engine.evaluate(readings([item]), policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.evaluate(readings([item], models: true), policy: .init(), now: now).count, 1)
        XCTAssertNotEqual(readings([item], models: true)[0].id, readings([item], models: true)[1].id)
    }

    func testComputeAndAPIBudgetsUseTheSameContractAndDrivesStaySeparate() {
        let compute = UsageSource(id: "compute", integration: .modal, account: "Compute", observedAt: now,
            payload: .compute(ComputeUsage(resources: [], spent: 95, budget: 100, dailySpend: [])))
        let api = UsageSource(id: "api", integration: .openaiAPI, account: "API", observedAt: now,
            payload: .spend(SpendUsage(spent: 95, budget: 100, today: 0, dailySpend: [], breakdown: [])))
        let device = UsageSource(id: "device", integration: .windowsStorage, account: "PC", observedAt: now,
            payload: .storage(StorageUsage(online: true, drives: [
                StorageDrive(id: "c", name: "C", usedGB: 950, capacityGB: 1000, breakdown: [], historyGB: []),
                StorageDrive(id: "d", name: "D", usedGB: 1, capacityGB: 1000, breakdown: [], historyGB: [])])))
        var engine = UsageAlertEngine()
        var policy = UsageAlertPolicy(); policy.budgetRemaining = 5
        let warnings = engine.evaluate(readings([compute, api, device]), policy: policy, now: now)
        XCTAssertEqual(warnings.count, 3)
        XCTAssertEqual(warnings.first { $0.sourceID == "device" }?.driveID, "c")
        XCTAssertEqual(warnings.filter { $0.sourceID != "device" }.map(\.remaining), [5.000000000000004, 5.000000000000004])
    }

    @MainActor
    func testControllerPersistsSettingsAndDismissalWithoutPollingOrMixingProviders() async throws {
        let name = "argus.usage.tests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageStore(defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        await controller.refresh()
        XCTAssertEqual(controller.glances.filter { $0.id.hasPrefix("quota-") }.count, 3)
        XCTAssertTrue(controller.glances.first { $0.id == "quota-codex" }?.detail.hasPrefix("Weekly") == true)
        let warning = try XCTUnwrap(controller.warnings.first)
        controller.dismiss(warning)
        controller.policy.storageRemaining = 15
        let restored = UsageController(store: store, defaults: defaults)
        XCTAssertFalse(restored.warnings.contains { $0.id == warning.id })
        XCTAssertEqual(restored.policy.storageRemaining, 15)
        restored.restoreDismissed()
        XCTAssertTrue(restored.warnings.contains { $0.id == warning.id })
    }

    func testPriorMonthBudgetIsNotAssignedToANewBillingCycle() {
        let month = UsageCalendar.monthStart(now)
        let source = UsageSource(id: "budget", integration: .openaiAPI, account: "API", observedAt: month.addingTimeInterval(-30),
            payload: .spend(SpendUsage(spent: 99, budget: 100, today: 0, dailySpend: [], breakdown: [])))
        XCTAssertTrue(UsageMeasurement.readings([source], now: month.addingTimeInterval(30), maxAge: 300, includeModelLimits: false).isEmpty)
    }
}
