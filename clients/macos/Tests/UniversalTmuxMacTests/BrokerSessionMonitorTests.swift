import Network
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

private func testMachine(_ base: String = "http://127.0.0.1:8123", id: String = "test") -> Machine {
    Machine(id: id, name: "test broker", isLocal: false, httpBase: base,
            wsBase: base.replacingOccurrences(of: "http", with: "ws"))
}

final class BrokerHealthTests: XCTestCase {
    func testSingleFailureIsDelayedAndSustainedLossBecomesOffline() {
        var health = BrokerHealth()
        health.record(success: true, responding: true, evidence: nil, now: 100)
        health.record(success: false, responding: false, evidence: nil, now: 108)
        XCTAssertEqual(health.status, .delayed)
        health.record(success: false, responding: false, evidence: nil, now: 120)
        XCTAssertEqual(health.status, .delayed)
        health.record(success: false, responding: false, evidence: nil, now: 139)
        XCTAssertEqual(health.status, .unreachable)
        health.record(success: true, responding: true, evidence: nil, now: 140)
        XCTAssertEqual(health.status, .reachable)
        XCTAssertEqual(health.failureCount, 0)
        XCTAssertEqual(health.retryDelay, 0)
    }

    func testCurrentTrafficAndHTTPResponsesPreventFalseOfflineButOldSocketEvidenceExpires() {
        for responding in [true, false] {
            var health = BrokerHealth()
            for time in stride(from: 0.0, through: 100.0, by: 10.0) {
                health.record(success: false, responding: responding,
                              evidence: responding ? nil : time, now: time)
                XCTAssertEqual(health.status, .delayed)
            }
            health.record(success: false, responding: false, evidence: 100, now: 131)
            XCTAssertEqual(health.status, .unreachable)
            XCTAssertTrue(health.observe(132, now: 132))
            XCTAssertEqual(health.status, .delayed)
        }
    }

    func testRetryRateRemainsBoundedDuringLongOutage() {
        var health = BrokerHealth()
        var delays: [TimeInterval] = []
        for index in 0..<100 {
            health.record(success: false, responding: false, evidence: nil, now: Double(index * 30))
            delays.append(health.retryDelay)
        }
        XCTAssertEqual(Array(delays.prefix(5)), [2, 4, 8, 16, 30])
        XCTAssertEqual(delays.max(), 30)
        XCTAssertEqual(health.status, .unreachable)
    }

    func testEvidenceMatchesWebSocketAndHTTPOriginsWithoutMixingPortsOrTLS() throws {
        let registry = BrokerReachabilityEvidence()
        for (socket, http) in [("ws://127.0.0.1:8123/ws?session=one", "http://127.0.0.1:8123"),
                               ("wss://compute.example:8722/ws?session=two", "https://compute.example:8722")] {
            registry.record(url: try XCTUnwrap(URL(string: socket)), now: 12)
            XCTAssertEqual(registry.latest(httpBase: http), 12)
            XCTAssertNil(registry.latest(httpBase: http + "0"))
        }
        XCTAssertNil(registry.latest(httpBase: "http://compute.example:8722"))
    }
}

@MainActor
final class BrokerSessionMonitorTests: XCTestCase {
    func testManualAndPeriodicRefreshesCoalesceAndFullWaitersWaitForFullSnapshot() async {
        let first = expectation(description: "foreground started")
        let full = expectation(description: "full started")
        let completed = expectation(description: "manual full completed")
        completed.expectedFulfillmentCount = 10
        var requests: [SessionRefreshScope] = []
        var held: [CheckedContinuation<BrokerSnapshotResult, Never>] = []
        let monitor = BrokerSessionMonitor(fetch: { _, scope in
            requests.append(scope)
            return await withCheckedContinuation { continuation in
                held.append(continuation)
                (requests.count == 1 ? first : full).fulfill()
            }
        }, probe: { _ in XCTFail("healthy request must not probe"); return false })
        let machine = testMachine()
        monitor.refresh(machine, scope: .foreground)
        await fulfillment(of: [first], timeout: 2)
        for _ in 0..<10 {
            monitor.refresh(machine, scope: .foreground)
            monitor.refresh(machine, scope: .all, force: true) { completed.fulfill() }
        }
        XCTAssertEqual(requests, [.foreground])
        held.removeFirst().resume(returning: .success([]))
        await fulfillment(of: [full], timeout: 2)
        XCTAssertEqual(requests, [.foreground, .all])
        held.removeFirst().resume(returning: .success([]))
        await fulfillment(of: [completed], timeout: 2)
    }

