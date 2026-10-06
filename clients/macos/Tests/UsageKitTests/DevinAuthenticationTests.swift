import XCTest
@testable import UsageKit

@available(macOS 14.0, *)
final class DevinAuthenticationTests: XCTestCase {
    static let link = "https://app.devin.ai/auth/cli/continue?state=fixture&code_challenge=challenge&code_challenge_method=S256&prompt=select_account"

    func testLoginLinksRequireCompleteProviderPKCEURLs() {
        let link = Self.link
        XCTAssertNil(DevinOutput.loginURL(in: "Visit " + link), "A fragment without a delimiter isn't a complete URL")
        XCTAssertEqual(DevinOutput.loginURL(in: "Visit " + link + " to sign in." )?.absoluteString, link)
        for invalid in [link.replacingOccurrences(of: "https:", with: "http:"),
                        link.replacingOccurrences(of: "app.devin.ai", with: "app.devin.ai.evil.test"),
                        link.replacingOccurrences(of: "app.devin.ai", with: "user:password@app.devin.ai"),
                        "https://app.devin.ai/auth/cli/continue?state=fixture"] {
            XCTAssertNil(DevinOutput.loginURL(in: "Visit " + invalid + " now"))
        }
        let ansi = "\u{1b}[sVisit \u{1b}]8;;\(link)\u{1b}\\\(link)\u{1b}]8;;\u{1b}\\ to sign in.\r\n"
        XCTAssertEqual(DevinOutput.loginURL(in: DevinOutput.plain(ansi))?.absoluteString, link)
    }

    func testSignInVerifiesIdentityWithoutRequiringQuotaAndUsesSamePrivateRoot() async throws {
        let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try AccountProfile.create(in: directory)
        let session = FixtureLoginProcess(profile: profile.root)
        let runner = FixtureAccountStatus(email: "first@example.test")
        let authenticator = DevinAuthenticator(executable: "/fixture/devin", runner: runner, makeSession: { _, environment in
            XCTAssertEqual(environment["HOME"], profile.root.path)
            return session
        })
        let login = try await authenticator.signIn(profile: profile) { url, process in
            XCTAssertEqual(url.absoluteString, Self.link)
            try? process.sendCode("fixture-code")
        }
        XCTAssertEqual(login.identity, "first@example.test")
        XCTAssertEqual(login.profile, profile.root.path)
        let environments = await runner.environments
        XCTAssertEqual(environments.map { $0["HOME"] }, [profile.root.path])
        XCTAssertTrue(session.closed)
        let permissions = try FileManager.default.attributesOfItem(atPath: profile.root.appendingPathComponent("data/devin/credentials.toml").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testFailedAndCancelledSignInNeverYieldVerifiedAccount() async throws {
        let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try AccountProfile.create(in: directory)
        for cancellation in [false, true] {
            let session = FixtureLoginProcess(profile: profile.root, status: 1)
            let authenticator = DevinAuthenticator(executable: "/fixture/devin", makeSession: { _, _ in session })
            do {
                _ = try await authenticator.signIn(profile: profile) { _, process in
                    if cancellation { process.cancel() } else { try? process.sendCode("fixture-code") }
                }
                XCTFail("A failed attempt cannot replace the saved connection")
            } catch { XCTAssertTrue(session.closed) }
        }
    }

    @MainActor
    func testStoreCancellationPreservesConfigurationAndRemovesOnlyAttemptProfile() async throws {
        let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AccountProfile.create(in: directory.appendingPathComponent("original"))
        var source = SourceConfiguration(id: "devin-fixture", integration: .devin, label: "Work")
        source.loginProfile = old.root.path; source.accountIdentity = "existing@example.test"
        let config = IntegrationConfiguration(sources: [source])
        let url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let before = try Data(contentsOf: url)
        let suite = "argus.devin.tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = directory.appendingPathComponent("attempts")
        let store = UsageStore(registry: IntegrationRegistry(adapters: [], origin: .live, configuration: config), defaults: defaults,
            cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")),
            connections: ConnectionRepository(url: url, profilesDirectory: attempts))
        store.makeDevinAuthenticator = { executable in
            DevinAuthenticator(executable: executable, makeSession: { _, environment in FixtureLoginProcess(profile: URL(fileURLWithPath: environment["HOME"]!)) })
        }
        store.connectAccount(source.id)
        for _ in 0..<100 where store.devinLoginProcess == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.devinLoginProcess)
        XCTAssertNotNil(store.loginInstructions)
        store.devinAuthorizationCode = "unsubmitted-fixture"
        store.cancelLogin()
        for _ in 0..<100 where store.loginSourceID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.loginSourceID)
        XCTAssertEqual(store.devinAuthorizationCode, "")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.root.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: attempts.path).isEmpty)
    }

    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("argus-devin-auth-test-\(UUID())") }

    @MainActor func testServiceCancellationAcknowledgesOnlyAfterOwnedProcessAndProfileCleanup() async throws {
        let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = try AccountProfile.create(in: directory.appendingPathComponent("original"))
        var source = SourceConfiguration(id: "devin-fixture", integration: .devin, label: "Work")
        source.loginProfile = old.root.path; source.accountIdentity = "existing@example.test"
        let config = IntegrationConfiguration(sources: [source]), url = directory.appendingPathComponent("config.json")
        try config.save(to: url)
        let before = try Data(contentsOf: url), attempts = directory.appendingPathComponent("attempts")
        let suite = "argus.devin.cancel-tests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(registry: .init(adapters: [], origin: .live, configuration: config), defaults: defaults,
            cache: .init(url: directory.appendingPathComponent("cache.json")),
            connections: .init(url: url, profilesDirectory: attempts))
        let process = FixtureLoginProcess(profile: old.root)
        store.makeDevinAuthenticator = { executable in DevinAuthenticator(executable: executable, makeSession: { _, _ in process }) }
        let started = try await store.handleAccountService(["action": "connect", "sourceID": source.id, "loginAttemptID": "owned"])
        XCTAssertEqual(started["loginAttemptID"] as? String, "owned")
        for _ in 0..<100 where store.devinLoginProcess == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.devinLoginProcess)
        store.refreshing = true
        let cancelled = try await store.handleAccountService(["action": "cancel", "loginAttemptID": "owned"])
        XCTAssertTrue(process.closed, "The response must wait for cleanup, not merely schedule it")
        XCTAssertNil(cancelled["loginSourceID"])
        XCTAssertNil(cancelled["loginAttemptID"])
        XCTAssertNil(cancelled["url"])
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.root.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: attempts.path).isEmpty)
    }

    func testInstalledCLIStartsAndCancelsInsideAnEmptyPrivateProfile() async throws {
        guard ProcessInfo.processInfo.environment["UT_DEVIN_CLI_PROBE"] == "1" else { throw XCTSkip("Opt-in installed CLI probe; no login code, browser or model run") }
        let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/devin").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Devin CLI is not installed") }
        let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try AccountProfile.create(in: directory)
        let result = try await CommandRunner().run(executable: executable, arguments: ["auth", "status"], environment: profile.environment)
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        XCTAssertTrue(output.contains("Not logged in"))
        XCTAssertTrue(output.contains(profile.root.path), "The installed CLI must select the private credential path")
        let authenticator = DevinAuthenticator(executable: executable)
        do {
            _ = try await authenticator.signIn(profile: profile) { url, process in
                XCTAssertEqual(url.host, "app.devin.ai")
                process.cancel()
            }
            XCTFail("Cancelling before code entry cannot succeed")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.root.appendingPathComponent("data/devin/credentials.toml").path))
    }
}

