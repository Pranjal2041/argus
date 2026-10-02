@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class ClaudeIntegrationTests: XCTestCase {
    private var config: SourceConfiguration { SourceConfiguration(id: "claude-a", integration: .claude, label: "Research") }
    private func json(_ text: String) throws -> JSONValue { try .decode(Data(text.utf8)) }

    func testWindowsRemainSeparateAndSparseFieldsStayMissing() throws {
        let source = try LiveClaudeIntegration.normalize(json(#"{"five_hour":{"utilization":25,"resets_at":"2026-09-21T14:00:00.000000Z"},"seven_day":{"utilization":80},"seven_day_sonnet":{"utilization":37},"seven_day_opus":null,"extra_usage":{"is_enabled":true,"used_credits":1200}}"#), configuration: config, email: "fixture@example.com", now: .now)
        XCTAssertEqual(source.quota?.shortWindow?.remainingPercent, 75)
        XCTAssertNotNil(source.quota?.shortWindow?.resetsAt)
        XCTAssertEqual(source.quota?.weeklyWindow?.remainingPercent, 20)
        XCTAssertNil(source.quota?.weeklyWindow?.resetsAt)
        XCTAssertEqual(source.quota?.additionalBuckets.map(\.name), ["Sonnet"])
        XCTAssertEqual(source.accountIdentity, "fixture@example.com")
        XCTAssertNil(source.spend)
        XCTAssertEqual(source.integration, .claude)
    }
    func testMissingIsNotZeroAndMalformedLimitsAreRejected() throws {
        for text in [#"{}"#, #"{"five_hour":{"utilization":-1}}"#, #"{"five_hour":{"utilization":101}}"#, #"{"five_hour":{"utilization":"no"}}"#] {
            XCTAssertThrowsError(try LiveClaudeIntegration.normalize(json(text), configuration: config, now: .now))
        }
        let source = try LiveClaudeIntegration.normalize(json(#"{"seven_day":{"utilization":0}}"#), configuration: config, now: .now)
        XCTAssertNil(source.quota?.shortWindow)
        XCTAssertEqual(source.quota?.weeklyWindow?.remainingPercent, 100)
    }
    func testWeeklyBreakdownMetadataDoesNotInvalidateLiveLimits() throws {
        // Breakdown fields have no top-level utilization: they are not quota windows.
        for breakdown in [#"{"sonnet":{"utilization":2}}"#, #"[{"model":"sonnet","utilization":2}]"#, "{}", "[]", "null"] {
            let usage = try json("""
                {"five_hour":{"utilization":2},"seven_day":{"utilization":0},
                 "seven_day_breakdown":\(breakdown),"seven_day_sonnet":{"utilization":3},
                 "seven_day_opus":null,"seven_day_metadata":{"updated_at":"2026-09-21T20:00:00Z"}}
                """)
            let observedAt = Date(timeIntervalSince1970: 1_790_000_000)
            let source = try LiveClaudeIntegration.normalize(usage, configuration: config, now: observedAt)
            XCTAssertEqual(source.quota?.shortWindow?.remainingPercent, 98)
            XCTAssertEqual(source.quota?.weeklyWindow?.remainingPercent, 100)
            XCTAssertEqual(source.quota?.additionalBuckets.map(\.name), ["Sonnet"])
            XCTAssertEqual(source.observedAt, observedAt)
            XCTAssertFalse(source.isStale)
            XCTAssertEqual(source.origin, .live)
        }
    }
    func testFutureWeeklyQuotaWindowsAreRecognizedByTheirSchema() throws {
        let source = try LiveClaudeIntegration.normalize(json(#"{"seven_day":{"utilization":20},"seven_day_future_model":{"utilization":45}}"#), configuration: config, now: .now)
        let bucket = try XCTUnwrap(source.quota?.additionalBuckets.first)
        XCTAssertEqual(bucket.id, "seven_day_future_model")
        XCTAssertEqual(bucket.windows.first?.remainingPercent, 55)
    }
    func testMetadataDoesNotMaskInvalidOrMissingRealLimits() throws {
        for text in [
            #"{"seven_day_breakdown":{"sonnet":{"utilization":2}}}"#,
            #"{"five_hour":{"utilization":2},"seven_day":{"utilization":"invalid"},"seven_day_breakdown":{}}"#,
            #"{"seven_day":{"utilization":0},"seven_day_sonnet":{}}"#,
            #"{"seven_day":{"utilization":0},"seven_day_future_model":{"utilization":"invalid"}}"#,
        ] {
            XCTAssertThrowsError(try LiveClaudeIntegration.normalize(json(text), configuration: config, now: .now))
        }
    }
    @MainActor
    func testRefreshWithWeeklyBreakdownClearsCachedStateAndFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "UsageTests.Claude.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let cache = SnapshotCache(url: directory.appendingPathComponent("readings.json"))
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        try cache.save([LiveClaudeIntegration.normalize(json(#"{"five_hour":{"utilization":50},"seven_day":{"utilization":30}}"#), configuration: config, now: oldDate)])
        let secrets = ClaudeMemoryCredentials(), reference = UUID().uuidString
        try secrets.save(["accessToken": "existing-grant", "expiresAt": String(Date.now.timeIntervalSince1970 + 3600)], reference: reference)
        var source = config; source.credentialReference = reference
        let client = ClaudeFixtureHTTP([
            (200, #"{"seven_day":{"utilization":"invalid"}}"#),
            (200, #"{"five_hour":{"utilization":2},"seven_day":{"utilization":0},"seven_day_breakdown":{"sonnet":{"utilization":2}}}"#),
        ])
        let adapter = LiveClaudeIntegration(configuration: source, client: client, secrets: secrets)
        let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter], origin: .live), defaults: defaults, cache: cache)
        await store.refresh(sourceID: source.id)
        XCTAssertTrue(try XCTUnwrap(store.sources.first).isStale)
        XCTAssertEqual(store.sources.first?.observedAt, oldDate)
        XCTAssertEqual(store.failures.count, 1)

        await store.refresh(sourceID: source.id)
        let fresh = try XCTUnwrap(store.sources.first)
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertFalse(fresh.isStale)
        XCTAssertGreaterThan(fresh.observedAt, oldDate)
        XCTAssertEqual(fresh.quota?.shortWindow?.remainingPercent, 98)
        XCTAssertEqual(fresh.quota?.weeklyWindow?.remainingPercent, 100)
        XCTAssertTrue(store.failures.isEmpty)
        let requests = await client.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/oauth/usage", "/api/oauth/usage"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testClaudeNeverEntersCodexAggregateAndCachedAccountsDoNotContribute() throws {
        let usage = try json(#"{"seven_day":{"utilization":20}}"#)
        let claude = try LiveClaudeIntegration.normalize(usage, configuration: config, now: .now)
        var stale = claude; stale.id = "claude-stale"; stale.isStale = true
        var codex = claude; codex.id = "codex-a"; codex.integration = .codex
        codex.payload = .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: 90, durationMinutes: 10080)]))
        XCTAssertEqual(CompactSummary(sources: [claude, stale, codex]).weeklyQuota?.remainingPercent, 10)
        let aggregate = try XCTUnwrap(QuotaAggregate.mainReadings(sources: [claude, stale, codex], integration: .claude).first)
        XCTAssertEqual(aggregate.remainingPercent, 80)
        XCTAssertEqual(aggregate.accountCount, 1)
        XCTAssertEqual(aggregate.totalAccounts, 2)
    }
    func testFreshLoginUsesUniquePKCEAndOnlyUsageScope() throws {
        let first = try ClaudeLoginFlow(), second = try ClaudeLoginFlow()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.verifier.count, 43)
        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: first.url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(parameters["scope"], "user:profile")
        XCTAssertEqual(parameters["code_challenge_method"], "S256")
        XCTAssertNotEqual(parameters["code_challenge"], first.verifier)
        XCTAssertEqual(first.url.host, "claude.com")
    }
    func testWrongStateDoesNotSendCodeToServer() async throws {
        let flow = try ClaudeLoginFlow(), client = ClaudeFixtureHTTP([])
        do { _ = try await flow.exchange(code: "fixture-code#wrong-state", client: client); XCTFail("Expected state rejection") } catch {}
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testCodeExchangeAndProfileIdentification() async throws {
        let flow = try ClaudeLoginFlow()
        let client = ClaudeFixtureHTTP([
            (200, #"{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600,"scope":"user:profile"}"#),
            (200, #"{"account":{"uuid":"fixture-user","email":"fixture@example.com"},"organization":{"organization_type":"claude_max"}}"#),
        ])
        let tokens = try await flow.exchange(code: "fixture-code#\(flow.state)", client: client)
        let identified = try await LiveClaudeIntegration.identify(tokens, client: client)
        XCTAssertEqual(identified["accountID"], "fixture-user")
        XCTAssertEqual(identified["email"], "fixture@example.com")
        let requests = await client.requests
        XCTAssertEqual(requests[0].url?.host, "platform.claude.com")
        let body = try JSONValue.decode(XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["code_verifier"].string, flow.verifier)
        XCTAssertEqual(requests[1].url?.path, "/api/oauth/profile")
    }
    func testAutomaticRefreshPersistsRotationAndOnlyReadsUsage() async throws {
        let secrets = ClaudeMemoryCredentials()
        let reference = UUID().uuidString
        try secrets.save(["accessToken": "expired", "refreshToken": "fixture-refresh", "expiresAt": "0", "scope": "user:profile", "email": "fixture@example.com"], reference: reference)
        var source = config; source.credentialReference = reference
        let client = ClaudeFixtureHTTP([
            (200, #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"scope":"user:profile"}"#),
            (200, #"{"five_hour":{"utilization":15},"seven_day":{"utilization":45}}"#),
        ])
        let readings = try await LiveClaudeIntegration(configuration: source, client: client, secrets: secrets).fetchSources()
        XCTAssertEqual(readings.first?.quota?.weeklyWindow?.remainingPercent, 55)
        XCTAssertEqual(try secrets.read(reference: reference)["refreshToken"], "rotated")
        let requests = await client.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "GET"])
        XCTAssertEqual(requests[1].url?.path, "/api/oauth/usage")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
    }
    func testNoLoginDoesNotReadAnyTerminalCredentialOrMakeRequests() async throws {
        let client = ClaudeFixtureHTTP([])
        do { _ = try await LiveClaudeIntegration(configuration: config, client: client, secrets: ClaudeMemoryCredentials()).fetchSources(); XCTFail("Expected missing login") } catch {}
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testUnauthorizedUsageRenewsOnlyThisGrantAndRetriesOnce() async throws {
        let secrets = ClaudeMemoryCredentials(), reference = UUID().uuidString
        try secrets.save(["accessToken": "rejected", "refreshToken": "own-refresh", "expiresAt": String(Date.now.timeIntervalSince1970 + 3600), "scope": "user:profile"], reference: reference)
        try secrets.save(["accessToken": "untouched-sibling"], reference: "sibling")
        var source = config; source.credentialReference = reference
        let client = ClaudeFixtureHTTP([
            (401, #"{"error":"not exposed"}"#),
            (200, #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"scope":"user:profile"}"#),
            (200, #"{"seven_day":{"utilization":75}}"#),
        ])
        let result = try await LiveClaudeIntegration(configuration: source, client: client, secrets: secrets).fetchSources()
        XCTAssertEqual(result.first?.quota?.weeklyWindow?.remainingPercent, 25)
        XCTAssertEqual(try secrets.read(reference: "sibling")["accessToken"], "untouched-sibling")
        let requests = await client.requests
        XCTAssertEqual(requests.count, 3)
    }
    func testConcurrentExpiryChecksShareOneRefresh() async throws {
        let secrets = ClaudeMemoryCredentials(), reference = UUID().uuidString
        try secrets.save(["accessToken": "expired", "refreshToken": "own-refresh", "expiresAt": "0", "scope": "user:profile"], reference: reference)
        let client = ClaudeFixtureHTTP([(200, #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600,"scope":"user:profile"}"#)])
        let manager = ClaudeTokenRefresh()
        let results = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<10 {
                group.addTask { try await manager.validCredentials(reference: reference, secrets: secrets, client: client)["accessToken"] }
            }
            var tokens: [String?] = []
            for try await token in group { tokens.append(token) }
            return tokens
        }
        XCTAssertEqual(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0 == "renewed" })
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testSeparateAccountsAndDuplicateRejectionPreserveConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let secrets = ClaudeMemoryCredentials()
        let repo = ConnectionRepository(url: url, secrets: secrets)
        try IntegrationConfiguration(sources: []).save(to: url)
        var first = ConnectionDraft(integration: .claude); first.label = "One"
        var second = ConnectionDraft(integration: .claude); second.label = "Two"
        let a = try repo.save(first), b = try repo.save(second)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(first.startsClaudeLogin)
        XCTAssertNil(a.codexHome)
        let values = ["accountID": "identity-one", "email": "one@example.com", "accessToken": "fixture-secret-one"]
        try ClaudeOAuth.save(values, sourceID: a.id, originalReference: nil, repository: repo)
        XCTAssertThrowsError(try ClaudeOAuth.save(values, sourceID: b.id, originalReference: nil, repository: repo))
        try ClaudeOAuth.save(["accountID": "identity-two", "accessToken": "fixture-secret-two"], sourceID: b.id, originalReference: nil, repository: repo)
        let saved = try repo.load()
        XCTAssertNotEqual(saved.sources[0].credentialReference, saved.sources[1].credentialReference)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("fixture-secret"))
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try ClaudeOAuth.save(values, sourceID: a.id, originalReference: "stale-reference", repository: repo))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testFailedConfigurationSaveRollsBackOnlyNewGrant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json"), secrets = ClaudeMemoryCredentials()
        var source = config; source.credentialReference = "old"
        try secrets.save(["accessToken": "original"], reference: "old")
        try IntegrationConfiguration(sources: [source]).save(to: url)
        var repo = ConnectionRepository(url: url, secrets: secrets)
        repo.saveConfiguration = { _, _ in throw IntegrationError.configuration("Fixture failure") }
        XCTAssertThrowsError(try ClaudeOAuth.save(["accessToken": "replacement"], sourceID: source.id, originalReference: "old", repository: repo))
        XCTAssertEqual(secrets.references, ["old"])
        XCTAssertEqual(try repo.load().sources.first?.credentialReference, "old")
    }
}

@available(macOS 14.0, *)
private actor ClaudeFixtureHTTP: HTTPClient {
    var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw IntegrationError.unavailable("No fixture response") }
        let (status, body) = responses.removeFirst()
        return HTTPResponse(status: status, data: Data(body.utf8))
    }
}

@available(macOS 14.0, *)
private final class ClaudeMemoryCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    var references: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
    func read(reference: String) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[reference] else { throw IntegrationError.authentication("Missing fixture") }; return value
    }
    func save(_ value: [String: String], reference: String) throws { lock.lock(); defer { lock.unlock() }; values[reference] = value }
    func update(_ value: [String: String], reference: String) throws { try save(value, reference: reference) }
    func delete(reference: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference) }
}
