@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class DaytonaBillingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_142_400)
    private func json(_ text: String) throws -> JSONValue { try .decode(Data(text.utf8)) }

    func testWalletUsesCentsAndDoesNotDoubleCountFreeAndPaidBalances() throws {
        let wallet = try json(#"{"totalSpentThisMonthCents":12345,"balanceCents":6500,"freeCreditsBalanceCents":1000,"paidCreditsBalanceCents":5500,"totalAmountDueThisMonthCents":9999}"#)
        let result = try DaytonaBilling.normalize(wallet: wallet, now: now)
        XCTAssertEqual(result.balanceUSD, 65, accuracy: 0.00001)
        XCTAssertEqual(try DaytonaBilling.normalize(wallet: json(#"{"balanceCents":0}"#), now: now).balanceUSD, 0)
        XCTAssertThrowsError(try DaytonaBilling.normalize(wallet: json(#"{"totalSpentThisMonthCents":-1}"#), now: now))
    }

    func testAnalyticsSandboxBreakdownUsesDollarsAndDeduplicates() throws {
        let usage = try json(#"[{"sandboxId":"a","totalPrice":123.45},{"sandboxId":"a","totalPrice":123.45},{"sandboxId":"b","totalPrice":2.5}]"#)
        let result = try DaytonaAnalytics.sandboxes(usage)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.spent, 123.45)
        XCTAssertThrowsError(try DaytonaAnalytics.sandboxes(json(#"[{"sandboxId":"a","totalPrice":-1}]"#)))
    }

    func testDeniedBillingDoesNotFallBackToAnotherVersionOrMakeMutations() async throws {
        let client = BillingFixture([reply(401)])
        do {
            _ = try await DaytonaBilling(client: client).fetch(organization: "org-1", headers: ["Authorization": "Bearer fixture"], now: now)
            XCTFail("Denied access should be reported")
        } catch HTTPFailure.status(let code) { XCTAssertEqual(code, 401) }
        let requests = await client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.host, "billing.app.daytona.io")
        XCTAssertEqual(requests[0].url?.path, "/v2/organization/org-1/wallet")
    }

    func testLegacyFallbackIsOnlyForMissingVersionAndReadsWalletOnly() async throws {
        let client = BillingFixture([reply(404), reply(200, #"{"totalSpentThisMonthCents":1000,"balanceCents":2000}"#)])
        let result = try await DaytonaBilling(client: client).fetch(organization: "org-1", headers: [:], now: now)
        XCTAssertEqual(result.balanceUSD, 20)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.path, "/organization/org-1/wallet")
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testBillingRejectsPathInjectionBeforeRequest() async {
        let client = BillingFixture([])
        do {
            _ = try await DaytonaBilling(client: client).fetch(organization: "../other", headers: [:], now: now)
            XCTFail("Unsafe identity should be rejected")
        } catch {}
        let requests = await client.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInventoryIncludesStoppedAndArchivedCountsWithoutCallingThemRunning() throws {
        let rows = try json(#"[{"id":"a","state":"started"},{"id":"a","state":"started"},{"id":"b","state":"stopped"},{"id":"c","state":"archived"}]"#).array!
        let result = try LiveDaytonaIntegration.normalize(sandboxes: rows, usage: nil,
            configuration: SourceConfiguration(id: "a", integration: .daytona, label: "A"), now: now)
        XCTAssertEqual(result.compute?.resources.count, 1)
        XCTAssertEqual(result.compute?.inventoryCounts, ["started": 1, "stopped": 1, "archived": 1])
        XCTAssertNil(result.compute?.spent)
    }

    func testFullDaytonaAdapterConnectsIndependentCapabilitiesWithAcceptedCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-daytona-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent(".env")
        try Data("DAYTONA_API_KEY=fixture-only\n".utf8).write(to: credential)
        var config = SourceConfiguration(id: "daytona", integration: .daytona, label: "Fixture")
        config.credentialFile = credential.path
        let client = BillingFixture([
            reply(200, #"{"items":[],"nextCursor":null}"#),
            reply(200, #"{"organizationId":"org-1","permissions":["read:limits","read:billing"]}"#),
            reply(200, #"{"regionUsage":[{"regionId":"us","sandboxClass":"small","currentCpuUsage":0,"totalCpuQuota":10}]}"#),
            reply(200, #"{"totalPrice":12.34,"sandboxCount":1}"#),
            reply(200, #"[{"sandboxId":"sandbox-1","totalPrice":12.34}]"#),
            reply(200, "[]"),
            reply(200, #"{"totalSpentThisMonthCents":999999,"balanceCents":5000}"#),
        ])
        let source = try await LiveDaytonaIntegration(configuration: config, client: client).fetchSources()[0]
        XCTAssertFalse(source.hasLimitedAccess)
        XCTAssertEqual(source.capabilities?.count, 4)
        XCTAssertEqual(source.compute?.spent, 12.34)
        XCTAssertEqual(source.compute?.accountBalanceUSD, 50)
        XCTAssertEqual(source.compute?.billingBreakdown.first?.name, "sandbox-1")
        XCTAssertEqual(source.compute?.providerCapacity.first?.limit, 10)
        let requests = await client.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.query?.contains("fixture-only") != true })
    }

    private func reply(_ code: Int, _ text: String = "{}") -> HTTPResponse {
        HTTPResponse(status: code, data: Data(text.utf8), retryAfter: nil)
    }
}

@available(macOS 14.0, *)
private actor BillingFixture: HTTPClient {
    var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw IntegrationError.invalidResponse("Unexpected fixture request") }
        return responses.removeFirst()
    }
}