@available(macOS 14.0, *)
private final class FixtureLoginProcess: LoginProcessServing, @unchecked Sendable {
    let events: AsyncThrowingStream<LoginProcessEvent, Error>
    let continuation: AsyncThrowingStream<LoginProcessEvent, Error>.Continuation
    let profile: URL
    let status: Int32
    private(set) var closed = false
    init(profile: URL, status: Int32 = 0) {
        let stream = AsyncThrowingStream<LoginProcessEvent, Error>.makeStream()
        events = stream.stream; continuation = stream.continuation
        self.profile = profile; self.status = status
    }
    func start() throws {
        // Split UTF-8/output arbitrarily, like a real PTY.
        let output = Data(("Visit " + DevinAuthenticationTests.link + " to sign in.\n").utf8)
        for byte in output { continuation.yield(.output(Data([byte]))) }
    }
    func sendCode(_ code: String) throws {
        if status == 0 {
            let directory = profile.appendingPathComponent("data/devin")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture-only".utf8).write(to: directory.appendingPathComponent("credentials.toml"))
        }
        continuation.yield(.exited(status)); continuation.finish()
    }
    func cancel() { continuation.finish(throwing: CancellationError()) }
    func close() async { closed = true; cancel() }
}

@available(macOS 14.0, *)
private actor FixtureAccountStatus: CommandRunning {
    let email: String
    var environments: [[String: String]] = []
    init(email: String) { self.email = email }
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        environments.append(environment)
        XCTAssertEqual(arguments, ["auth", "status"])
        return CommandOutput(status: 0, stdout: Data("Logged in (via Devin).\n  Email: \(email)\n  Plan: Enterprise\nFailed to fetch quota: \n".utf8), stderr: Data())
    }
}
