import XCTest
@testable import UniversalTmuxMac

final class SessionSummaryQueueTests: XCTestCase {
    func testAdmissionOrderSurvivesCapacityAndCoalescesWithoutLosingPosition() {
        var queue = SessionSummaryQueue<Int>(capacity: 2)
        for n in 0..<12 { queue.enqueue("job-\(n)", work: n, merge: { _, new in new }) }
        XCTAssertEqual(queue.next()?.key, "job-0")
        XCTAssertEqual(queue.next()?.key, "job-1")
        XCTAssertNil(queue.next())
        queue.enqueue("job-2", work: 200, merge: { _, new in new })
        queue.enqueue("job-0", work: 100, merge: { _, new in new })
        XCTAssertEqual(queue.pendingKeys.count, 11)
        queue.finish("job-1")
        let next = queue.next()
        XCTAssertEqual(next?.key, "job-2")
        XCTAssertEqual(next?.work, 200)
        XCTAssertNil(queue.next())
        queue.finish("job-0"); queue.finish("job-2")
        var drained: [String] = []
        while let entry = queue.next() { drained.append(entry.key); queue.finish(entry.key) }
        XCTAssertEqual(drained, (3..<12).map { "job-\($0)" } + ["job-0"])
    }

    func testDelayedRetryDoesNotBlockUnrelatedWorkAndRemovalDoesNotReleaseActiveOwnership() {
        var queue = SessionSummaryQueue<Int>(capacity: 1)
        for key in ["slow", "retry", "healthy"] { queue.enqueue(key, work: 1, merge: { _, new in new }) }
        XCTAssertEqual(queue.next()?.key, "slow")
        queue.removeAllPending()
        XCTAssertEqual(queue.active, ["slow"])
        for key in ["retry", "healthy", "removed"] { queue.enqueue(key, work: 1, merge: { _, new in new }) }
        queue.retainPending { key, _ in key != "removed" }
        XCTAssertNil(queue.next())
        queue.finish("slow")
        XCTAssertEqual(queue.next(where: { key, _ in key != "retry" })?.key, "healthy")
        queue.finish("healthy")
        XCTAssertEqual(queue.next()?.key, "retry")
    }
}

@MainActor
final class CommandCenterSchedulingTests: XCTestCase {
    private func fixture(provider: AgentStatusProvider, capacity: Int = 2) -> (AppState, CommandCenterModel, UserDefaults, String) {
        let suite = "cc.scheduler.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let app = AppState(isolatedForTesting: true)
        app.machines = [
            Machine(id: "a-slow", name: "Slow transport", host: "", os: "linux", isLocal: false,
                    httpBase: "http://127.0.0.1:1", wsBase: "ws://127.0.0.1:1"),
            Machine(id: "z-fast", name: "Fast transport", host: "", os: "windows", isLocal: false,
                    httpBase: "http://127.0.0.1:2", wsBase: "ws://127.0.0.1:2")
        ]
        for machine in app.machines {
            app.sessionsByMachine[machine.id] = (0..<4).map {
                SessionInfo(name: "job-\($0)", state: "idle", lineageID: "\(machine.os)-\($0)")
            }
        }
        let model = CommandCenterModel(collector: true, defaults: defaults, provider: provider, maximumConcurrentSummaries: capacity)
        model.bind(app); model.collectionAllowed = { true }; model.collectionGeneration = { 1 }
        return (app, model, defaults, suite)
    }