    func testCompletionReentrancyCannotOverlapQueuedFullRefresh() async {
        let first = expectation(description: "first started")
        let full = expectation(description: "full started")
        let done = expectation(description: "reentrant waiter completed")
        var held: [CheckedContinuation<BrokerSnapshotResult, Never>] = []
        var count = 0
        let monitor = BrokerSessionMonitor(fetch: { _, _ in
            count += 1
            return await withCheckedContinuation {
                held.append($0)
                (count == 1 ? first : full).fulfill()
            }
        }, probe: { _ in false })
        let machine = testMachine()
        monitor.refresh(machine, scope: .foreground) {
            monitor.refresh(machine, scope: .foreground, force: true) { done.fulfill() }
        }
        await fulfillment(of: [first], timeout: 2)
        monitor.refresh(machine, scope: .all)
        held.removeFirst().resume(returning: .success([]))
        await fulfillment(of: [full], timeout: 2)
        XCTAssertEqual(count, 2)
        held.removeFirst().resume(returning: .success([]))
        await fulfillment(of: [done], timeout: 2)
    }

    func testRetiredRouteCannotPublishEvenIfCancellationDoesNotStopItsReply() async {
        let started = expectation(description: "old route started")
        let updated = expectation(description: "new route published")
        let cancelledWaiter = expectation(description: "retired waiter released")
        var held: CheckedContinuation<BrokerSnapshotResult, Never>?
        var snapshots: [String] = []
        let monitor = BrokerSessionMonitor(fetch: { machine, _ in
            if machine.httpBase.hasPrefix("http:") {
                return await withCheckedContinuation { held = $0; started.fulfill() }
            }
            return .success([SessionInfo(name: "new")])
        }, probe: { _ in false })
        monitor.onUpdate = { _, update in
            snapshots += update.sessions?.map(\.name) ?? []
            updated.fulfill()
        }
        monitor.refresh(testMachine(), scope: .all) { cancelledWaiter.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        monitor.refresh(testMachine("https://new-route.example:8722"), scope: .all)
        await fulfillment(of: [updated, cancelledWaiter], timeout: 2)
        held?.resume(returning: .success([SessionInfo(name: "stale")]))
        await Task.yield()
        XCTAssertEqual(snapshots, ["new"])
    }

    func testSlowBrokerDoesNotBlockAnotherMachineAndRemovalReleasesWaiters() async {
        let slow = expectation(description: "slow started")
        let fast = expectation(description: "other machine completes")
        let retired = expectation(description: "removed waiter released")
        var held: CheckedContinuation<BrokerSnapshotResult, Never>?
        let monitor = BrokerSessionMonitor(fetch: { machine, _ in
            if machine.id == "slow" { return await withCheckedContinuation { held = $0; slow.fulfill() } }
            return .success([])
        }, probe: { _ in false })
        monitor.onUpdate = { machine, _ in XCTAssertEqual(machine.id, "fast"); fast.fulfill() }
        monitor.refresh(testMachine(id: "slow"), scope: .all) { retired.fulfill() }
        await fulfillment(of: [slow], timeout: 2)
        let other = testMachine("https://other.example:8722", id: "fast")
        monitor.refresh(other, scope: .foreground)
        await fulfillment(of: [fast], timeout: 2)
        monitor.retainMachines([other])
        await fulfillment(of: [retired], timeout: 2)
        held?.resume(returning: .failure(.transport(-1001)))
    }

    func testBackoffCoalescesFullIntentAndManualRefreshCanRetryImmediately() async {
        var clock: TimeInterval = 0
        var requests: [SessionRefreshScope] = []
        let first = expectation(description: "failure published")
        let second = expectation(description: "forced refresh published")
        let monitor = BrokerSessionMonitor(fetch: { _, scope in
            requests.append(scope)
            return requests.count == 1 ? .failure(.transport(-1001)) : .success([])
        }, probe: { _ in false }, now: { clock }, evidence: { _ in nil })
        monitor.onUpdate = { _, _ in (requests.count == 1 ? first : second).fulfill() }
        monitor.refresh(testMachine(), scope: .foreground)
        await fulfillment(of: [first], timeout: 2)
        clock = 1
        for _ in 0..<20 { monitor.refresh(testMachine(), scope: .all) }
        XCTAssertEqual(requests.count, 1)
        monitor.refresh(testMachine(), scope: .foreground, force: true)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(requests, [.foreground, .all])
    }

    func testProbeAndTerminalEvidenceKeepBothRoutesDelayedAndPreserveAppSnapshot() async {
        for base in ["http://127.0.0.1:8123", "https://broker.example:8722"] {
            for terminalEvidence in [false, true] {
                var clock: TimeInterval = 0
                var probes = 0
                let monitor = BrokerSessionMonitor(fetch: { _, _ in .failure(.transport(-1001)) },
                    probe: { _ in probes += 1; return true }, now: { clock },
                    evidence: { _ in terminalEvidence ? clock : nil })
                let state = AppState(isolatedForTesting: true, sessionMonitor: monitor)
                let machine = testMachine(base)
                state.machines = [machine]
                state.sessionsByMachine[machine.id] = [SessionInfo(name: "retained")]
                for index in 0..<4 {
                    clock = Double(index * 40)
                    let group = DispatchGroup()
                    state.refresh(machine, group: group, coalesce: false)
                    let done = expectation(description: "app refresh completed")
                    group.notify(queue: .main) { done.fulfill() }
                    await fulfillment(of: [done], timeout: 2)
                    XCTAssertEqual(state.statusByMachine[machine.id], .delayed)
                    XCTAssertEqual(state.sessionsByMachine[machine.id]?.map(\.name), ["retained"])
                    XCTAssertNotNil(state.refreshIssueByMachine[machine.id])
                }
                XCTAssertEqual(probes, terminalEvidence ? 0 : 4)
            }
        }
    }

    func testHTTPAndSchemaErrorsAreNotOfflineAndRecoveryClearsTheIssue() async {
        for failure in [BrokerRefreshFailure.http(503), .http(401), .invalidSnapshot, .invalidURL] {
            var clock: TimeInterval = 0
            var healthy = false
            let monitor = BrokerSessionMonitor(fetch: { _, _ in healthy ? .success([]) : .failure(failure) },
                probe: { _ in XCTFail("HTTP response already proves reachability"); return false },
                now: { clock }, evidence: { _ in nil })
            let state = AppState(isolatedForTesting: true, sessionMonitor: monitor)
            let machine = testMachine()
            state.machines = [machine]
            for index in 0..<4 {
                clock = Double(index * 60)
                healthy = index == 3
                let done = expectation(description: "refresh")
                let group = DispatchGroup()
                state.refresh(machine, group: group, coalesce: false)
                group.notify(queue: .main) { done.fulfill() }
                await fulfillment(of: [done], timeout: 2)
                XCTAssertEqual(state.statusByMachine[machine.id], healthy ? .reachable : .delayed)
            }
            XCTAssertNil(state.refreshIssueByMachine[machine.id])
        }
    }

    func testStatusBadgesRenderInActualSwiftUIView() throws {
        let view = VStack(alignment: .leading, spacing: 16) {
            ForEach([BrokerConnectionStatus.checking, .reachable, .delayed, .unreachable], id: \.rawValue) { status in
                HStack {
                    Text("TEST BROKER").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    MachineConnectionBadge(status: status, sessionCount: 26)
                }
            }
        }.padding(16).frame(width: 300).background(Theme.sidebarBackground)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("argus-broker-status-badges.png")
        try png.write(to: path)
        XCTAssertEqual(image.width, 600)
    }
}

/// A real HTTP fixture: four bulk requests deliberately never respond. Monitoring
/// must still reach /sessions on the same origin, without increasing the bulk pool.
final class BrokerMonitoringTransportTests: XCTestCase {
    func testLiveMonitoringRoutes() async throws {
        // Opt-in, read-only smoke check through the actual TLS proxy and native
        // transport. No session creation, WebSocket attach, or broker restart.
        guard let raw = ProcessInfo.processInfo.environment["UT_TEST_MONITOR_ROUTES"],
              let data = raw.data(using: .utf8),
              let routes = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw XCTSkip("live monitoring routes not configured")
        }
        for route in routes {
            let base = try XCTUnwrap(route["url"])
            if let address = route["address"], let host = URL(string: base)?.host {
                registerBrokerTLSAddress(address, dnsName: host)
            }
            for scope in [SessionRefreshScope.foreground, .all] {
                let result = await BrokerSessionMonitor.fetchSnapshot(testMachine(base), scope)
                guard case .success = result else { return XCTFail("live monitoring failed on \(base)") }
            }
        }
    }

