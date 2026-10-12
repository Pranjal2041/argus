import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class OriginalHTTPClientTests: XCTestCase {
    private let url = URL(string: "https://provider.example/usage")!

    func testTransientRateLimitAndServerFailureRetryInsideTheSameRefresh() async throws {
        for status in [429, 500, 503] {
            let client = ScriptedUsageHTTP([status, 200])
            let value = try await client.get(url, headers: ["Authorization": "Bearer fixture"])
            XCTAssertEqual(value["value"].int, 2)
            let requests = await client.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Usage/0.2.0" })
        }
    }

    func testFailedRefreshDoesNotCreateAPersistentCooldown() async throws {
        for status in [429, 503] {
            let client = ScriptedUsageHTTP([status, status, 200])
            do { _ = try await client.get(url, headers: [:]); XCTFail("Expected the second failure") }
            catch HTTPFailure.status(let received) { XCTAssertEqual(received, status) }
            // No clock advance, controller restart, or new HTTP client is needed.
            let recovered = try await client.get(url, headers: [:])
            XCTAssertEqual(recovered["value"].int, 3)
            let count = await client.requests.count
            XCTAssertEqual(count, 3)
        }
    }

    func testAuthenticationAndPermissionFailuresAreNotRetried() async throws {
        for status in [401, 403] {
            let client = ScriptedUsageHTTP([status, 200])
            do { _ = try await client.get(url, headers: [:]); XCTFail("Expected rejection") }
            catch HTTPFailure.status(let received) { XCTAssertEqual(received, status) }
            let count = await client.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testEachAccountAndRefreshUsesItsOwnNewResponse() async throws {
        let client = ScriptedUsageHTTP([200, 200, 200])
        let first = try await client.get(url, headers: ["Authorization": "Bearer first"])
        let second = try await client.get(url, headers: ["Authorization": "Bearer second"])
        let next = try await client.get(url, headers: ["Authorization": "Bearer first"])
        XCTAssertEqual([first["value"].int, second["value"].int, next["value"].int], [1, 2, 3])
        let headers = await client.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(headers, ["Bearer first", "Bearer second", "Bearer first"])
    }

    func testInsecureProviderURLIsRejectedBeforeTransport() async throws {
        let client = ScriptedUsageHTTP([])
        do { _ = try await client.get(URL(string: "http://provider.example")!, headers: [:]); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is IntegrationError) }
        let count = await client.requests.count
        XCTAssertEqual(count, 0)
    }
}

@available(macOS 14.0, *)
private actor ScriptedUsageHTTP: HTTPClient {
    private var statuses: [Int]
    private(set) var requests: [URLRequest] = []
    init(_ statuses: [Int]) { self.statuses = statuses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !statuses.isEmpty else { throw IntegrationError.invalidResponse("Fixture exhausted") }
        return HTTPResponse(status: statuses.removeFirst(), data: Data("{\"value\":\(requests.count)}".utf8), retryAfter: 0)
    }
}
