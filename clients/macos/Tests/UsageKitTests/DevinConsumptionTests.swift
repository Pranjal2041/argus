import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class DevinConsumptionTests: XCTestCase {
    private let configuration = SourceConfiguration(id: "devin", integration: .devin, label: "Work", accountIdentity: "reader@example.test")
    private let account = DevinAccount(email: "reader@example.test", plan: "Enterprise")
    private var now: Date { JSONValue.string("2026-10-02T12:00:00Z").date! }

    private func response(_ value: String = "2331.999656", limit: String = "null") throws -> JSONValue {
        try JSONValue.decode(Data("""
        {"consumption":[
          {"start":"2026-08-15T00:00:00-08:00","end":"2026-09-15T00:00:00-08:00","acus_consumed":999},
          {"start":"2026-10-15T00:00:00-08:00","end":"2026-11-15T00:00:00-08:00","acus_consumed":777},
          {"start":"2026-09-15T00:00:00-08:00","end":"2026-10-15T00:00:00-08:00","acus_consumed":\(value),"acu_limit":\(limit)}
        ]}
        """.utf8))
    }

    func testCurrentConsumptionDoesNotRequireOrDeriveLimits() throws {
        for limit in ["null", "0", "11200"] {
            let source = try DevinConsumption.normalize(response(limit: limit), account: account, configuration: configuration, now: now)
            let usage = try XCTUnwrap(source.consumption)
            XCTAssertEqual(usage.used, 2331.999656, accuracy: 0.00000001)
            XCTAssertEqual(usage.formattedAmount, "2,332")
            XCTAssertEqual(usage.unit, "ACUs")
            XCTAssertEqual(usage.period?.label, "Sep 15 – Oct 14")
            XCTAssertEqual(source.accountIdentity, account.email)
            XCTAssertNil(source.quota)
        }
    }

    func testMissingInvalidOrAmbiguousTotalsDoNotBecomeZeroOrPreviousPeriod() throws {
        for value in ["null", "-1", "true", "\"NaN\"", "\"Infinity\""] {
            XCTAssertThrowsError(try DevinConsumption.normalize(response(value), account: account, configuration: configuration, now: now))
        }
        let zero = try DevinConsumption.normalize(response("0"), account: account, configuration: configuration, now: now)
        XCTAssertEqual(zero.consumption?.used, 0)
        let payload = try response()
        XCTAssertThrowsError(try DevinConsumption.normalize(payload, account: account, configuration: configuration, now: now.addingTimeInterval(365 * 86400)))
        var cycles = payload["consumption"].array!
        cycles.append(cycles.last!)
        XCTAssertThrowsError(try DevinConsumption.normalize(.object(["consumption": .array(cycles)]), account: account, configuration: configuration, now: now))
        XCTAssertThrowsError(try DevinConsumption.normalize(payload, account: DevinAccount(email: "different@example.test"), configuration: configuration, now: now))
    }

    func testStandaloneCLITotalRemainsUsefulWhenQuotaIsUnavailable() throws {
        for line in ["50 ACUs consumed", "ACUs used: 50", "50 ACUs used", "50 of 0 ACUs"] {
            let source = try LiveDevinIntegration.normalize("Logged in\nEmail: reader@example.test\n\(line)\nFailed to fetch quota", configuration: configuration, now: now)
            XCTAssertEqual(source.consumption?.used, 50)
            XCTAssertNil(source.consumption?.period)
            XCTAssertNil(source.quota)
        }
        for line in ["-1 ACUs consumed", "Session cost: 50 ACUs", "ACUs consumed: unknown"] {
            XCTAssertThrowsError(try LiveDevinIntegration.normalize("Logged in\nEmail: reader@example.test\n\(line)", configuration: configuration, now: now))
        }
    }

    func testPrivateCredentialRecordKeepsDeploymentAndRejectsUnsafeFields() throws {
        let credentials = try DevinAPICredentials.parse("""
        # The CLI's flat TOML format
        windsurf_api_key = 'fixture-key' # comment
        devin_api_url = "https://deployment.example.test/api"
        dangerously_skip_plugin_authentication = false
        """)
        XCTAssertEqual(credentials.apiKey, "fixture-key")
        XCTAssertEqual(credentials.baseURL.absoluteString, "https://deployment.example.test/api")
        for text in [
            "windsurf_api_key = 'fixture'\ndevin_api_url = 'http://example.test'",
            "windsurf_api_key = 'fixture'\ndevin_api_url = 'https://user:password@example.test'",
            "windsurf_api_key = 'fixture'\ndevin_api_url = 'https://example.test?token=wrong'",
            "windsurf_api_key = 'fixture'\nwindsurf_api_key = 'duplicate'\ndevin_api_url = 'https://example.test'",
            "windsurf_api_key = \"newline\\nkey\"\ndevin_api_url = 'https://example.test'",
            "[unrelated]\nwindsurf_api_key = 'fixture'\ndevin_api_url = 'https://example.test'"
        ] { XCTAssertThrowsError(try DevinAPICredentials.parse(text)) }
    }

    func testCredentialReaderDoesNotFollowAFileOutsideThePrivateProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("argus-consumption-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try AccountProfile.create(in: directory)
        let source = directory.appendingPathComponent("outside.toml")
        try Data("windsurf_api_key = 'fixture'\ndevin_api_url = 'https://example.test'".utf8).write(to: source)
        let file = profile.root.appendingPathComponent("data/devin/credentials.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source)
        XCTAssertThrowsError(try DevinAPICredentials.load(profile))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: source, to: file)
        XCTAssertEqual(try DevinAPICredentials.load(profile).apiKey, "fixture")
    }

    func testEachAccountFetchesItsOwnReadOnlyConsumptionEndpoint() async throws {
        let client = ConsumptionHTTPFixture(status: 200)
        for label in ["public", "enterprise"] {
            var source = configuration; source.loginProfile = "/fixture/\(label)"
            let result = try await LiveDevinIntegration(configuration: source, executable: "/usr/bin/true",
                runner: ConsumptionStatusFixture(), client: client, readCredentials: { profile in
                    let label = profile.root.lastPathComponent
                    return DevinAPICredentials(apiKey: "fixture-" + label, baseURL: URL(string: "https://\(label).example.test")!)
                }).fetchSources()
            XCTAssertEqual(result.first?.consumption?.used, 12.5)
            XCTAssertEqual(result.first?.accountIdentity, account.email)
        }
        let requests = await client.requests
        XCTAssertEqual(requests.map { $0.url!.host! }, ["public.example.test", "enterprise.example.test"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer fixture-public", "Bearer fixture-enterprise"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/personal-analytics/consumption" && $0.url?.query == nil && $0.httpBody == nil })
    }

    func testIdentityAndPermissionsAreCheckedWithoutBorrowingAnotherAccount() async throws {
        var source = configuration; source.loginProfile = "/fixture/account"
        let client = ConsumptionHTTPFixture(status: 403)
        var adapter = LiveDevinIntegration(configuration: source, executable: "/usr/bin/true",
            runner: ConsumptionStatusFixture(), client: client,
            readCredentials: { _ in DevinAPICredentials(apiKey: "fixture", baseURL: URL(string: "https://example.test")!) })
        do { _ = try await adapter.fetchSources(); XCTFail("A denied analytics permission must remain denied") }
        catch let error as IntegrationError { XCTAssertEqual(error.title, "Access required"); XCTAssertFalse(error.needsAuthentication) }
        adapter.runner = ConsumptionStatusFixture(email: "different@example.test")
        do { _ = try await adapter.fetchSources(); XCTFail("The wrong account must never supply usage") }
        catch let error as IntegrationError { XCTAssertTrue(error.needsAuthentication) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1, "Identity mismatch must stop before an HTTP request")
    }

    func testSelfServeQuotaRemainsAvailableWhenConsumptionIsNotSupported() async throws {
        var source = configuration; source.loginProfile = "/fixture/account"
        let result = try await LiveDevinIntegration(configuration: source, executable: "/usr/bin/true",
            runner: ConsumptionStatusFixture(extra: "Daily: 30% remaining"), client: ConsumptionHTTPFixture(status: 403),
            readCredentials: { _ in DevinAPICredentials(apiKey: "fixture", baseURL: URL(string: "https://example.test")!) }).fetchSources()
        XCTAssertEqual(result.first?.quota?.windows.first?.remainingPercent, 30)
        XCTAssertNil(result.first?.consumption)
    }

    func testConfiguredAccountConsumptionReadOnlyProbe() async throws {
        guard ProcessInfo.processInfo.environment["UT_DEVIN_USAGE_PROBE"] == "1" else { throw XCTSkip("Opt-in read-only request using an explicitly saved Devin account") }
        let config = try IntegrationConfiguration.load()
        let source = try XCTUnwrap(config.sources.first { $0.integration == .devin && $0.enabled && $0.accountProfile != nil })
        let result = try await LiveDevinIntegration(configuration: source, executable: config.executables.devin).fetchSources()
        let reading = try XCTUnwrap(result.first)
        XCTAssertEqual(reading.accountIdentity, source.accountIdentity)
        let usage = try XCTUnwrap(reading.consumption)
        XCTAssertTrue(usage.hasReading)
        XCTAssertEqual(usage.unit, "ACUs")
        XCTAssertNotNil(usage.period)
        XCTAssertNil(reading.quota)
    }
}

@available(macOS 14.0, *)
private struct ConsumptionStatusFixture: CommandRunning {
    var email = "reader@example.test"
    var extra = ""
    func run(executable: String, arguments: [String], environment: [String : String], timeout: Double) async throws -> CommandOutput {
        XCTAssertEqual(arguments, ["auth", "status"])
        return CommandOutput(status: 0, stdout: Data("Logged in\nEmail: \(email)\nPlan: Enterprise\n\(extra)".utf8), stderr: Data())
    }
}

@available(macOS 14.0, *)
private actor ConsumptionHTTPFixture: HTTPClient {
    let status: Int
    var requests: [URLRequest] = []
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let format = ISO8601DateFormatter(), now = Date.now
        let body = """
        {"consumption":[{"start":"\(format.string(from: now.addingTimeInterval(-86400)))","end":"\(format.string(from: now.addingTimeInterval(86400)))","acus_consumed":12.5,"acu_limit":null}]}
        """
        return HTTPResponse(status: status, data: Data(body.utf8), retryAfter: nil)
    }
}
