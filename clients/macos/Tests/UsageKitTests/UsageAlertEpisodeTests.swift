import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageAlertEpisodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_900_000)

    private func normalized(_ provider: IntegrationID, reset: Date, minutes: Int) throws -> UsageSource {
        let configuration = SourceConfiguration(id: provider.rawValue, integration: provider, label: "Work")
        if provider == .claude {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return try LiveClaudeIntegration.normalize(.object([
                minutes == 300 ? "five_hour" : "seven_day": .object([
                    "utilization": .number(98), "resets_at": .string(formatter.string(from: reset))
                ])
            ]), configuration: configuration, now: now)
        }
        return try LiveCodexIntegration.normalize(account: .object([:]), rates: .object([
            "rateLimits": .object(["primary": .object([
                "usedPercent": .number(98), "windowDurationMins": .number(Double(minutes)),
                "resetsAt": .number(reset.timeIntervalSince1970)
            ])])
        ]), configuration: configuration, now: now)
    }

    private func readings(_ sources: [UsageSource]) -> [UsageMeasurement] {
        UsageMeasurement.readings(sources, now: now, maxAge: 300, includeModelLimits: false)
    }

    private func metric(reset: Date?, minutes: Int? = 300, remaining: Double = 2) -> UsageMeasurement {
        let source = UsageSource(id: "account", integration: .codex, account: "Work", observedAt: now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Window", usedPercent: 100 - remaining,
                resetsAt: reset, durationMinutes: minutes)])), origin: .live)
        return readings([source])[0]
    }

    func testResetEstimateJitterDoesNotRearmAcrossProviderAdaptersOrRelaunch() throws {
        let boundary = now.addingTimeInterval(3600)
        for (provider, minutes) in [(IntegrationID.claude, 10080), (.codex, 300)] {
            var engine = UsageAlertEngine()
            let original = try readings([normalized(provider, reset: boundary.addingTimeInterval(-0.289), minutes: minutes)])
            engine.dismiss(try XCTUnwrap(engine.evaluate(original, policy: .init(), now: now).first))
            for offset in [0.072, -0.411, 1.15, -1.35, 29.9, -29.9] {
                let data = try JSONEncoder().encode(engine.dismissals)
                engine = UsageAlertEngine(dismissals: try JSONDecoder().decode([String: UsageAlertEngine.Dismissal].self, from: data))
                let updated = try readings([normalized(provider, reset: boundary.addingTimeInterval(offset), minutes: minutes)])
                XCTAssertTrue(engine.evaluate(updated, policy: .init(), now: now).isEmpty, "\(provider): \(offset)")
                XCTAssertEqual(engine.dismissals.count, 1)
            }
        }
    }

    func testNextPeriodRearmsWithoutSamplingARecovery() throws {
        for (provider, minutes) in [(IntegrationID.claude, 10080), (.codex, 300)] {
            var engine = UsageAlertEngine()
            let reset = now.addingTimeInterval(3600)
            let original = try readings([normalized(provider, reset: reset, minutes: minutes)])
            engine.dismiss(try XCTUnwrap(engine.evaluate(original, policy: .init(), now: now).first))
            let next = try readings([normalized(provider, reset: reset.addingTimeInterval(Double(minutes) * 60 + 0.1), minutes: minutes)])
            XCTAssertEqual(engine.evaluate(next, policy: .init(), now: now).count, 1)
        }
    }

    func testEstimateUpdatesDoNotMoveTheDismissedCycleAnchor() throws {
        var engine = UsageAlertEngine()
        let reset = now.addingTimeInterval(2400)
        let original = metric(reset: reset, minutes: 60)
        engine.dismiss(try XCTUnwrap(engine.evaluate([original], policy: .init(), now: now).first))
        for offset in [10.0, 100, 1000, -100, 500] {
            XCTAssertTrue(engine.evaluate([metric(reset: reset.addingTimeInterval(offset), minutes: 60)], policy: .init(), now: now).isEmpty)
            XCTAssertEqual(engine.dismissals[original.id]?.cycle, original.cycle)
        }
        XCTAssertEqual(engine.evaluate([metric(reset: reset.addingTimeInterval(3600), minutes: 60)], policy: .init(), now: now).count, 1)
    }

    func testMissingResetMetadataPreservesThenAnchorsDismissal() throws {
        var engine = UsageAlertEngine()
        let unknown = metric(reset: nil)
        engine.dismiss(try XCTUnwrap(engine.evaluate([unknown], policy: .init(), now: now).first))
        let reported = metric(reset: now.addingTimeInterval(3600))
        XCTAssertTrue(engine.evaluate([reported], policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.dismissals[unknown.id]?.cycle, reported.cycle)
        XCTAssertTrue(engine.evaluate([unknown], policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.dismissals[unknown.id]?.cycle, reported.cycle)
        let next = metric(reset: now.addingTimeInterval(3600 + 300 * 60))
        XCTAssertEqual(engine.evaluate([next], policy: .init(), now: now).count, 1)
    }

    func testUnknownPeriodRequiresTheRecordedResetBoundaryToPass() throws {
        var engine = UsageAlertEngine()
        let reset = now.addingTimeInterval(300)
        let original = metric(reset: reset, minutes: nil)
        engine.dismiss(try XCTUnwrap(engine.evaluate([original], policy: .init(), now: now).first))
        let adjusted = metric(reset: reset.addingTimeInterval(10), minutes: nil)
        XCTAssertTrue(engine.evaluate([adjusted], policy: .init(), now: now).isEmpty)
        XCTAssertEqual(engine.dismissals[original.id]?.cycle, original.cycle)
        let next = metric(reset: reset.addingTimeInterval(3600), minutes: nil)
        XCTAssertEqual(engine.evaluate([next], policy: .init(), now: reset.addingTimeInterval(1)).count, 1)
    }

    func testJitterPreservesSnoozeExpiryEscalationAndRecovery() throws {
        var engine = UsageAlertEngine()
        let reset = now.addingTimeInterval(3600)
        let original = metric(reset: reset, remaining: 8)
        let warning = try XCTUnwrap(engine.evaluate([original], policy: .init(), now: now).first)
        engine.dismiss(warning, until: now.addingTimeInterval(60))
        let adjusted = metric(reset: reset.addingTimeInterval(0.9), remaining: 8)
        XCTAssertTrue(engine.evaluate([adjusted], policy: .init(), now: now.addingTimeInterval(59)).isEmpty)
        XCTAssertEqual(engine.evaluate([adjusted], policy: .init(), now: now.addingTimeInterval(61)).count, 1)
        engine.dismiss(warning)
        let critical = metric(reset: reset.addingTimeInterval(1.1))
        let escalation = try XCTUnwrap(engine.evaluate([critical], policy: .init(), now: now).first)
        XCTAssertTrue(escalation.critical)
        engine.dismiss(escalation)
        XCTAssertTrue(engine.evaluate([metric(reset: reset.addingTimeInterval(-0.1))], policy: .init(), now: now).isEmpty)
        _ = engine.evaluate([metric(reset: reset, remaining: 100)], policy: .init(), now: now)
        XCTAssertEqual(engine.evaluate([critical], policy: .init(), now: now).count, 1)
    }

    func testBudgetCyclesRemainExactAndIndependentOfQuotaEstimates() throws {
        var engine = UsageAlertEngine()
        var budget = metric(reset: now.addingTimeInterval(3600))
        budget.kind = .budget
        budget.cycle = "month-one"
        engine.dismiss(try XCTUnwrap(engine.evaluate([budget], policy: .init(), now: now).first))
        budget.resetsAt = budget.resetsAt?.addingTimeInterval(0.3)
        XCTAssertTrue(engine.evaluate([budget], policy: .init(), now: now).isEmpty)
        budget.cycle = "month-two"
        XCTAssertEqual(engine.evaluate([budget], policy: .init(), now: now).count, 1)
    }

    @MainActor
    func testControllerPersistsDismissalsAfterEstimateUpdatesAndRelaunch() throws {
        let name = "argus.warning-episode.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageStore(defaults: defaults)
        let reset = now.addingTimeInterval(3600)
        store.sources = try [normalized(.claude, reset: reset.addingTimeInterval(-0.289), minutes: 10080),
                             normalized(.codex, reset: reset.addingTimeInterval(-0.289), minutes: 300)]
        let controller = UsageController(store: store, defaults: defaults)
        controller.reconcile(now: now)
        XCTAssertEqual(controller.warnings.count, 2)
        for warning in controller.warnings { controller.dismiss(warning) }
        store.sources = try [normalized(.claude, reset: reset.addingTimeInterval(0.072), minutes: 10080),
                             normalized(.codex, reset: reset.addingTimeInterval(0.072), minutes: 300)]
        controller.reconcile(now: now)
        XCTAssertTrue(controller.warnings.isEmpty)
        let restored = UsageController(store: store, defaults: defaults)
        restored.reconcile(now: now)
        XCTAssertTrue(restored.warnings.isEmpty)
        XCTAssertEqual(restored.engine.dismissals.count, 2)
    }
}
