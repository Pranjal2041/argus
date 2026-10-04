@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class HTTPPollingTests: XCTestCase {
    private let url = URL(string: "https://provider.example/usage")!
    private let headers = ["Authorization": "Bearer fixture"]

    func testRetryAfterSupportsSecondsAndAllHTTPDateFormats() throws {
        let now = Date(timeIntervalSince1970: 784111777) // Sun, 06 Nov 1994 08:49:37 GMT
        XCTAssertEqual(URLSessionHTTPClient.retryAfter(" 3600 ", now: now), 3600)
        for value in ["Sun, 06 Nov 1994 09:49:37 GMT", "Sunday, 06-Nov-94 09:49:37 GMT", "Sun Nov 6 09:49:37 1994"] {
            XCTAssertEqual(URLSessionHTTPClient.retryAfter(value, now: now), 3600, value)
        }
        XCTAssertEqual(URLSessionHTTPClient.retryAfter("Sun, 06 Nov 1994 07:49:37 GMT", now: now), 0)
        for value in ["-1", "nan", "inf", "nonsense"] { XCTAssertNil(URLSessionHTTPClient.retryAfter(value)) }
        XCTAssertNil(URLSessionHTTPClient.retryAfter(nil))
    }

    func test429IsNotImmediatelyRetriedAndCooldownSurvivesClientRecreation() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429, retryAfter: 3600), reply(200)])
        let first = PollingClient(transport, coordinator)
        let deadline = try await limited { _ = try await first.get(self.url, headers: self.headers) }
        XCTAssertEqual(deadline, clock.now.addingTimeInterval(3600))
        clock.advance(120)
        let recreated = PollingClient(transport, coordinator)
        let sameDeadline = try await limited { _ = try await recreated.get(self.url, headers: self.headers) }
        XCTAssertEqual(sameDeadline, deadline)
        let count = await transport.count
        XCTAssertEqual(count, 1, "Neither a background poll nor a newly constructed client may bypass Retry-After")
        clock.advance(3480)
        _ = try await recreated.get(url, headers: headers)
        let finalCount = await transport.count
        XCTAssertEqual(finalCount, 2)
    }

    func testRepeatedRateLimitsBackOffAndSuccessResetsBackoff() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429), reply(429), reply(200), reply(429)])
        let client = PollingClient(transport, coordinator)
        let first = try await limited { _ = try await client.get(self.url, headers: self.headers) }
        XCTAssertEqual(first, clock.now.addingTimeInterval(120))
        clock.advance(120)
        let second = try await limited { _ = try await client.get(self.url, headers: self.headers) }
        XCTAssertEqual(second, clock.now.addingTimeInterval(240))
        clock.advance(240)
        _ = try await client.get(url, headers: headers)
        let reset = try await limited { _ = try await client.get(self.url, headers: self.headers) }
        XCTAssertEqual(reset, clock.now.addingTimeInterval(120))
    }

    func testCooldownCoversOtherPathsButNotOtherAccountsOrOrigins() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429), reply(200), reply(200)])
        let client = PollingClient(transport, coordinator)
        _ = try await limited { _ = try await client.get(self.url, headers: self.headers) }
        _ = try await limited { _ = try await client.get(self.url.appendingPathComponent("details"), headers: self.headers) }
        _ = try await client.get(url, headers: ["Authorization": "Bearer other-account"])
        _ = try await client.get(URL(string: "https://other.example/usage")!, headers: headers)
        let count = await transport.count
        XCTAssertEqual(count, 3)
    }

    func testConcurrentIdenticalChecksShareOneRequestWithoutCachingSuccess() async throws {
        let coordinator = HTTPPollingCoordinator(), transport = PollingTransport([reply(200), reply(200)], delay: .milliseconds(100))
        let client = PollingClient(transport, coordinator)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await client.get(self.url, headers: self.headers) } }
            try await group.waitForAll()
        }
        let concurrentCount = await transport.count
        XCTAssertEqual(concurrentCount, 1)
        _ = try await client.get(url, headers: headers)
        let laterCount = await transport.count
        XCTAssertEqual(laterCount, 2, "A completed response must not become a falsely fresh reading")
    }

    func testConcurrentWaitersAllReceiveTheSameCooldown() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429)], delay: .milliseconds(100))
        let client = PollingClient(transport, coordinator)
        let deadlines = try await withThrowingTaskGroup(of: Date.self) { group in
            for _ in 0..<20 {
                group.addTask { try await self.limited { _ = try await client.get(self.url, headers: self.headers) } }
            }
            var dates: [Date] = []
            for try await date in group { dates.append(date) }
            return dates
        }
        XCTAssertEqual(Set(deadlines), [clock.now.addingTimeInterval(120)])
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testExplicitServerUnavailableCooldownIsNotTruncated() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(503, retryAfter: 900), reply(200)])
        let client = PollingClient(transport, coordinator)
        for advance in [0.0, 120.0] {
            clock.advance(advance)
            do { _ = try await client.get(url, headers: headers); XCTFail("Must defer") }
            catch let error as IntegrationError { XCTAssertFalse(error.needsAuthentication) }
        }
        let count = await transport.count
        XCTAssertEqual(count, 1)
        clock.advance(780)
        _ = try await client.get(url, headers: headers)
    }

    func testAuthenticationAndPermissionFailuresAreNotRateLimitedOrRetried() async throws {
        let coordinator = HTTPPollingCoordinator(), transport = PollingTransport([reply(401), reply(403), reply(200)])
        let client = PollingClient(transport, coordinator)
        for status in [401, 403] {
            do { _ = try await client.get(url, headers: headers); XCTFail("Must reject") }
            catch HTTPFailure.status(let actual) { XCTAssertEqual(actual, status) }
        }
        _ = try await client.get(url, headers: headers)
        let count = await transport.count
        XCTAssertEqual(count, 3)
    }

    func testShortServerUnavailableRetryStillRecoversWithinTheRefresh() async throws {
        let transport = PollingTransport([reply(503, retryAfter: 0.01), reply(200)])
        let client = PollingClient(transport, HTTPPollingCoordinator())
        _ = try await client.get(url, headers: headers)
        let count = await transport.count
        XCTAssertEqual(count, 2)
    }

    func testOlderSuccessfulResponseCannotEraseANewerCooldown() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = ControlledPollingTransport()
        let slow = URLRequest(url: url.appendingPathComponent("slow"))
        let limitedRequest = URLRequest(url: url.appendingPathComponent("limited"))
        let first = Task { try await coordinator.response(to: slow) { try await transport.send(slow) } }
        await transport.waitForRequests(1)
        let second = Task { try await coordinator.response(to: limitedRequest) { try await transport.send(limitedRequest) } }
        await transport.waitForRequests(2)
        await transport.complete(path: limitedRequest.url!.path, with: reply(429))
        _ = try await limited { _ = try await second.value }
        await transport.complete(path: slow.url!.path, with: reply(200))
        _ = try await first.value
        _ = try await limited { _ = try await coordinator.response(to: slow) { XCTFail("Cooldown was erased"); return self.reply(200) } }
    }

    func testCancelledCallerDoesNotTurnSharedResponseIntoFreshSuccess() async throws {
        let coordinator = HTTPPollingCoordinator(), transport = ControlledPollingTransport()
        let request = URLRequest(url: url)
        let first = Task { try await coordinator.response(to: request) { try await transport.send(request) } }
        await transport.waitForRequests(1)
        first.cancel()
        await transport.complete(path: url.path, with: reply(200))
        do { _ = try await first.value; XCTFail("Caller cancellation must propagate") }
        catch is CancellationError {}
        let next = try await coordinator.response(to: request) { self.reply(200) }
        XCTAssertEqual(next.status, 200, "The completed shared task must be cleaned up")
    }

    func testLaterInFlightErrorCannotShortenExistingServerCooldown() async throws {
        for laterResponse in [reply(429), reply(503, retryAfter: 1)] {
            let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
            let transport = ControlledPollingTransport()
            let firstRequest = URLRequest(url: url.appendingPathComponent("first"))
            let secondRequest = URLRequest(url: url.appendingPathComponent("second"))
            let first = Task { try await coordinator.response(to: firstRequest) { try await transport.send(firstRequest) } }
            await transport.waitForRequests(1)
            let second = Task { try await coordinator.response(to: secondRequest) { try await transport.send(secondRequest) } }
            await transport.waitForRequests(2)
            await transport.complete(path: firstRequest.url!.path, with: reply(429, retryAfter: 3600))
            let originalDeadline = try await limited { _ = try await first.value }
            clock.advance(1)
            await transport.complete(path: secondRequest.url!.path, with: laterResponse)
            let remainingDeadline = try await limited { _ = try await second.value }
            XCTAssertEqual(remainingDeadline, originalDeadline)
            clock.advance(300)
            _ = try await limited {
                _ = try await coordinator.response(to: firstRequest) { XCTFail("A shorter response bypassed Retry-After"); return self.reply(200) }
            }
        }
    }

    func testCustomTransportInheritsSharedCooldownByDefault() async throws {
        let transport = PollingTransport([reply(429)])
        let client = DefaultPollingClient(transport: transport)
        let account = ["Authorization": "Bearer fixture-\(UUID().uuidString)"]
        for _ in 0..<2 { _ = try await limited { _ = try await client.get(self.url, headers: account) } }
        let count = await transport.count
        XCTAssertEqual(count, 1)
    }

    func testRateLimitDoesNotTriggerDaytonaVersionFallback() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429), reply(200, #"{"balanceCents":2500}"#)])
        let billing = DaytonaBilling(client: PollingClient(transport, coordinator))
        for _ in 0..<2 {
            _ = try await limited { _ = try await billing.fetch(organization: "org-1", headers: self.headers, now: clock.now) }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v2/organization/org-1/wallet"])
        clock.advance(120)
        let reading = try await billing.fetch(organization: "org-1", headers: headers, now: clock.now)
        XCTAssertEqual(reading.balanceUSD, 25)
    }

    @MainActor
    func testClaudeCooldownPreservesReadingAndRecoversWithoutReauthentication() async throws {
        let clock = PollingClock(), coordinator = HTTPPollingCoordinator(now: { clock.now })
        let transport = PollingTransport([reply(429, retryAfter: 600), reply(200, #"{"seven_day":{"utilization":25}}"#)])
        let config = SourceConfiguration(id: "fixture", integration: .claude, label: "Fixture", credentialReference: "fixture")
        let adapter = LiveClaudeIntegration(configuration: config, client: PollingClient(transport, coordinator), secrets: PollingCredentials())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "UsageTests.Polling.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let cache = SnapshotCache(url: directory.appendingPathComponent("readings.json"))
        let previous = try LiveClaudeIntegration.normalize(.decode(Data(#"{"seven_day":{"utilization":10}}"#.utf8)), configuration: config, now: clock.now)
        try cache.save([previous])
        let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter], origin: .live), defaults: defaults, cache: cache)
        for _ in 0..<3 { await store.refresh() }
        XCTAssertEqual(store.sources.first?.observedAt, previous.observedAt)
        XCTAssertEqual(store.sources.first?.quota?.weeklyWindow?.remainingPercent, 90)
        XCTAssertTrue(try XCTUnwrap(store.sources.first?.isStale))
        XCTAssertEqual(store.failures.first?.errorTitle, "Rate limited")
        XCTAssertEqual(store.failures.first?.needsAuthentication, false)
        XCTAssertTrue(store.failures.first?.error?.contains("paused until") == true)
        let count = await transport.count
        XCTAssertEqual(count, 1)
        clock.advance(600)
        await store.refresh()
        XCTAssertFalse(try XCTUnwrap(store.sources.first?.isStale))
        XCTAssertEqual(store.sources.first?.quota?.weeklyWindow?.remainingPercent, 75)
        XCTAssertTrue(store.failures.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"], "A rate limit must not rotate credentials")
    }

    private func reply(_ status: Int, _ body: String = "{}", retryAfter: Double? = nil) -> HTTPResponse {
        HTTPResponse(status: status, data: Data(body.utf8), retryAfter: retryAfter)
    }

    private func limited(_ operation: () async throws -> Void) async throws -> Date {
        do { try await operation(); XCTFail("Expected rate limit"); return .distantPast }
        catch IntegrationError.rateLimited(let until) { return until }
    }
}

@available(macOS 14.0, *)
private struct PollingClient: HTTPClient {
    let transport: PollingTransport
    let pollingCoordinator: HTTPPollingCoordinator
    init(_ transport: PollingTransport, _ coordinator: HTTPPollingCoordinator) {
        self.transport = transport; self.pollingCoordinator = coordinator
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse { try await transport.send(request) }
}

@available(macOS 14.0, *)
private struct DefaultPollingClient: HTTPClient {
    let transport: PollingTransport
    func send(_ request: URLRequest) async throws -> HTTPResponse { try await transport.send(request) }
}

@available(macOS 14.0, *)
private actor PollingTransport {
    private var responses: [HTTPResponse]
    private let delay: Duration?
    private(set) var requests: [URLRequest] = []
    var count: Int { requests.count }
    init(_ responses: [HTTPResponse], delay: Duration? = nil) { self.responses = responses; self.delay = delay }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw IntegrationError.invalidResponse("Unexpected request") }
        let response = responses.removeFirst()
        if let delay { try await Task.sleep(for: delay) }
        return response
    }
}

private final class PollingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

@available(macOS 14.0, *)
private actor ControlledPollingTransport {
    private var pending: [String: CheckedContinuation<HTTPResponse, Error>] = [:]
    private var count = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            pending[request.url!.path] = continuation
            count += 1
            for (threshold, observer) in observers where count >= threshold { observer.resume() }
            observers.removeAll { count >= $0.0 }
        }
    }
    func waitForRequests(_ threshold: Int) async {
        if count >= threshold { return }
        await withCheckedContinuation { observers.append((threshold, $0)) }
    }
    func complete(path: String, with response: HTTPResponse) { pending.removeValue(forKey: path)?.resume(returning: response) }
}

@available(macOS 14.0, *)
private struct PollingCredentials: CredentialStoring {
    func read(reference: String) throws -> [String: String] {
        ["accessToken": "fixture", "expiresAt": String(Date().timeIntervalSince1970 + 3600)]
    }
    func save(_ values: [String: String], reference: String) throws { XCTFail("No credential writes expected") }
    func delete(reference: String) throws { XCTFail("No credential writes expected") }
}
