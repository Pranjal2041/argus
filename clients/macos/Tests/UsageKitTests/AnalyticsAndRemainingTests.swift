@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class AnalyticsAndRemainingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_142_400)
    private func json(_ text: String) throws -> JSONValue { try .decode(Data(text.utf8)) }
    private func reply(_ code: Int, _ text: String = "{}") -> HTTPResponse {
        HTTPResponse(status: code, data: Data(text.utf8), retryAfter: nil)
    }

    func testRemainingQuotaIsInvertedAndClamped() {
        for (used, remaining) in [(0.0, 100.0), (100, 0), (63, 37), (130, 0), (-5, 100)] {
            XCTAssertEqual(QuotaWindow(label: "Weekly", usedPercent: used).remainingPercent, remaining)
        }
    }

    func testAggregateIncludesAllFiveAndFutureAccountsWithoutPooling() {
        var sources = [63.0, 100, 30, 20, 100].enumerated().map { account("\($0.offset)", used: $0.element) }
        let first = QuotaAggregate.readings(sources: sources)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].remainingPercent, 37.4, accuracy: 0.0001)
        XCTAssertEqual(first[0].accountCount, 5)
        sources.append(account("sixth", used: 0))
        let next = QuotaAggregate.readings(sources: sources)
        XCTAssertEqual(next[0].remainingPercent, 287.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(next[0].totalAccounts, 6)
    }

    func testAggregateExcludesStaleAndMissingAccountsWithCoverage() {
        var stale = account("cached", used: 100); stale.isStale = true
        let missing = UsageSource(id: "missing", integration: .codex, account: "Missing", observedAt: now,
            payload: .unavailable(UnavailableUsage(title: "Sign in", message: "Not connected")))
        let result = QuotaAggregate.readings(sources: [account("live", used: 20), stale, missing])
        XCTAssertEqual(result[0].remainingPercent, 80)
        XCTAssertEqual(result[0].accountCount, 1)
        XCTAssertEqual(result[0].totalAccounts, 3)
        XCTAssertTrue(QuotaAggregate.readings(sources: [stale, missing]).isEmpty)
    }

    func testAggregateKeepsDurationsAndModelBucketsSeparateAndDeduplicatesSources() {
        var source = account("one", used: 25)
        var quota = source.quota!
        quota.windows.append(QuotaWindow(label: "5-hour", usedPercent: 80, durationMinutes: 300))
        quota.additionalBuckets = [QuotaBucket(id: "spark", name: "Spark", windows: [QuotaWindow(label: "Weekly", usedPercent: 5, durationMinutes: 10080)])]
        source.payload = .quota(quota)
        let result = QuotaAggregate.readings(sources: [source, source])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first { $0.id == "main:300" }?.remainingPercent, 20)
        XCTAssertEqual(result.first { $0.id == "main:10080" }?.remainingPercent, 75)
        XCTAssertEqual(result.first { $0.id == "spark:10080" }?.remainingPercent, 95)
        XCTAssertTrue(result.allSatisfy { $0.accountCount == 1 && $0.totalAccounts == 1 })
    }

    func testMainOverviewAggregateExcludesSecondaryModelBuckets() {
        var source = account("one", used: 63)
        var quota = source.quota!
        quota.additionalBuckets = [QuotaBucket(id: "spark", name: "Spark", windows: [QuotaWindow(label: "Weekly", usedPercent: 0, durationMinutes: 10080)]),
                                  QuotaBucket(id: "gpt-reserve", name: "gpt-reserve", windows: [QuotaWindow(label: "Weekly", usedPercent: 0, durationMinutes: 10080)])]
        source.payload = .quota(quota)
        let result = QuotaAggregate.mainReadings(sources: [source])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].remainingPercent, 37)
        XCTAssertEqual(result[0].id, "main:10080")
        XCTAssertEqual(source.quota?.additionalBuckets.count, 2, "Model data remains available in account details")
    }

    func testOverviewHidesUnavailableSourcesButKeepsPartialRealReadings() {
        let missing = UsageSource(id: "missing", integration: .openaiAPI, account: "Missing", observedAt: now,
            payload: .unavailable(UnavailableUsage(title: "Access required", message: "Not connected")))
        let partial = UsageSource(id: "daytona", integration: .daytona, account: "Personal", observedAt: now,
            payload: .compute(ComputeUsage(resources: [], capacity: nil, spent: 12.34, budget: nil, dailySpend: [])))
        let noMainQuota = UsageSource(id: "empty", integration: .codex, account: "Empty", observedAt: now,
            payload: .quota(QuotaUsage(windows: [])))
        XCTAssertFalse(missing.hasOverviewReading)
        XCTAssertFalse(noMainQuota.hasOverviewReading)
        XCTAssertTrue(partial.hasOverviewReading)
        XCTAssertNil(partial.compute?.accountBalanceUSD)
        XCTAssertTrue(account("known", used: 100).hasOverviewReading, "A reported zero remaining quota is real data, not unavailable")
    }

    func testAnalyticsChartGroupsUTCPricesWithoutInferringGPUOrMissingDays() throws {
        let data = try json(#"[{"time":"2026-09-01T00:00:00Z","cpuPrice":8.064,"ramPrice":16.2,"diskPrice":0.43848},{"time":"2026-09-01T01:00:00Z","cpuPrice":1,"ramPrice":2,"diskPrice":3},{"time":"2026-08-31T23:00:00Z","cpuPrice":999,"ramPrice":0,"diskPrice":0}]"#)
        let result = try DaytonaAnalytics.chart(data, from: UsageCalendar.monthStart(now), to: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].value, 30.70248, accuracy: 0.00001)
        XCTAssertEqual(UsageCalendar.dateString(result[0].date), "2026-09-01")
        XCTAssertThrowsError(try DaytonaAnalytics.chart(json(#"[{"time":"2026-09-01T00:00:00Z","cpuPrice":1}]"#), from: UsageCalendar.monthStart(now), to: now))
    }

    func testAnalyticsFallbackUsesSandboxTotalWhenAggregateFailsAndChartDoesNotReplaceTotal() async throws {
        let client = AnalyticsFixture([reply(401), reply(200, #"[{"sandboxId":"a","totalPrice":1667.28}]"#),
            reply(200, #"[{"time":"2026-09-01T00:00:00Z","cpuPrice":1,"ramPrice":2,"diskPrice":3}]"#)])
        let result = try await DaytonaAnalytics(client: client).fetch(organization: "org-1", headers: ["Authorization": "Bearer fixture"], now: now)
        XCTAssertEqual(result.spentUSD, 1667.28)
        XCTAssertEqual(result.dailySpend, [6])
        XCTAssertEqual(result.sandboxCount, 1)
        XCTAssertTrue(result.notes.contains { $0.contains("aggregate endpoint") })
        let requests = await client.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "analytics.app.daytona.io" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Daytona-Organization-ID") == "org-1" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.query?.contains("fixture") != true })
    }

    func testAnalyticsTotalSurvivesDetailAndChartFailure() async throws {
        let client = AnalyticsFixture([reply(200, #"{"totalPrice":12.34,"sandboxCount":2}"#), reply(403), reply(403)])
        let reading = try await DaytonaAnalytics(client: client).fetch(organization: "org-1", headers: [:], now: now)
        XCTAssertEqual(reading.spentUSD, 12.34)
        XCTAssertEqual(reading.notes.count, 2)
        XCTAssertTrue(reading.dailySpend.isEmpty)
    }

    func testAnalyticsRejectsPathInjectionAndInvalidSpend() async throws {
        let client = AnalyticsFixture([])
        do { _ = try await DaytonaAnalytics(client: client).fetch(organization: "../bad", headers: [:], now: now); XCTFail() } catch {}
        let requests = await client.requests; XCTAssertTrue(requests.isEmpty)
        let invalid = AnalyticsFixture([reply(200, #"{"totalPrice":-1}"#), reply(200, "[]")])
        do { _ = try await DaytonaAnalytics(client: invalid).fetch(organization: "org", headers: [:], now: now); XCTFail() } catch {}
    }

    func testWalletRejectionCannotHideLiveSpendingOrClaimKeyNeedsPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-analytics-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent(".env")
        try Data("DAYTONA_API_KEY=fixture-only\n".utf8).write(to: credential)
        var config = SourceConfiguration(id: "daytona", integration: .daytona, label: "Fixture")
        config.credentialFile = credential.path
        let client = AnalyticsFixture([
            reply(200, #"{"items":[],"nextCursor":null}"#), reply(200, #"{"organizationId":"org-1"}"#), reply(200, #"{"regionUsage":[]}"#),
            reply(200, #"{"totalPrice":1667.28,"sandboxCount":266}"#), reply(200, #"[{"sandboxId":"a","totalPrice":1667.28}]"#), reply(200, "[]"), reply(401)
        ])
        let source = try await LiveDaytonaIntegration(configuration: config, client: client).fetchSources()[0]
        XCTAssertEqual(source.compute?.spent, 1667.28)
        XCTAssertEqual(source.compute?.periodSandboxCount, 266)
        XCTAssertNil(source.compute?.accountBalanceUSD)
        XCTAssertFalse(source.hasLimitedAccess)
        XCTAssertTrue(source.hasUnavailableCapabilities)
        XCTAssertEqual(source.capabilities?.first { $0.id == "spending" }?.status, .available)
        XCTAssertEqual(source.capabilities?.first { $0.id == "wallet" }?.isOptional, true)
        XCTAssertTrue(source.capabilities?.first { $0.id == "wallet" }?.message.contains("does not mean your key lacks full access") == true)
    }

    private func account(_ id: String, used: Double) -> UsageSource {
        UsageSource(id: id, integration: .codex, account: id, observedAt: now,
            payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: used, durationMinutes: 10080)])))
    }
}

@available(macOS 14.0, *)
private actor AnalyticsFixture: HTTPClient {
    var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw IntegrationError.invalidResponse("Unexpected fixture request") }
        return responses.removeFirst()
    }
}
