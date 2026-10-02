import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class AccountProfileTests: XCTestCase {
    func testProfileCommitIsIndependentForDifferentCLIImplementations() throws {
        for provider in [IntegrationID.codex, .devin] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let firstProfile = try AccountProfile.create(in: root), secondProfile = try AccountProfile.create(in: root)
            let replacement = try AccountProfile.create(in: root)
            var first = SourceConfiguration(id: "first", integration: provider, label: "First")
            first.accountProfile = firstProfile.root.path; first.accountIdentity = "first@example.test"
            var second = SourceConfiguration(id: "second", integration: provider, label: "Second")
            second.accountProfile = secondProfile.root.path; second.accountIdentity = "second@example.test"
            let repo = ConnectionRepository(url: root.appendingPathComponent("config.json"))
            try IntegrationConfiguration(sources: [first, second]).save(to: repo.url)
            // Metadata changes during an in-progress browser sign-in are kept.
            var changed = try repo.load(); changed.sources[0].label = "Renamed"
            try changed.save(to: repo.url)
            try AccountProfileCommit.save(.init(profile: replacement.root.path, identity: "replacement@example.test"),
                sourceID: first.id, integration: provider, originalProfile: first.accountProfile, repository: repo)
            let config = try repo.load()
            XCTAssertEqual(config.sources[0].accountProfile, replacement.root.path)
            XCTAssertEqual(config.sources[0].label, "Renamed")
            XCTAssertEqual(config.sources[0].accountIdentity, "replacement@example.test")
            XCTAssertEqual(config.sources[1].accountProfile, second.accountProfile)
            XCTAssertEqual(config.sources[1].accountIdentity, second.accountIdentity)
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstProfile.root.path), "Never delete a previous profile as a side effect of account replacement")
        }
    }

    func testCommitRejectsDuplicatesStaleSelectionAndDisabledConnections() throws {
        for provider in [IntegrationID.codex, .devin] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var first = SourceConfiguration(id: "first", integration: provider, label: "First")
            first.accountProfile = root.appendingPathComponent("first").path
            var second = SourceConfiguration(id: "second", integration: provider, label: "Second")
            second.accountProfile = root.appendingPathComponent("second").path; second.accountIdentity = "other@example.test"
            let repo = ConnectionRepository(url: root.appendingPathComponent("config.json"))
            try IntegrationConfiguration(sources: [first, second]).save(to: repo.url)
            let before = try Data(contentsOf: repo.url)
            for login in [
                VerifiedProfileLogin(profile: root.appendingPathComponent("new").path, identity: "OTHER@example.test"),
                VerifiedProfileLogin(profile: second.accountProfile!, identity: "new@example.test"),
                VerifiedProfileLogin(profile: root.appendingPathComponent("new").path, identity: "")
            ] {
                XCTAssertThrowsError(try AccountProfileCommit.save(login, sourceID: first.id, integration: provider,
                    originalProfile: first.accountProfile, repository: repo))
                XCTAssertEqual(try Data(contentsOf: repo.url), before)
            }
            let valid = VerifiedProfileLogin(profile: root.appendingPathComponent("new").path, identity: "new@example.test")
            XCTAssertThrowsError(try AccountProfileCommit.save(valid, sourceID: first.id, integration: provider, originalProfile: "/outdated", repository: repo))
            var changed = try repo.load(); changed.sources[0].enabled = false; try changed.save(to: repo.url)
            XCTAssertThrowsError(try AccountProfileCommit.save(valid, sourceID: first.id, integration: provider, originalProfile: first.accountProfile, repository: repo))
        }
    }

    func testFailedWriteKeepsOldAccountAndExplicitIdentityValidationIsShared() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var source = SourceConfiguration(id: "account", integration: .devin, label: "Account")
        source.loginProfile = root.appendingPathComponent("old").path
        var repo = ConnectionRepository(url: root.appendingPathComponent("config.json"))
        try IntegrationConfiguration(sources: [source]).save(to: repo.url)
        let before = try Data(contentsOf: repo.url)
        repo.saveConfiguration = { _, _ in throw IntegrationError.configuration("Fixture failure") }
        XCTAssertThrowsError(try AccountProfileCommit.save(.init(profile: root.appendingPathComponent("new").path, identity: "new@example.test"),
            sourceID: source.id, integration: .devin, originalProfile: source.loginProfile, repository: repo))
        XCTAssertEqual(try Data(contentsOf: repo.url), before)
        for provider in [IntegrationID.codex, .devin] {
            var expected = SourceConfiguration(id: "one", integration: provider, label: "One")
            expected.accountIdentity = "person@example.test"
            XCTAssertNoThrow(try expected.validateAccountIdentity("PERSON@example.test"))
            XCTAssertThrowsError(try expected.validateAccountIdentity("other@example.test"))
            XCTAssertThrowsError(try expected.validateAccountIdentity(nil))
        }
    }

    func testPrivateRootsAndEnvironmentDoNotInheritAmbientCredentials() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try AccountProfile.create(in: root), second = try AccountProfile.create(in: root)
        XCTAssertNotEqual(first.environment, second.environment)
        for directory in [first.root, first.root.appendingPathComponent("data"), first.root.appendingPathComponent("config")] {
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
        }
        let environment = UsageProcessEnvironment.make(overrides: first.environment,
            inherited: ["HOME": "/ambient", "XDG_DATA_HOME": "/ambient/data", "DEVIN_API_KEY": "fixture", "WINDSURF_TOKEN": "fixture", "OTHER_AUTH_TOKEN": "fixture", "PATH": "/bin"])
        XCTAssertEqual(environment["HOME"], first.root.path)
        XCTAssertEqual(environment["XDG_DATA_HOME"], first.root.appendingPathComponent("data").path)
        XCTAssertEqual(environment["PATH"], "/bin")
        XCTAssertNil(environment["DEVIN_API_KEY"]); XCTAssertNil(environment["WINDSURF_TOKEN"]); XCTAssertNil(environment["OTHER_AUTH_TOKEN"])
        XCTAssertThrowsError(try AccountProfile(path: "/tmp/.."))
        XCTAssertThrowsError(try AccountProfile(path: "relative"))
    }

    func testConnectionDraftStartsSeparateSignInForNewDevinAccount() throws {
        let draft = ConnectionDraft(integration: .devin)
        XCTAssertTrue(draft.startsAccountLogin)
        XCTAssertTrue(draft.startsDevinLogin)
        var source = SourceConfiguration(id: "existing", integration: .devin, label: "Existing")
        XCTAssertTrue(ConnectionDraft(source: source).startsDevinLogin, "Legacy shared-login rows must be explicitly connected, not reused ambiently")
        source.loginProfile = "/private/profile"
        XCTAssertFalse(ConnectionDraft(source: source).startsDevinLogin, "Renaming a signed-in account must not start another login")
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("argus-account-test-\(UUID())") }
}
