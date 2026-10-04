@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class ConnectionSetupTests: XCTestCase {
    @MainActor func testAccountServiceHandlesDifferentCredentialShapesWithoutExportingSecrets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "usage.account-service.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let secrets = MemoryCredentials(), repo = try repository(directory, secrets: secrets)
        let store = UsageStore(registry: .live(try repo.load()), defaults: defaults,
            cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")), connections: repo)
        // Save does not fetch providers; the scheduled collector owns refresh.
        for (integration, credentials) in [(IntegrationID.daytona, ["DAYTONA_API_KEY": "private-fixture-one"]),
                                          (.modal, ["MODAL_TOKEN_ID": "private-fixture-two", "MODAL_TOKEN_SECRET": "private-fixture-three"])] {
            var draft = ConnectionDraft(integration: integration); draft.label = integration.name; draft.credentials = credentials
            let state = try await store.handleAccountService(["action": "save", "draft": draft.serviceFields])
            let serialized = try JSONSerialization.data(withJSONObject: state)
            XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("private-fixture"))
            XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("credentialReference"))
        }
        var config = try repo.load()
        XCTAssertEqual(config.sources.count, 2); XCTAssertEqual(secrets.references.count, 2)
        var edited = ConnectionDraft(source: config.sources[0]); edited.label = "Renamed on phone"; edited.enabled = false
        _ = try await store.handleAccountService(["action": "save", "draft": edited.serviceFields])
        config = try repo.load()
        XCTAssertEqual(config.sources[0].label, "Renamed on phone"); XCTAssertFalse(config.sources[0].enabled)
        XCTAssertEqual(secrets.references.count, 2)
        _ = try await store.handleAccountService(["action": "remove", "sourceID": config.sources[0].id])
        XCTAssertEqual(try repo.load().sources.count, 1)
    }

    @MainActor func testConsumerAccountEditsUseServiceInsteadOfLocalRepository() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try repository(directory, secrets: MemoryCredentials())
        let name = "usage.account-consumer.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageStore(registry: .live(try repo.load()), defaults: defaults, connections: repo)
        var calls: [[String: Any]] = []
        store.remoteAccountRequest = { request in calls.append(request); return ["connections": []] }
        var draft = ConnectionDraft(integration: .daytona); draft.label = "Remote"; draft.credentials = ["DAYTONA_API_KEY": "rpc-fixture"]
        let saved = await store.saveConnection(draft)
        XCTAssertTrue(saved)
        XCTAssertTrue(try repo.load().sources.isEmpty)
        XCTAssertEqual(calls.first?["action"] as? String, "save")
    }
    func testNewAPIConnectionKeepsSecretsOutOfConfiguration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryCredentials()
        let repo = try repository(directory, secrets: secrets)
        var draft = ConnectionDraft(integration: .daytona)
        draft.label = "  Personal  "; draft.credentials = ["DAYTONA_API_KEY": "fixture-private-key"]
        let saved = try repo.save(draft)
        XCTAssertEqual(saved.label, "Personal")
        XCTAssertNotNil(saved.credentialReference)
        XCTAssertNil(saved.credentialFile)
        XCTAssertFalse(try String(contentsOf: repo.url, encoding: .utf8).contains("fixture-private-key"))
        XCTAssertEqual(try CredentialReader.values(for: saved, required: ["DAYTONA_API_KEY"], secrets: secrets), draft.credentials)
        XCTAssertEqual(try repo.load().sources.count, 1)
    }

    func testEditingLabelPreservesExistingCredentialFileWithoutCopyingIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent("external.env")
        let original = Data("DAYTONA_API_KEY=untouched-fixture\n".utf8)
        try original.write(to: credential)
        let secrets = MemoryCredentials()
        let repo = try repository(directory, secrets: secrets)
        var source = SourceConfiguration(id: "existing", integration: .daytona, label: "Before")
        source.credentialFile = credential.path
        try IntegrationConfiguration(sources: [source]).save(to: repo.url)
        var draft = ConnectionDraft(source: source); draft.label = "After"
        XCTAssertTrue(draft.credentials.isEmpty)
        let saved = try repo.save(draft)
        XCTAssertEqual(saved.id, source.id)
        XCTAssertEqual(saved.credentialFile, credential.path)
        XCTAssertTrue(secrets.references.isEmpty)
        XCTAssertEqual(try Data(contentsOf: credential), original)
    }

    func testReplacingCredentialsDoesNotChangeSiblingAccountOrSharedKey() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryCredentials()
        let repo = try repository(directory, secrets: secrets)
        try secrets.save(["OPENAI_ADMIN_KEY": "old-fixture"], reference: "shared")
        var first = SourceConfiguration(id: "first", integration: .openaiAPI, label: "First")
        first.credentialReference = "shared"
        var second = first; second.id = "second"; second.label = "Second"
        try IntegrationConfiguration(sources: [first, second]).save(to: repo.url)
        var draft = ConnectionDraft(source: first); draft.credentials = ["OPENAI_ADMIN_KEY": "new-fixture"]
        let saved = try repo.save(draft)
        XCTAssertNotEqual(saved.credentialReference, "shared")
        XCTAssertEqual(try repo.load().sources[1].credentialReference, "shared")
        XCTAssertEqual(try secrets.read(reference: "shared")["OPENAI_ADMIN_KEY"], "old-fixture")
        XCTAssertEqual(secrets.references.count, 2)
    }

    func testIncompleteModalPairIsRejectedBeforeSavingAnything() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryCredentials()
        let repo = try repository(directory, secrets: secrets)
        var draft = ConnectionDraft(integration: .modal)
        draft.label = "Work"; draft.credentials = ["MODAL_TOKEN_ID": "fixture-id"]
        XCTAssertThrowsError(try repo.save(draft))
        XCTAssertTrue(secrets.references.isEmpty)
        XCTAssertTrue(try repo.load().sources.isEmpty)
    }

    func testReplacingImportedCredentialDoesNotDeleteStandaloneUsageSecret() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryCredentials()
        let repo = try repository(directory, secrets: secrets)
        let legacyReference = "usage-credential-legacy-fixture"
        try secrets.save(["DAYTONA_API_KEY": "original-fixture"], reference: legacyReference)
        var original = SourceConfiguration(id: "imported", integration: .daytona, label: "Imported")
        original.credentialReference = legacyReference
        try IntegrationConfiguration(sources: [original]).save(to: repo.url)
        var draft = ConnectionDraft(source: original)
        draft.credentials = ["DAYTONA_API_KEY": "replacement-fixture"]
        let replacement = try repo.save(draft)
        XCTAssertTrue(try XCTUnwrap(replacement.credentialReference).hasPrefix("argus-usage-"))
        XCTAssertEqual(try secrets.read(reference: legacyReference)["DAYTONA_API_KEY"], "original-fixture")
        XCTAssertEqual(secrets.references.count, 2)
    }

    func testFailedConfigurationWriteRollsBackOnlyTheNewSecret() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = MemoryCredentials()
        var repo = try repository(directory, secrets: secrets)
        try secrets.save(["DAYTONA_API_KEY": "unrelated-fixture"], reference: "other")
        repo.saveConfiguration = { _, _ in throw IntegrationError.configuration("Fixture write failure") }
        var draft = ConnectionDraft(integration: .daytona)
        draft.label = "Personal"; draft.credentials = ["DAYTONA_API_KEY": "new-fixture"]
        XCTAssertThrowsError(try repo.save(draft))
        XCTAssertEqual(secrets.references, ["other"])
        XCTAssertTrue(try repo.load().sources.isEmpty)
    }

    func testInvalidHostAndBudgetDoNotPersistConnections() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try repository(directory, secrets: MemoryCredentials())
        var draft = ConnectionDraft(integration: .windowsStorage)
        draft.label = "Windows"; draft.host = "host; unwanted-command"
        XCTAssertThrowsError(try repo.save(draft))
        draft.host = "DESKTOP-TEST"; draft.budget = "-1"
        XCTAssertThrowsError(try repo.save(draft))
        draft.budget = ""; draft.label = " "
        XCTAssertThrowsError(try repo.save(draft))
        XCTAssertTrue(try repo.load().sources.isEmpty)
    }

    func testNewCodexConnectionGetsItsOwnProfileWithoutStartingAuthentication() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try repository(directory, secrets: MemoryCredentials())
        var draft = ConnectionDraft(integration: .codex); draft.label = "Another account"
        let saved = try repo.save(draft)
        XCTAssertTrue(draft.startsCodexLogin)
        XCTAssertTrue(try XCTUnwrap(saved.codexHome).hasPrefix(directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.codexHome!))
        XCTAssertNil(saved.credentialReference)
    }

    @MainActor
    func testCheckingOneConnectionDoesNotRefreshItsSibling() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CountingAccount(id: "first"), second = CountingAccount(id: "second")
        let store = UsageStore(registry: IntegrationRegistry(adapters: [first, second], origin: .live),
            defaults: UserDefaults(suiteName: "com.pranjal.usage.tests.\(UUID())")!,
            cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")))
        await store.refresh()
        await store.refresh(sourceID: "first")
        let firstCount = await first.count, secondCount = await second.count
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(Set(store.sources.map(\.id)), ["first", "second"])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-connection-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testSharedControllerStartsOnlyOneRefreshLoop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "argus.usage.lifecycle.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let account = CountingAccount(id: "single")
        let store = UsageStore(registry: IntegrationRegistry(adapters: [account], origin: .live), defaults: defaults,
            cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")))
        let controller = UsageController(store: store, defaults: defaults)
        defer { controller.stop() }
        controller.start(); controller.start(); controller.start()
        try await Task.sleep(for: .milliseconds(100))
        let calls = await account.count
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(controller.lastRefresh)
    }
    private func repository(_ directory: URL, secrets: MemoryCredentials) throws -> ConnectionRepository {
        let url = directory.appendingPathComponent("config.json")
        try IntegrationConfiguration(sources: []).save(to: url)
        return ConnectionRepository(url: url, secrets: secrets, profilesDirectory: directory.appendingPathComponent("profiles"))
    }
}

@available(macOS 14.0, *)
private final class MemoryCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    var references: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
    func read(reference: String) throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let value = values[reference] else { throw IntegrationError.authentication("Fixture missing") }
        return value
    }
    func save(_ value: [String: String], reference: String) throws {
        lock.lock(); defer { lock.unlock() }; values[reference] = value
    }
    func delete(reference: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: reference)
    }
}

@available(macOS 14.0, *)
private actor CountingAccount: UsageIntegration {
    nonisolated let id = IntegrationID.codex
    nonisolated let descriptor: IntegrationDescriptor?
    private(set) var count = 0
    init(id: String) { descriptor = IntegrationDescriptor(sourceID: id, integration: .codex, label: id) }
    func fetchSources() async throws -> [UsageSource] {
        count += 1
        return [UsageSource(id: descriptor!.sourceID, integration: .codex, account: descriptor!.label, observedAt: .now,
                            payload: .quota(QuotaUsage(windows: [])), origin: .live)]
    }
}
