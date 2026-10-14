import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageTransportDiagnosticTests: XCTestCase {
    func testHTTPDiagnosticsPreserveRequestsAndResponsesWithoutRecordingSecrets() async throws {
        let trace = UsageCollectionTrace(), base = DiagnosticFixtureHTTP()
        let client = UsageDiagnosticHTTPClient(base: base, trace: trace)
        var request = URLRequest(url: URL(string: "https://provider.example/private?token=secret-query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer secret-header", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("secret-body".utf8)
        let result = try await client.send(request)
        XCTAssertEqual(result.status, 429)
        XCTAssertEqual(result.retryAfter, 47)
        XCTAssertEqual(result.data, Data("secret-response".utf8))
        let received = await base.request
        XCTAssertEqual(received, request)
        let events = await trace.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].destination, "provider.example")
        XCTAssertEqual(events[0].status, 429)
        XCTAssertEqual(events[0].retryAfterSeconds, 47)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("private"))
    }

    func testCommandDiagnosticsPreserveInvocationWithoutRecordingArgumentsOrEnvironment() async throws {
        let trace = UsageCollectionTrace(), base = DiagnosticFixtureCommand()
        let runner = UsageDiagnosticCommandRunner(base: base, trace: trace)
        let output = try await runner.run(executable: "/private/bin/provider", arguments: ["secret-argument"],
            environment: ["ACCESS_TOKEN": "secret-environment"], timeout: 35)
        XCTAssertEqual(output.status, 7)
        XCTAssertEqual(output.stdout, Data("secret-output".utf8))
        let passed = await base.passed
        XCTAssertTrue(passed)
        let events = await trace.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].destination, "provider")
        XCTAssertEqual(events[0].status, 7)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("private"))
    }

    func testTransportFailuresPreserveCodesWithoutRecordingErrorMessages() async throws {
        let trace = UsageCollectionTrace()
        let client = UsageDiagnosticHTTPClient(base: DiagnosticFailingHTTP(), trace: trace)
        do {
            _ = try await client.send(URLRequest(url: URL(string: "https://other.example/private")!))
            XCTFail("Expected the underlying transport error")
        } catch {
            XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut)
        }
        let events = await trace.events
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].status)
        XCTAssertEqual(events[0].errorCode, NSURLErrorTimedOut)
        XCTAssertEqual(events[0].errorDomain, NSURLErrorDomain)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("private"))
    }
}

@available(macOS 14.0, *)
private struct DiagnosticFailingHTTP: HTTPClient {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "secret-response"])
    }
}

@available(macOS 14.0, *)
private actor DiagnosticFixtureHTTP: HTTPClient {
    private(set) var request: URLRequest?
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        self.request = request
        return .init(status: 429, data: Data("secret-response".utf8), retryAfter: 47)
    }
}

@available(macOS 14.0, *)
private actor DiagnosticFixtureCommand: CommandRunning {
    private(set) var passed = false
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        passed = executable == "/private/bin/provider" && arguments == ["secret-argument"] &&
            environment == ["ACCESS_TOKEN": "secret-environment"] && timeout == 35
        return .init(status: 7, stdout: Data("secret-output".utf8), stderr: Data("secret-error".utf8))
    }
}
