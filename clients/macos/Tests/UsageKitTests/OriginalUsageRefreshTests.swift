import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class OriginalUsageRefreshTests: XCTestCase {
    @MainActor func testSnapshotApplicationAndCachedStartupNeverReenterOrPublishCollectionChanges() throws {
        for age: TimeInterval in [0, 300, 3600] {
            for active in [false, true] {
                for cachedStartup in [false, true] {
                    let suite = "usage.snapshot.lifecycle.\(UUID())", defaults = UserDefaults(suiteName: suite)!
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let observed = Date().addingTimeInterval(-age)
                    let snapshot = UsageWorkspaceWire.Snapshot(version: 1, observedAt: observed,
                        lastRefresh: observed, sources: [Self.reading("account", provider: .claude, date: observed)],
                        glances: [], warnings: [], failures: [], accounts: [], refreshing: active)
                    let data = try UsageWorkspaceWire.encoder.encode(snapshot)
                    let store = UsageStore(defaults: defaults), reader = UsageController(store: store, defaults: defaults)
                    var notifications = 0, publications = 0
                    let changed = store.readingsChanged
                    // Bound a regression so the assertion fails instead of crashing the test process.
                    store.readingsChanged = {
                        notifications += 1
                        if notifications <= 8 { changed?() }
                    }
                    reader.readingsChanged = { publications += 1 }
                    if cachedStartup {
                        defaults.set(data, forKey: "workspaceSnapshot.v1.fixture")
                        reader.bindSharedWorkspace("fixture", isLocal: true)
                    } else {
                        try reader.applySharedSnapshot(data)
                    }
                    XCTAssertEqual(store.sources.map(\.id), ["account"])
                    XCTAssertEqual(reader.refreshing, active && age < 120)
                    XCTAssertEqual(store.isRefreshing, reader.refreshing, "Dashboard and summary use the same projection")
                    XCTAssertFalse(store.refreshing, "A reader never inherits ownership of remote work")
                    reader.reconcile()
                    reader.reconcile(now: Date().addingTimeInterval(180))
                    XCTAssertFalse(store.isRefreshing)
                    XCTAssertFalse(reader.refreshing)
                    reader.clearSharedPresentation()
                    XCTAssertEqual(notifications, 0, "Reading, expiring, or clearing a replica cannot notify collection changes")
                    XCTAssertEqual(publications, 0, "Applying remote state must not echo it to the publisher")
                }
            }
        }
    }

    @MainActor func testRemoteRequestKeepsOwnershipUntilCompletionAndExpiredProgressDoesNotBlockRetry() async throws {
        let suite = "usage.remote.request.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults), reader = UsageController(store: store, defaults: defaults)
        let gate = FetchGate(), started = expectation(description: "remote request started")
        var requests = 0
        reader.remoteRefresh = { _ in
            requests += 1
            started.fulfill()
            await gate.wait()
        }
        let old = UsageWorkspaceWire.Snapshot(version: 1, observedAt: Date().addingTimeInterval(-300),
            lastRefresh: nil, sources: [], glances: [], warnings: [], failures: [], accounts: [], refreshing: true)
        let data = try UsageWorkspaceWire.encoder.encode(old)
        try reader.applySharedSnapshot(data)
        let task = Task { await reader.refresh() }
        await fulfillment(of: [started], timeout: 2)
        try reader.applySharedSnapshot(data)
        XCTAssertTrue(store.refreshing)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertTrue(reader.refreshing)
        await reader.refresh()
        await store.refresh()
        XCTAssertEqual(requests, 1, "Snapshot application cannot allow overlapping remote requests")
        await gate.release()
        await task.value
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(reader.refreshing)
    }

    @MainActor func testProgressNotificationsOnlyDescribeLocalTransitions() {
        let suite = "usage.progress.transitions.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        var transitions: [Bool] = []
        store.readingsChanged = { transitions.append(store.refreshing) }
        store.refreshing = false
        store.refreshing = true
        store.refreshing = true
        store.remoteRefreshExpiresAt = Date().addingTimeInterval(120)
        store.now = Date().addingTimeInterval(180)
        store.remoteRefreshExpiresAt = nil
        store.refreshing = false
        store.refreshing = false
        XCTAssertEqual(transitions, [true, false])
        store.readingsChanged = nil
    }

    @MainActor func testSavedStartupSnapshotsLoadHeadlessly() throws {
        guard ProcessInfo.processInfo.environment["UT_USAGE_SNAPSHOT_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only check of saved startup snapshots; no GUI or provider requests")
        }
        let saved = UserDefaults.standard.persistentDomain(forName: "dev.universaltmux.usage") ?? [:]
        let snapshots = saved.filter { $0.key.hasPrefix("workspaceSnapshot.v1.") && $0.value is Data }
        XCTAssertFalse(snapshots.isEmpty, "The probe must exercise actual saved snapshots")
        for (key, value) in snapshots {
            let data = try XCTUnwrap(value as? Data)
            let snapshot = try UsageWorkspaceWire.decoder.decode(UsageWorkspaceWire.Snapshot.self, from: data)
            let suite = "usage.startup.probe.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(data, forKey: key)
            let store = UsageStore(defaults: defaults), reader = UsageController(store: store, defaults: defaults)
            var publications = 0
            reader.readingsChanged = { publications += 1 }
            reader.bindSharedWorkspace(String(key.dropFirst("workspaceSnapshot.v1.".count)), isLocal: true)
            XCTAssertEqual(store.sources.map(\.id), snapshot.sources.map(\.id))
            XCTAssertFalse(store.refreshing)
            reader.reconcile(now: Date().addingTimeInterval(3600))
            XCTAssertFalse(store.isRefreshing)
            XCTAssertFalse(reader.refreshing)
            XCTAssertEqual(publications, 0)
            try reader.restoreCollectorSnapshot(data)
            XCTAssertFalse(store.isRefreshing)
            XCTAssertEqual(publications, 0)
        }
    }

    @MainActor func testExpiredReplicaCannotEndAnOwnedCollection() async throws {
        for provider in [IntegrationID.openaiAPI, .codex] {
            let suite = "usage.collection.ownership.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = FetchGate(), started = expectation(description: "collector started")
            let adapter = FixtureUsageIntegration(id: provider, sourceID: "account") {
                started.fulfill()
                await gate.wait()
                return [Self.reading("account", provider: provider)]
            }
            let store = UsageStore(registry: .init(adapters: [adapter]), defaults: defaults)
            let controller = UsageController(store: store, defaults: defaults)
            let task = Task { await controller.refresh() }
            await fulfillment(of: [started], timeout: 2)
            var notifications = 0
            let changed = store.readingsChanged
            store.readingsChanged = {
                notifications += 1
                if notifications <= 8 { changed?() }
            }
            let observed = Date().addingTimeInterval(-300)
            let snapshot = UsageWorkspaceWire.Snapshot(version: 1, observedAt: observed,
                lastRefresh: observed, sources: [], glances: [], warnings: [], failures: [], accounts: [], refreshing: true)
            try controller.applySharedSnapshot(UsageWorkspaceWire.encoder.encode(snapshot))
            XCTAssertTrue(store.refreshing, "Only the task owning a collection can end it")
            XCTAssertTrue(controller.refreshing)
            XCTAssertEqual(notifications, 0)
            await gate.release()
            await task.value
            store.readingsChanged = changed
            XCTAssertFalse(controller.refreshing)
            XCTAssertEqual(store.sources.map(\.id), ["account"])
        }
    }

    @MainActor func testCancelledOwnerCannotStartAQueuedCollection() async throws {
        let suite = "usage.cancelled.owner.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = OriginalFetchAttempts()
        let adapter = FixtureUsageIntegration(id: .codex, sourceID: "account") {
            _ = await attempts.next()
            return [Self.reading("account", provider: .codex)]
        }
        let controller = UsageController(store: UsageStore(registry: .init(adapters: [adapter]), defaults: defaults), defaults: defaults)
        let queued = Task {
            try? await Task.sleep(for: .seconds(60))
            await controller.refresh()
        }
        queued.cancel()
        await queued.value
        let count = await attempts.count
        XCTAssertEqual(count, 0)
    }

    @MainActor func testAccountRPCReadsAndFailuresDoNotPollAndEditsRefreshOnlyTheirOwnSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-rpc-cadence-\(UUID())")
        let suite = "usage.rpc.cadence.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localAttempts = OriginalFetchAttempts(), cliAttempts = OriginalFetchAttempts()
        let local = FixtureUsageIntegration(id: .macStorage, sourceID: "local") {
            _ = await localAttempts.next()
            return [Self.reading("local", provider: .macStorage)]
        }
        let cli = FixtureUsageIntegration(id: .codex, sourceID: "cli") {
            _ = await cliAttempts.next()
            return [Self.reading("cli", provider: .codex)]
        }
        var cliSource = SourceConfiguration(id: "cli", integration: .codex, label: "CLI")
        cliSource.codexHome = directory.path
        let source = SourceConfiguration(id: "local", integration: .macStorage, label: "Disk")
        let config = IntegrationConfiguration(sources: [source, cliSource])
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let store = UsageStore(registry: .init(adapters: [local, cli], origin: .live, configuration: config),
            defaults: defaults, cache: .init(url: directory.appendingPathComponent("cache.json")),
            connections: .init(url: url))
        store.makeRegistry = { .init(adapters: [local, cli], origin: .live, configuration: $0) }
        let controller = UsageController(store: store, defaults: defaults)
        await controller.refresh()
        var changes = 0
        controller.readingsChanged = { changes += 1 }
        for index in 0..<20 {
            let request: [String: Any] = index.isMultiple(of: 2) ? [:] : ["action": "state"]
            let result = await controller.handleAccountService(try JSONSerialization.data(withJSONObject: request))
            XCTAssertNil((try JSONSerialization.jsonObject(with: result) as? [String: Any])?["error"])
        }
        XCTAssertEqual(changes, 0, "Read-only state queries must not dirty usage or poll providers")
        let failed = await controller.handleAccountService(Data(#"{"action":"connect","sourceID":"missing"}"#.utf8))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: failed) as? [String: Any])?["error"])
        let beforeLocal = await localAttempts.count, beforeCLI = await cliAttempts.count
        XCTAssertEqual(beforeLocal, 1); XCTAssertEqual(beforeCLI, 1)
        var draft = ConnectionDraft(source: source); draft.label = "Renamed disk"
        let edited = await controller.handleAccountService(try JSONSerialization.data(withJSONObject: ["action": "save", "draft": draft.serviceFields]))
        XCTAssertNil((try JSONSerialization.jsonObject(with: edited) as? [String: Any])?["error"])
        let afterLocal = await localAttempts.count, afterCLI = await cliAttempts.count
        XCTAssertEqual(afterLocal, 2)
        XCTAssertEqual(afterCLI, 1, "Editing one connection cannot repoll every other account")
        XCTAssertGreaterThan(changes, 0)
    }

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
