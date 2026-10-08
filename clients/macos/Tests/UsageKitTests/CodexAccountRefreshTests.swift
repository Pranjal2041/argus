import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class CodexAccountRefreshTests: XCTestCase {
    private var account: JSONValue { .object(["type": .string("chatgpt"), "email": .string("person@example.test")]) }
    private var rates: JSONValue { .object(["rateLimits": .object([
        "primary": .object(["usedPercent": .number(25), "windowDurationMins": .number(10080)])
    ])]) }

    func testHealthyAccountDoesNotForceCredentialRotation() async throws {
        let session = ScriptedCodexAccount([.success(.object(["account": account])), .success(rates)])
        let sources = try await integration(session).fetchSources()
        XCTAssertEqual(sources.first?.quota?.weeklyWindow?.usedPercent, 25)
        XCTAssertEqual(session.calls, ["account/read:false", "account/rateLimits/read"])
        XCTAssertTrue(session.closed)
    }

    func testMissingAccountUsesProviderRefreshBeforeAskingToSignIn() async throws {
        let session = ScriptedCodexAccount([
            .success(.object(["account": .null])), .success(.object(["account": account])), .success(rates)
        ])
        let sources = try await integration(session).fetchSources()
        XCTAssertEqual(sources.first?.accountIdentity, "person@example.test")
        XCTAssertEqual(session.calls, ["account/read:false", "account/read:true", "account/rateLimits/read"])
        XCTAssertTrue(session.closed)
    }

    func testExpiredQuotaRequestRefreshesOnceAndRecovers() async throws {
        for error: Error in [IntegrationError.authentication("Expired"), CodexRPCFailure(code: -32000)] {
            let session = ScriptedCodexAccount([
                .success(.object(["account": account])), .failure(error),
                .success(.object(["account": account])), .success(rates)
            ])
            let sources = try await integration(session).fetchSources()
            XCTAssertFalse(sources.isEmpty)
            XCTAssertEqual(session.calls, ["account/read:false", "account/rateLimits/read", "account/read:true", "account/rateLimits/read"])
            XCTAssertTrue(session.closed)
        }
    }

    func testRecoveryNeverLoopsOrChangesAccount() async throws {
        let other: JSONValue = .object(["type": .string("chatgpt"), "email": .string("other@example.test")])
        for refreshed in [account, other] {
            let session = ScriptedCodexAccount([
                .success(.object(["account": account])), .failure(CodexRPCFailure(code: -32000)),
                .success(.object(["account": refreshed])), .failure(CodexRPCFailure(code: -32000))
            ])
            do { _ = try await integration(session).fetchSources(); XCTFail("Must not accept failed or changed account") }
            catch { XCTAssertTrue(error is CodexRPCFailure || (error as? IntegrationError)?.needsAuthentication == true) }
            XCTAssertEqual(session.calls.filter { $0 == "account/read:true" }.count, 1)
            XCTAssertEqual(session.calls.filter { $0 == "account/rateLimits/read" }.count, refreshed == other ? 1 : 2)
            XCTAssertTrue(session.closed)
        }
    }

    func testNullAccountIsNotReportedAsAPIKeyAndUnknownTypesAreNotAssumed() async throws {
        for type in ["missing", "apiKey", "amazonBedrock", "futureType"] {
            let value: JSONValue = type == "missing" ? .null : .object(["type": .string(type)])
            let session = ScriptedCodexAccount(Array(repeating: .success(.object(["account": value])), count: 2))
            do { _ = try await integration(session).fetchSources(); XCTFail("Must require a supported account") }
            catch {
                let failure = try XCTUnwrap(error as? IntegrationError)
                XCTAssertEqual(failure.needsAuthentication, type == "missing" || type == "apiKey")
                XCTAssertEqual(failure.errorDescription?.contains("API key"), type == "apiKey")
            }
            XCTAssertEqual(session.calls, type == "missing" ? ["account/read:false", "account/read:true"] : ["account/read:false"])
            XCTAssertTrue(session.closed)
        }
    }

    func testLegacyProfileWithoutConfiguredIdentityCannotSwitchAccountsDuringRecovery() async throws {
        let session = ScriptedCodexAccount([
            .success(.object(["account": account])), .failure(CodexRPCFailure(code: -32000)),
            .success(.object(["account": .object(["type": .string("chatgpt"), "email": .string("other@example.test")])]))
        ])
        var adapter = integration(session)
        var config = adapter.configuration; config.accountIdentity = nil
        adapter = LiveCodexIntegration(configuration: config, executable: "/fixture", makeSession: { _, _ in session })
        do { _ = try await adapter.fetchSources(); XCTFail("Account identity must remain stable") }
        catch { XCTAssertTrue((error as? IntegrationError)?.needsAuthentication == true) }
        XCTAssertEqual(session.calls.filter { $0 == "account/rateLimits/read" }.count, 1)
        XCTAssertTrue(session.closed)
    }

    func testTransportProtocolAndCancellationFailuresDoNotRotateCredentials() async throws {
        for error: Error in [IntegrationError.timeout, IntegrationError.unavailable("Offline"),
                             CodexRPCFailure(code: -32601), CancellationError()] {
            let session = ScriptedCodexAccount([.success(.object(["account": account])), .failure(error)])
            do { _ = try await integration(session).fetchSources(); XCTFail("Must preserve failure") }
            catch { XCTAssertFalse((error as? IntegrationError)?.needsAuthentication == true) }
            XCTAssertEqual(session.calls, ["account/read:false", "account/rateLimits/read"])
            XCTAssertTrue(session.closed)
        }
    }

    func testMalformedAccountResponseIsNotMistakenForMissingLogin() async throws {
        let session = ScriptedCodexAccount([.success(.object([:]))])
        do { _ = try await integration(session).fetchSources(); XCTFail("Malformed response must fail") }
        catch {
            guard case .invalidResponse = error as? IntegrationError else { return XCTFail("Expected protocol failure") }
        }
        XCTAssertEqual(session.calls, ["account/read:false"])
        XCTAssertTrue(session.closed)
    }

    func testFailedRefreshRemainsUnavailableInsteadOfInventingAPIKeyLogin() async throws {
        let session = ScriptedCodexAccount([.success(.object(["account": .null])), .failure(CodexRPCFailure(code: -32603))])
        let results = await IntegrationRegistry(adapters: [integration(session)], origin: .live).fetchAll()
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.descriptor?.sourceID, "account")
        XCTAssertFalse(result.needsAuthentication)
        XCTAssertEqual(result.errorTitle, "Unavailable")
        XCTAssertFalse(result.error?.contains("API key") == true)
        XCTAssertEqual(session.calls, ["account/read:false", "account/read:true"])
        XCTAssertTrue(session.closed)
    }

    private func integration(_ session: ScriptedCodexAccount) -> LiveCodexIntegration {
        var config = SourceConfiguration(id: "account", integration: .codex, label: "Account")
        config.codexHome = FileManager.default.temporaryDirectory.path
        config.accountIdentity = "person@example.test"
        return LiveCodexIntegration(configuration: config, executable: "/fixture", makeSession: { executable, profile in
            XCTAssertEqual(executable, "/fixture")
            XCTAssertEqual(profile, FileManager.default.temporaryDirectory.path)
            return session
        })
    }
}

@available(macOS 14.0, *)
private final class ScriptedCodexAccount: CodexServing, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<JSONValue, Error>]
    private var recorded: [String] = []
    private var isClosed = false
    init(_ script: [Result<JSONValue, Error>]) { self.script = script }
    var calls: [String] { lock.withLock { recorded } }
    var closed: Bool { lock.withLock { isClosed } }
    func initialize() async throws {}
    func request(_ method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        try lock.withLock {
            let suffix = params["refreshToken"].map { $0 == .bool(true) ? ":true" : ":false" } ?? ""
            recorded.append(method + suffix)
            guard !script.isEmpty else { throw IntegrationError.invalidResponse("Fixture exhausted") }
            return try script.removeFirst().get()
        }
    }
    func waitForNotification(_ method: String, timeout: Double) async throws -> JSONValue {
        throw IntegrationError.invalidResponse("No login should be started")
    }
    func close(with error: Error) { lock.withLock { isClosed = true } }
}