    func testAllQueuedSessionsDrainWithoutAnotherSweepInBothNetworkModes() async throws {
        for lowData in [false, true] {
            let provider = SchedulingProvider(), gate = SummaryTestGate()
            let (app, model, defaults, suite) = fixture(provider: provider)
            defer { defaults.removePersistentDomain(forName: suite) }
            model.networkPolicy = { NetworkPolicy(lowData: lowData) }
            model.monotonicNow = { 100 } // no timer can advance during this test
            let slowStarted = expectation(description: "slow jobs reserved both slots")
            slowStarted.expectedFulfillmentCount = 2
            var fetches: [String] = []
            var running = 0, peak = 0
            model.fetchOutput = { base, name in
                fetches.append(base + name); running += 1; peak = max(peak, running)
                if base.hasSuffix(":1") && name < "job-2" { slowStarted.fulfill(); await gate.wait() }
                running -= 1
                return "Evaluation results for \(base) \(name)."
            }
            let published = expectation(description: "all sessions summarized")
            published.expectedFulfillmentCount = 8
            var publishedKeys = Set<String>()
            model.statusesChanged = {
                for key in model.statuses.keys where publishedKeys.insert(key).inserted { published.fulfill() }
            }
            model.collectTick()
            await fulfillment(of: [slowStarted], timeout: 2)
            XCTAssertEqual(model.activeSummaryKeys.count, 2)
            XCTAssertEqual(model.queuedSummaryKeys.count, 6)
            XCTAssertEqual(fetches.count, 2, "Fast transports must not even start ahead of admitted work")
            gate.release()
            await fulfillment(of: [published], timeout: 5)
            await settle(model)
            XCTAssertEqual(model.statuses.count, app.sessionsByMachine.values.reduce(0) { $0 + $1.count })
            XCTAssertEqual(provider.calls.count, 8)
            XCTAssertEqual(Set(fetches).count, 8)
            XCTAssertLessThanOrEqual(peak, 2)
            XCTAssertTrue(model.activeSummaryKeys.isEmpty)
            XCTAssertTrue(model.queuedSummaryKeys.isEmpty)
        }
    }

    func testBusySessionRefreshCoalescesAndReplacementCannotPublishOldResult() async throws {
        for lineage in ["tmux", "conpty"] {
            let gate = SummaryTestGate(), provider = SchedulingProvider()
            let (app, model, defaults, suite) = fixture(provider: provider, capacity: 1)
            defer { defaults.removePersistentDomain(forName: suite) }
            app.machines = [app.machines[0]]
            app.sessionsByMachine = ["a-slow": [SessionInfo(name: "job", lineageID: lineage + "-old")]]
            model.monotonicNow = { 100 }; model.networkPolicy = { NetworkPolicy(lowData: true) }
            let started = expectation(description: "old capture started"), complete = expectation(description: "replacement summarized")
            var captures = 0
            model.fetchOutput = { _, _ in
                captures += 1
                if captures == 1 { started.fulfill(); await gate.wait(); return "Old conversation" }
                return "New conversation"
            }
            var completed = false
            model.statusesChanged = {
                if !completed, model.statuses["a-slow/job"] != nil { completed = true; complete.fulfill() }
            }
            model.collectTick()
            await fulfillment(of: [started], timeout: 2)
            let ref = SessionRef(machineID: "a-slow", session: "job")
            for _ in 0..<10 { model.requestRefresh(ref: ref); model.collectTick() }
            XCTAssertEqual(model.queuedSummaryKeys, [ref.id])
            app.sessionsByMachine["a-slow"] = [SessionInfo(name: "job", lineageID: lineage + "-new")]
            model.collectTick()
            gate.release()
            await fulfillment(of: [complete], timeout: 3)
            await settle(model)
            XCTAssertEqual(captures, 2)
            XCTAssertEqual(provider.calls, [ref.id])
            XCTAssertEqual(model.statuses[ref.id]?.oneLiner, "New conversation")
        }
    }

