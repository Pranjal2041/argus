import Foundation
import XCTest
@testable import UniversalTmuxMac

final class MemoryCredentialSecretStore: CredentialSecretStore {
    var secrets: [UUID: CredentialVaultSecret] = [:]
    var availableAfterFirstUnlock = false

    func read(id: UUID) throws -> CredentialVaultSecret {
        guard let secret = secrets[id] else { throw CredentialVaultError.secretMissing }
        return secret
    }

    func write(id: UUID, secret: CredentialVaultSecret, availableAfterFirstUnlock: Bool) throws {
        secrets[id] = secret
        self.availableAfterFirstUnlock = availableAfterFirstUnlock
    }

    func delete(id: UUID) throws { secrets[id] = nil }

    func setAvailableAfterFirstUnlock(_ enabled: Bool, ids: [UUID]) throws {
        availableAfterFirstUnlock = enabled
    }
}

@MainActor
final class CredentialVaultTests: XCTestCase {
    func testOneTimeGrantIsBoundToCallerAndConsumedAfterFill() async throws {
        let (vault, defaults, _, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        try vault.save(name: "Research Gmail", group: "Research", username: "user@example.com",
                       password: "correct horse battery staple")
        let caller = testCaller(session: "research")
        let requestTask = Task {
            try await vault.requestGrant(credentialName: "Research Gmail", caller: caller,
                                         domain: "accounts.google.com")
        }
        await Task.yield()
        XCTAssertEqual(vault.pendingApproval?.entry.name, "Research Gmail")
        XCTAssertEqual(vault.pendingApproval?.restrictToDomain, false)
        vault.approvePending()
        let response = try await requestTask.value

        let (_, secret) = try vault.resolve(grant: response.token,
                                            credentialName: "Research Gmail", caller: caller,
                                            domain: "mail.google.com")
        XCTAssertEqual(secret.username, "user@example.com")
        XCTAssertEqual(secret.password, "correct horse battery staple")

        XCTAssertThrowsError(try vault.resolve(
            grant: response.token, credentialName: "Research Gmail",
            caller: testCaller(session: "other-panel"), domain: "mail.google.com"
        ))
        let entry = try XCTUnwrap(vault.entry(named: "Research Gmail"))
        vault.markGrantUsed(response.token, entry: entry, caller: caller)
        XCTAssertThrowsError(try vault.resolve(
            grant: response.token, credentialName: "Research Gmail",
            caller: caller, domain: "mail.google.com"
        ))
    }

    func testUnattendedModeAutoGrantsWholeVaultAndChangesKeychainAccessibility() async throws {
        let (vault, defaults, secrets, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        try vault.save(name: "Dashboard", group: "Test", username: "agent", password: "secret")
        vault.setAllowInUnattendedMode(true)
        vault.unattendedModeActive = true

        let caller = testCaller(session: "night-run")
        let grant = try await vault.requestGrant(credentialName: "Dashboard", caller: caller, domain: "")
        XCTAssertEqual(grant.scope, .vault)
        XCTAssertEqual(grant.duration, .panel)
        XCTAssertTrue(secrets.availableAfterFirstUnlock)
        XCTAssertNil(vault.pendingApproval)
    }

    func testPasswordNeverAppearsInPersistedVaultMetadata() throws {
        let (vault, defaults, _, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        let password = "never-persist-this-password"
        try vault.save(name: "Example", group: "", username: "person", password: password)
        for (_, value) in defaults.persistentDomain(forName: suite) ?? [:] {
            if let data = value as? Data {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(password))
            }
        }
    }

    func testAPIKeyRequestResolvesSavedNameToItsEnvironmentVariable() async throws {
        let (vault, defaults, _, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        try vault.saveAPIKey(name: "OpenAI primary", group: "Research",
                             variable: "OPENAI_API_KEY", value: "sk-primary")
        try vault.saveAPIKey(name: "OpenAI secondary", group: "Research",
                             variable: "OPENAI_API_KEY", value: "sk-secondary")
        try vault.saveAPIKey(name: "Anthropic", group: "Research",
                             variable: "ANTHROPIC_API_KEY", value: "sk-ant")
        let caller = testCaller(session: "research", cwd: "/work/project")
        let task = Task {
            try await vault.requestAPIKey(name: "openai primary",
                                          destination: "/work/project/.env", caller: caller)
        }
        await Task.yield()
        let request = try XCTUnwrap(vault.pendingAPIKeyApproval)
        XCTAssertEqual(request.name, "openai primary")
        XCTAssertEqual(request.candidates.map(\.name), ["OpenAI primary"])
        vault.approvePendingAPIKey()
        let response = try await task.value
        XCTAssertEqual(response.variable, "OPENAI_API_KEY")
        XCTAssertEqual(response.entry.name, "OpenAI primary")
        XCTAssertEqual(response.value, "sk-primary")
    }

    func testAPIKeyValueNeverAppearsInPersistedMetadata() throws {
        let (vault, defaults, _, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        let value = "never-persist-this-api-key"
        try vault.saveAPIKey(name: "OpenAI", group: "", variable: "OPENAI_API_KEY", value: value)
        for (_, stored) in defaults.persistentDomain(forName: suite) ?? [:] {
            if let data = stored as? Data {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(value))
            }
        }
    }

    func testUnknownAPIKeyCanBeSavedInsideItsPendingApproval() async throws {
        let (vault, defaults, _, suite) = makeVault()
        defer { defaults.removePersistentDomain(forName: suite) }
        let caller = testCaller(session: "new-project", cwd: "/work/new-project")
        let task = Task {
            try await vault.requestAPIKey(name: "New service",
                                          destination: "/work/new-project/.env", caller: caller)
        }
        await Task.yield()
        XCTAssertEqual(vault.pendingAPIKeyApproval?.candidates.count, 0)
        try vault.saveAndApprovePendingAPIKey(variable: "NEW_SERVICE_API_KEY", value: "new-secret")
        let response = try await task.value
        XCTAssertEqual(response.entry.name, "New service")
        XCTAssertEqual(response.value, "new-secret")
        XCTAssertEqual(vault.apiKeyEntries(for: "NEW_SERVICE_API_KEY").count, 1)
    }

    func testLegacyEntriesDecodeAsSignIns() throws {
        struct LegacyEntry: Codable {
            let id: UUID
            let name: String
            let group: String
            let createdAt: Date
            let updatedAt: Date
        }
        let suite = "CredentialVaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyEntry(id: UUID(), name: "Existing Gmail", group: "Research",
                                 createdAt: Date(), updatedAt: Date())
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "ut.credentialVault.entries.v1")
        let vault = CredentialVaultStore(secretStore: MemoryCredentialSecretStore(), defaults: defaults)
        XCTAssertEqual(vault.entries.first?.kind, .login)
        XCTAssertEqual(vault.entries.first?.environmentVariable, "")
    }

    private func makeVault() -> (CredentialVaultStore, UserDefaults, MemoryCredentialSecretStore, String) {
        let suite = "CredentialVaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let secrets = MemoryCredentialSecretStore()
        return (CredentialVaultStore(secretStore: secrets, defaults: defaults), defaults, secrets, suite)
    }

    private func testCaller(session: String, cwd: String = "") -> BrowserCredentialCaller {
        BrowserCredentialCaller(machineName: "babel-p9-28", machineHost: "babel-p9-28",
                                sessionName: session, stableSessionID: "$4",
                                sessionLineageID: "tmux:lineage:$4",
                                workingDirectory: cwd,
                                dotenvPath: cwd.isEmpty ? "" : cwd + "/.env")
    }
}