    private final class Connections: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NWConnection] = []
        func add(_ connection: NWConnection) { lock.lock(); defer { lock.unlock() }; values.append(connection) }
        func cancel() { lock.lock(); defer { lock.unlock() }; values.forEach { $0.cancel() } }
    }

    func testMonitoringHasReservedCapacityWhenGeneralPoolIsSaturated() async throws {
        let queue = DispatchQueue(label: "monitoring-isolation-fixture")
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listening")
        let bulkStarted = expectation(description: "all four general slots occupied")
        bulkStarted.expectedFulfillmentCount = 4
        let connections = Connections()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connections.add(connection)
            connection.start(queue: queue)
            Self.readRequest(connection, buffer: Data()) { request in
                if request.contains("/bulk") { bulkStarted.fulfill(); return }
                let body = #"{"sessions":[{"name":"live","windows":1,"attached":false,"activity":0}]}"#
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 2)
        let port = try XCTUnwrap(listener.port)
        let base = "http://127.0.0.1:\(port.rawValue)"
        let general = makeBrokerSession(configuration: .ephemeral)
        let monitoring = makeBrokerSession(configuration: .ephemeral, traffic: .monitoring)
        defer {
            general.invalidateAndCancel()
            monitoring.invalidateAndCancel()
            listener.cancel()
            connections.cancel()
        }
        XCTAssertEqual(general.configuration.httpMaximumConnectionsPerHost, 4)
        XCTAssertEqual(monitoring.configuration.httpMaximumConnectionsPerHost, 2)
        XCTAssertNil(monitoring.configuration.urlCache)
        XCTAssertEqual(monitoring.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(monitoring.configuration.timeoutIntervalForResource, 8)
        for index in 0..<4 {
            general.dataTask(with: try XCTUnwrap(URL(string: base + "/bulk/\(index)"))).resume()
        }
        await fulfillment(of: [bulkStarted], timeout: 2)
        let started = ProcessInfo.processInfo.systemUptime
        let result = await BrokerSessionMonitor.fetchSnapshot(testMachine(base), .foreground, session: monitoring)
        guard case .success(let sessions) = result else { return XCTFail("monitoring was starved by bulk traffic") }
        XCTAssertEqual(sessions.map(\.name), ["live"])
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }

    private static func readRequest(_ connection: NWConnection, buffer: Data, handler: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                handler(text)
            } else if !done && error == nil && buffer.count < 32_768 {
                readRequest(connection, buffer: buffer, handler: handler)
            }
        }
    }
}