    func testLeaseLossDropsPendingWorkAndRejectsLateProviderResult() async throws {
        let provider = SchedulingProvider(), gate = SummaryTestGate()
        let (_, model, defaults, suite) = fixture(provider: provider, capacity: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        // CommandCenterModel intentionally keeps its app weak; retain the fixture.
        let app = AppState(isolatedForTesting: true)
        app.machines[0].httpBase = "http://127.0.0.1:1"
        app.sessionsByMachine["local"] = (0..<3).map { SessionInfo(name: "job-\($0)", lineageID: "life-\($0)") }
        model.bind(app)
        var owns = true
        model.collectionAllowed = { owns }
        model.fetchOutput = { _, _ in "Terminal results" }
        let started = expectation(description: "model in flight")
        provider.handler = { _, _, _ in started.fulfill(); await gate.wait(); return AgentStatus(label: "idle", oneLiner: "Late result", updatedAt: .now) }
        model.collectTick()
        await fulfillment(of: [started], timeout: 2)
        owns = false; model.collectionOwnershipChanged(); model.collectTick()
        gate.release(); await settle(model)
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertTrue(model.queuedSummaryKeys.isEmpty)
        XCTAssertTrue(model.activeSummaryKeys.isEmpty)
        _ = app
    }

    func testCorrectionDuringGenerationIsDeliveredByOneCoalescedFollowUp() async throws {
        let provider = SchedulingProvider(), gate = SummaryTestGate()
        let (app, model, defaults, suite) = fixture(provider: provider, capacity: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        app.machines = [app.machines[0]]
        app.sessionsByMachine = ["a-slow": [SessionInfo(name: "job", lineageID: "life")]]
        model.monotonicNow = { 100 }
        model.fetchOutput = { _, _ in "Current terminal results" }
        let first = expectation(description: "first model call"), corrected = expectation(description: "correction delivered")
        var notes: [String?] = []
        provider.handler = { _, _, note in
            notes.append(note)
            if notes.count == 1 { first.fulfill(); await gate.wait() }
            return AgentStatus(label: "working", oneLiner: note ?? "Old answer", updatedAt: .now)
        }
        model.collectTick()
        await fulfillment(of: [first], timeout: 2)
        let ref = SessionRef(machineID: "a-slow", session: "job")
        model.setManualLabel(ref: ref, label: "working", actor: "test", correctionID: "correction", note: "Reviewed correction")
        model.statusesChanged = {
            if model.correctionDelivered(ref: ref, id: "correction") { corrected.fulfill() }
        }
        for _ in 0..<10 { model.collectTick() }
        XCTAssertEqual(model.queuedSummaryKeys, [ref.id])
        gate.release()
        await fulfillment(of: [corrected], timeout: 2); await settle(model)
        XCTAssertEqual(notes.count, 2)
        XCTAssertNil(notes[0])
        XCTAssertEqual(notes[1], "Reviewed correction")
        XCTAssertEqual(model.statuses[ref.id]?.oneLiner, "Reviewed correction")
    }

    func testCollectorRestoresOnlyMatchingWorkspaceAndSessionLifetimes() async throws {
        let provider = SchedulingProvider(), gate = SummaryTestGate()
        let (app, model, defaults, suite) = fixture(provider: provider, capacity: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        app.machines = [app.machines[0]]
        try app.sharedWorkspace.replica.bind("saved-workspace")
        let reader = CommandCenterModel(defaults: defaults)
        reader.bind(app)
        reader.statuses = Dictionary(uniqueKeysWithValues: (0..<4).map {
            ("a-slow/job-\($0)", AgentStatus(label: "idle", oneLiner: "Saved \($0)", updatedAt: Date(timeIntervalSince1970: 100)))
        })
        reader.readSharedStatuses()
        let readerCache = defaults.data(forKey: "ut.ccPresentation.v2.saved-workspace")
        model.collectionOwnershipChanged(workspaceID: "saved-workspace")
        XCTAssertEqual(model.statuses.count, 4)
        app.sessionsByMachine["a-slow"]![3].lineageID = "replacement"
        let first = expectation(description: "missing replacement gets first slot")
        var captures: [String] = []
        model.fetchOutput = { _, name in
            captures.append(name)
            if captures.count == 1 { first.fulfill(); await gate.wait() }
            return "New \(name)"
        }
        model.collectTick()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(captures.first, "job-3")
        XCTAssertNil(model.statuses["a-slow/job-3"])
        XCTAssertEqual(model.statuses["a-slow/job-0"]?.oneLiner, "Saved 0")
        gate.release(); await settle(model)
        await withCheckedContinuation { continuation in
            CodexStatusProvider.writeDefaults { continuation.resume() }
        }
        XCTAssertEqual(defaults.data(forKey: "ut.ccPresentation.v2.saved-workspace"), readerCache,
                       "Collector persistence must not overwrite reader-owned pending corrections")
        XCTAssertNotNil(defaults.data(forKey: "ut.ccCollector.v1.saved-workspace"))
        let restarted = CommandCenterModel(collector: true, defaults: defaults, provider: provider)
        restarted.collectionOwnershipChanged(workspaceID: "saved-workspace")
        XCTAssertEqual(restarted.statuses["a-slow/job-0"]?.oneLiner, "New job-0")
        model.collectionOwnershipChanged(workspaceID: "different-workspace")
        XCTAssertTrue(model.statuses.isEmpty)
    }

    func testFailuresDoNotBlockHealthySessionsAndRetryOnExplicitCadence() async throws {
        let provider = SchedulingProvider()
        let (app, model, defaults, suite) = fixture(provider: provider, capacity: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        app.machines = [app.machines[0]]
        app.sessionsByMachine["a-slow"] = [SessionInfo(name: "bad", lineageID: "bad"), SessionInfo(name: "good", lineageID: "good")]
        var now = 100.0, failure = true
        model.monotonicNow = { now }; model.networkPolicy = { NetworkPolicy(lowData: true) }
        var attempts: [String] = []
        model.fetchOutput = { _, name in attempts.append(name); return name == "bad" && failure ? nil : "Result for \(name)" }
        let good = expectation(description: "healthy session finished")
        var publishedGood = false
        model.statusesChanged = {
            if !publishedGood, model.statuses["a-slow/good"] != nil { publishedGood = true; good.fulfill() }
        }
        model.collectTick()
        await fulfillment(of: [good], timeout: 2); await settle(model)
        XCTAssertEqual(attempts, ["bad", "good"])
        model.statusesChanged = nil
        for _ in 0..<10 { model.collectTick() }
        XCTAssertEqual(attempts, ["bad", "good"])
        failure = false; now = 160
        let retried = expectation(description: "retry at sixty seconds, not six minutes")
        var publishedRetry = false
        model.statusesChanged = {
            if !publishedRetry, model.statuses["a-slow/bad"] != nil { publishedRetry = true; retried.fulfill() }
        }
        model.collectTick()
        await fulfillment(of: [retried], timeout: 2); await settle(model)
        XCTAssertEqual(model.statuses.count, 2)
        XCTAssertEqual(attempts.filter { $0 == "bad" }.count, 2)
        XCTAssertEqual(provider.calls.filter { $0.hasSuffix("/good") }.count, 1, "Unchanged content must not make another model call")
    }

    private func settle(_ model: CommandCenterModel) async {
        for _ in 0..<100 {
            if model.activeSummaryKeys.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class SchedulingProvider: AgentStatusProvider {
    @MainActor var handler: ((String, String, String?) async -> AgentStatus?)?
    @MainActor private(set) var calls: [String] = []
    var spendUSD: Double { 0 }
    var callCount: Int { 0 }
    func forget(key: String) {}
    func status(forKey key: String, output: String, note: String?) async -> AgentStatus? {
        await generate(key, output, note)
    }
    @MainActor private func generate(_ key: String, _ output: String, _ note: String?) async -> AgentStatus? {
        calls.append(key)
        if let handler { return await handler(key, output, note) }
        return AgentStatus(label: "idle", oneLiner: output, updatedAt: .now)
    }
}

@MainActor
private final class SummaryTestGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { let pending = waiting; waiting.removeAll(); pending.forEach { $0.resume() } }
}
