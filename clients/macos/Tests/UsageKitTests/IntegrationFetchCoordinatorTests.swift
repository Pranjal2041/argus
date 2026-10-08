import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class IntegrationFetchCoordinatorTests: XCTestCase {
    func testResultsStreamBeforeAnUncooperativeAccountTimesOut() async {
        let gate = FetchGate(), delivered = expectation(description: "healthy account arrived")
        let coordinator = IntegrationFetchCoordinator(timeout: 0.2)
        let slow = FixtureUsageIntegration(id: .codex, sourceID: "slow") {
            await gate.wait()
            return [Self.reading("slow", provider: .codex)]
        }
        let fast = FixtureUsageIntegration(id: .claude, sourceID: "fast") { [Self.reading("fast", provider: .claude)] }
        let registry = IntegrationRegistry(adapters: [slow, fast], fetchCoordinator: coordinator)
        let task = Task {
            await registry.fetchAll { result in
                if result.descriptor?.sourceID == "fast" { delivered.fulfill() }
            }
        }
        await fulfillment(of: [delivered], timeout: 1)
        let result = await task.value
        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result.first { $0.descriptor?.sourceID == "fast" }?.error)
        let failure = result.first { $0.descriptor?.sourceID == "slow" }
        XCTAssertEqual(failure?.error, IntegrationError.timeout.errorDescription)
        XCTAssertEqual(failure?.needsAuthentication, false)
        await gate.release()
    }

    func testDeadlineDoesNotStartOverlappingRetriesAndLateResultsDoNotWin() async {
        for provider in [IntegrationID.codex, .openaiAPI] {
            let gate = FetchGate(), coordinator = IntegrationFetchCoordinator(timeout: 0.05)
            let adapter = FixtureUsageIntegration(id: provider, sourceID: "account") {
                await gate.wait()
                return [Self.reading("account", provider: provider)]
            }
            async let first = coordinator.fetch(adapter)
            async let duplicate = coordinator.fetch(adapter)
            let results = await [first, duplicate]
            XCTAssertTrue(results.allSatisfy { $0.error == IntegrationError.timeout.errorDescription })
            for _ in 0..<3 {
                let retry = await coordinator.fetch(adapter)
                XCTAssertEqual(retry.error, IntegrationError.timeout.errorDescription)
            }
            let attempts = await gate.attempts
            XCTAssertEqual(attempts, 1)
            await gate.release()
            // Let the canceled operation acknowledge its exit. Its late success
            // must not change the already-returned timeout into fresh data.
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(results.allSatisfy { $0.sources.isEmpty })
            let recovered = await coordinator.fetch(adapter)
            XCTAssertNil(recovered.error)
            let recoveredAttempts = await gate.attempts
            XCTAssertEqual(recoveredAttempts, 2)
        }
    }

    @MainActor func testStoreAndWorkspaceReadersReceiveHealthyAccountsDuringAStalledRefresh() async throws {
        let suite = "usage.streaming.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = FetchGate(), fresh = expectation(description: "fresh account visible before batch completion")
        let updated = Date(), previous = updated.addingTimeInterval(-3600)
        let adapters: [any UsageIntegration] = [
            FixtureUsageIntegration(id: .claude, sourceID: "healthy") { [Self.reading("healthy", provider: .claude, date: updated)] },
            FixtureUsageIntegration(id: .codex, sourceID: "slow") {
                await gate.wait()
                return [Self.reading("slow", provider: .codex)]
            }
        ]
        let registry = IntegrationRegistry(adapters: adapters, fetchCoordinator: IntegrationFetchCoordinator(timeout: 0.3))
        let store = UsageStore(registry: registry, defaults: defaults)
        store.sources = [Self.reading("healthy", provider: .claude, date: previous), Self.reading("slow", provider: .codex, date: previous)]
        store.lastRefresh = previous
        let controller = UsageController(store: store, defaults: defaults)
        let readerStore = UsageStore(defaults: defaults)
        let reader = UsageController(store: readerStore, defaults: defaults)
        var delivered = false
        controller.readingsChanged = {
            guard !delivered, store.sources.first(where: { $0.id == "healthy" })?.observedAt == updated else { return }
            delivered = true
            XCTAssertTrue(controller.refreshing)
            XCTAssertEqual(store.lastRefresh, previous)
            XCTAssertEqual(store.sources.first { $0.id == "slow" }?.observedAt, previous)
            do { try reader.applySharedSnapshot(controller.sharedSnapshot()) }
            catch { XCTFail("\(error)") }
            XCTAssertTrue(reader.refreshing)
            XCTAssertEqual(readerStore.sources.first { $0.id == "healthy" }?.observedAt.timeIntervalSince1970 ?? 0,
                           updated.timeIntervalSince1970, accuracy: 0.001)
            fresh.fulfill()
        }
        let refresh = Task { await controller.refresh() }
        await fulfillment(of: [fresh], timeout: 2)
        await refresh.value
        XCTAssertFalse(controller.refreshing)
        XCTAssertEqual(store.sources.first { $0.id == "healthy" }?.isStale, false)
        XCTAssertEqual(store.sources.first { $0.id == "slow" }?.isStale, true)
        XCTAssertEqual(store.failures.count, 1)
        XCTAssertFalse(store.failures[0].needsAuthentication)
        try reader.applySharedSnapshot(controller.sharedSnapshot())
        XCTAssertFalse(reader.refreshing)
        await gate.release()
    }

    @MainActor func testCollectorRestoresReadingsWithoutInheritingPreviousOwnersActiveRefresh() throws {
        let suite = "usage.restore.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceStore = UsageStore(defaults: defaults), source = UsageController(store: sourceStore, defaults: defaults)
        let prior = Date().addingTimeInterval(-90)
        sourceStore.sources = [Self.reading("account", provider: .claude, date: prior)]
        sourceStore.lastRefresh = prior
        sourceStore.refreshing = true
        let data = try source.sharedSnapshot()
        let collectorStore = UsageStore(defaults: defaults), collector = UsageController(store: collectorStore, defaults: defaults)
        try collector.restoreCollectorSnapshot(data)
        XCTAssertFalse(collectorStore.refreshing)
        XCTAssertEqual(collectorStore.sources.count, 1)
        XCTAssertEqual(collector.lastRefresh?.timeIntervalSince1970 ?? 0, prior.timeIntervalSince1970, accuracy: 0.001)
        let reader = UsageController(store: UsageStore(defaults: defaults), defaults: defaults)
        try reader.applySharedSnapshot(data)
        XCTAssertTrue(reader.refreshing)
        reader.reconcile(now: Date().addingTimeInterval(180))
        XCTAssertFalse(reader.refreshing, "A lost publisher cannot leave a reader's spinner active forever")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "refreshing")
        try reader.applySharedSnapshot(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(reader.refreshing)
    }

    @MainActor func testReadersUseThePublishedCadenceInsteadOfExpiringBetweenScheduledChecks() throws {
        let suite = "usage.cadence.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults), collector = UsageController(store: store, defaults: defaults)
        let now = Date(), readingTime = now.addingTimeInterval(-8 * 60)
        store.sources = [Self.reading("quota", provider: .claude, date: readingTime)]
        store.lastRefresh = readingTime
        collector.refreshSeconds = 120
        collector.setCollectionCadence(600)
        collector.reconcile(now: now)
        XCTAssertNotEqual(collector.glances.first?.value, "Cached")
        let reader = UsageController(store: UsageStore(defaults: defaults), defaults: defaults)
        try reader.applySharedSnapshot(collector.sharedSnapshot())
        reader.reconcile(now: now)
        XCTAssertEqual(reader.glances.first?.value, collector.glances.first?.value)
        reader.reconcile(now: readingTime.addingTimeInterval(1801))
        XCTAssertEqual(reader.glances.first?.value, "Cached")
        collector.setCollectionCadence(120)
        try reader.applySharedSnapshot(collector.sharedSnapshot())
        reader.reconcile(now: now)
        XCTAssertEqual(reader.glances.first?.value, "Cached")
    }

    private static func reading(_ id: String, provider: IntegrationID, date: Date = .now) -> UsageSource {
        UsageSource(id: id, integration: provider, account: id, observedAt: date,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 30, resetsAt: nil, durationMinutes: 10080)])), origin: .live)
    }
}

@available(macOS 14.0, *)
private struct FixtureUsageIntegration: UsageIntegration {
    let id: IntegrationID
    let sourceID: String
    let fetch: @Sendable () async throws -> [UsageSource]
    var descriptor: IntegrationDescriptor? { .init(sourceID: sourceID, integration: id, label: sourceID) }
    func fetchSources() async throws -> [UsageSource] { try await fetch() }
}

private actor FetchGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var attempts = 0
    func wait() async {
        attempts += 1
        if !open { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() {
        open = true
        let pending = waiting; waiting.removeAll()
        pending.forEach { $0.resume() }
    }
}
