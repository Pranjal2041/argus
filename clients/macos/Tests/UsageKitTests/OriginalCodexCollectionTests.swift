import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class OriginalCodexCollectionTests: XCTestCase {
    func testOriginalReadOnlyProtocolUsesTheConfiguredPrivateProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sources = try await fixture.integration.fetchSources()
        XCTAssertEqual(sources.first?.accountIdentity, "fixture@example.test")
        XCTAssertEqual(sources.first?.quota?.weeklyWindow?.usedPercent, 25)
        let calls = try fixture.calls()
        XCTAssertEqual(calls.compactMap { $0["method"].string }, ["initialize", "initialized", "account/read", "account/rateLimits/read"])
        XCTAssertEqual(calls[2]["params"]["refreshToken"].bool, false)
    }

    func testMissingOrUnsupportedAccountMatchesOriginalWithoutExtraCredentialRotation() async throws {
        for account in [JSONValue.null, .object(["type": .string("apiKey")])] {
            let fixture = try Fixture(account: account)
            defer { fixture.remove() }
            do { _ = try await fixture.integration.fetchSources(); XCTFail("Expected unsupported login") }
            catch { XCTAssertTrue((error as? IntegrationError)?.needsAuthentication == true) }
            let calls = try fixture.calls()
            XCTAssertEqual(calls.filter { $0["method"].string == "account/read" }.count, 1)
            XCTAssertFalse(calls.contains { $0["params"]["refreshToken"].bool == true })
            XCTAssertFalse(calls.contains { $0["method"].string == "account/rateLimits/read" })
        }
    }

    func testFailedCLIReadDoesNotPoisonTheNextCollection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(#"{"error":{"code":-32000,"message":"Fixture failure"}}"#.utf8).write(to: fixture.root.appendingPathComponent("rates.json"))
        let registry = IntegrationRegistry(adapters: [fixture.integration], origin: .live)
        let failed = await registry.fetchAll()
        XCTAssertNotNil(failed.first?.error)
        try fixture.writeRates()
        let recovered = await registry.fetchAll()
        XCTAssertNil(recovered.first?.error)
        XCTAssertEqual(recovered.first?.sources.first?.quota?.weeklyWindow?.usedPercent, 25)
        XCTAssertEqual(try fixture.calls().filter { $0["method"].string == "account/read" }.count, 2)
    }

    private struct Fixture {
        let root: URL
        let integration: LiveCodexIntegration
        init(account: JSONValue = .object(["type": .string("chatgpt"), "email": .string("fixture@example.test")])) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-original-codex-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../testdata/usage/codex-app-server.rb").standardizedFileURL
            let executable = root.appendingPathComponent("codex")
            try FileManager.default.copyItem(at: source, to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            try JSONEncoder().encode(account).write(to: root.appendingPathComponent("account.json"))
            var config = SourceConfiguration(id: "fixture", integration: .codex, label: "Fixture")
            config.codexHome = root.path
            integration = LiveCodexIntegration(configuration: config, executable: executable.path)
            try writeRates()
        }
        func writeRates() throws {
            try Data(#"{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}"#.utf8)
                .write(to: root.appendingPathComponent("rates.json"))
        }
        func calls() throws -> [JSONValue] {
            try String(contentsOf: root.appendingPathComponent("requests.jsonl"))
                .split(separator: "\n").map { try JSONValue.decode(Data($0.utf8)) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
