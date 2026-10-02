import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class UsageMigrationTests: XCTestCase {
    func testImportPreservesLegacyAndReferencesAndNeverOverwritesArgus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        var source = SourceConfiguration(id: "account", integration: .claude, label: "Work")
        source.credentialReference = "legacy-reference"
        try IntegrationConfiguration(sources: [source]).save(to: old.appendingPathComponent("integrations.json"))
        let before = try Data(contentsOf: old.appendingPathComponent("integrations.json"))
        XCTAssertTrue(try UsageMigration.importIfNeeded(from: old, to: new))
        let imported = try IntegrationConfiguration.load(from: new.appendingPathComponent("integrations.json"))
        XCTAssertEqual(imported.sources[0].credentialReference, "legacy-reference")
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("integrations.json")), before)
        try IntegrationConfiguration(sources: []).save(to: new.appendingPathComponent("integrations.json"))
        XCTAssertFalse(try UsageMigration.importIfNeeded(from: old, to: new))
        XCTAssertTrue(try IntegrationConfiguration.load(from: new.appendingPathComponent("integrations.json")).sources.isEmpty)
        let permissions = try FileManager.default.attributesOfItem(atPath: new.appendingPathComponent("integrations.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExistingExecutableConfigurationLoadsWithNewProviderDefaults() throws {
        let data = Data(#"{"sources":[],"executables":{"codex":"/custom/codex","ut":"/custom/ut","uvx":"/custom/uvx"}}"#.utf8)
        let config = try JSONDecoder().decode(IntegrationConfiguration.self, from: data)
        XCTAssertEqual(config.executables.codex, "/custom/codex")
        XCTAssertTrue(config.executables.devin.hasSuffix("/.local/bin/devin"))
    }
}
