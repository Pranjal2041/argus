import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class OriginalUsageRefreshTests: XCTestCase {
    @MainActor func testRecurringCollectionSurvivesFailureAndStopRestartWithoutAPublisher() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-copy-loop-\(UUID())")
        let suite = "usage.copy.loop.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let attempts = OriginalFetchAttempts()
        let adapter = FixtureUsageIntegration(id: .openaiAPI, sourceID: "account") {
            if await attempts.next() == 1 { throw IntegrationError.unavailable("First check offline") }
            return [Self.reading("account", provider: .openaiAPI)]
        }
        let cache = SnapshotCache(url: directory.appendingPathComponent("readings.json"))
        let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter], origin: .live), defaults: defaults, cache: cache)
        let controller = UsageController(store: store, defaults: defaults)
        controller.refreshSeconds = 0.03 // Test clock only; public settings clamp to >= 60 seconds.
        defer { controller.stop() }
        controller.start(); controller.start()
        try await Task.sleep(for: .milliseconds(160))
        controller.stop()
        // Cancelling the loop lets its already-running provider read finish.
        // Count after that read settles, not while its actor hop is queued.
        for _ in 0..<100 where store.refreshing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.refreshing)
        let completed = await attempts.count
        XCTAssertGreaterThanOrEqual(completed, 3)
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.sources.first).isStale)
        XCTAssertNotNil(cache.load().first)
        try await Task.sleep(for: .milliseconds(80))
        let stopped = await attempts.count
        XCTAssertEqual(stopped, completed)
        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()
        let restarted = await attempts.count
        XCTAssertGreaterThan(restarted, stopped)
    }

    func testEveryRefreshCallsAdaptersAgainAfterFailure() async {
        for provider in [IntegrationID.openaiAPI, .codex] {
            let attempts = OriginalFetchAttempts()
            let adapter = FixtureUsageIntegration(id: provider, sourceID: "account") {
                let attempt = await attempts.next()
                if attempt == 1 { throw IntegrationError.unavailable("Fixture failure") }
                return [Self.reading("account", provider: provider)]
            }
            let registry = IntegrationRegistry(adapters: [adapter], origin: .live)
            let first = await registry.fetchAll()
            XCTAssertNotNil(first.first?.error)
            XCTAssertFalse(first.first?.needsAuthentication == true)
            let next = await registry.fetchAll()
            XCTAssertNil(next.first?.error)
            XCTAssertEqual(next.first?.sources.first?.id, "account")
            let count = await attempts.count
            XCTAssertEqual(count, 2)
        }
    }

    @MainActor func testRefreshPreservesOriginalCacheAndRecoversForHTTPAndCLISources() async throws {
        for provider in [IntegrationID.openaiAPI, .codex] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-copy-cache-\(UUID())")
            let suite = "usage.copy.cache.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            let cache = SnapshotCache(url: directory.appendingPathComponent("readings.json"))
            let originalDate = Date().addingTimeInterval(-3600)
            try cache.save([Self.reading("account", provider: provider, date: originalDate)])
            let attempts = OriginalFetchAttempts()
            let adapter = FixtureUsageIntegration(id: provider, sourceID: "account") {
                if await attempts.next() == 1 { throw IntegrationError.timeout }
                return [Self.reading("account", provider: provider)]
            }
            let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter], origin: .live),
                                   defaults: defaults, cache: cache)
            XCTAssertTrue(try XCTUnwrap(store.sources.first).isStale)
            await store.refresh()
            XCTAssertEqual(store.sources.first?.observedAt.timeIntervalSince1970 ?? 0,
                           originalDate.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertTrue(try XCTUnwrap(store.sources.first).isStale)
            XCTAssertEqual(store.failures.count, 1)
            await store.refresh()
            XCTAssertFalse(try XCTUnwrap(store.sources.first).isStale)
            XCTAssertTrue(store.failures.isEmpty)
            XCTAssertGreaterThan(store.sources.first?.observedAt ?? .distantPast, originalDate)
            XCTAssertEqual(cache.load().first?.observedAt.timeIntervalSince1970 ?? 0,
                           store.sources.first?.observedAt.timeIntervalSince1970 ?? 0, accuracy: 0.001)
        }
    }

    @MainActor func testOverlappingRefreshesUseOriginalStoreSingleFlightGuard() async throws {
        let suite = "usage.copy.single-flight.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = FetchGate()
        let started = expectation(description: "account fetch started")
        let adapter = FixtureUsageIntegration(id: .claude, sourceID: "account") {
            started.fulfill()
            await gate.wait()
            return [Self.reading("account", provider: .claude)]
        }
        let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter]), defaults: defaults)
        let controller = UsageController(store: store, defaults: defaults)
        let active = Task { await controller.refresh() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.refreshing)
        await controller.refresh()
        await store.refresh(sourceID: "account")
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        await gate.release()
        await active.value
        XCTAssertFalse(controller.refreshing)
        XCTAssertEqual(store.sources.count, 1)
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

private actor OriginalFetchAttempts {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}
