@testable import UsageKit
import XCTest

@available(macOS 14.0, *)
final class LiveIntegrationTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue { try JSONValue.decode(Data(text.utf8)) }
    private var now: Date { Date(timeIntervalSince1970: 1_789_142_400) } // September 11, 2026 UTC

    func testDotenvIsParsedAsDataWithoutEvaluatingShellSyntax() {
        let parsed = CredentialReader.parse("""
        # comment
        export FIRST = 'literal value'
        SECOND="with # inside"
        THIRD=plain # comment
        COMMAND=$(do-not-execute)
        MALFORMED-LABEL=no
        EMPTY=
        """)
        XCTAssertEqual(parsed["FIRST"], "literal value")
        XCTAssertEqual(parsed["SECOND"], "with # inside")
        XCTAssertEqual(parsed["THIRD"], "plain")
        XCTAssertEqual(parsed["COMMAND"], "$(do-not-execute)")
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertNil(parsed["MALFORMED-LABEL"])
    }

    func testConfigurationSupportsMinimalSourceAndRejectsDuplicateIDs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"sources":[{"id":"mac","integration":"mac-storage","label":"Mac"}]}"#.utf8).write(to: url)
        let config = try IntegrationConfiguration.load(from: url)
        XCTAssertTrue(config.sources[0].enabled)
        XCTAssertEqual(config.refreshIntervalSeconds, 120)
        var duplicate = config; duplicate.sources += config.sources
        try duplicate.save(to: url)
        XCTAssertThrowsError(try IntegrationConfiguration.load(from: url))
    }

    func testCodexWeeklyPrimaryIsNotMistakenForFiveHourWindow() throws {
        let account = try json(#"{"type":"chatgpt","email":"person@example.test","planType":"pro"}"#)
        let rates = try json(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":null},"spark":{"limitName":"Spark","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1900000000}}},"rateLimitResetCredits":{"availableCount":2}}"#)
        let source = try LiveCodexIntegration.normalize(account: account, rates: rates,
            configuration: SourceConfiguration(id: "codex-a", integration: .codex, label: "Primary"), now: now)
        let quota = try XCTUnwrap(source.quota)
        XCTAssertEqual(source.accountIdentity, "person@example.test")
        XCTAssertNil(quota.shortWindow)
        XCTAssertEqual(quota.weeklyWindow?.usedPercent, 55)
        XCTAssertEqual(quota.additionalBuckets[0].windows.count, 2)
        XCTAssertEqual(quota.resetCreditsAvailable, 2)
        XCTAssertTrue(quota.weeklyHistory.isEmpty)
    }

    func testCodexMissingResetAndSecondaryStayMissing() throws {
        let windows = try LiveCodexIntegration.windows(json(#"{"primary":{"usedPercent":0,"windowDurationMins":60},"secondary":null}"#))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "1-hour")
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertThrowsError(try LiveCodexIntegration.windows(json(#"{"primary":{"usedPercent":-1}}"#)))
    }

    func testDaytonaCountsOnlyStartedAndDoesNotInventPricesOrIdleState() throws {
        let rows = try json(#"[{"id":"a","name":"running","state":"started","cpu":2,"memory":4},{"id":"b","state":"stopped","cpu":8,"memory":16},{"id":"c","state":"paused","cpu":4,"memory":8},{"id":"a","state":"started","cpu":2,"memory":4}]"#).array!
        let source = try LiveDaytonaIntegration.normalize(sandboxes: rows, usage: nil,
            configuration: SourceConfiguration(id: "daytona", integration: .daytona, label: "Personal"), now: now)
        let compute = try XCTUnwrap(source.compute)
        XCTAssertEqual(compute.resources.count, 1)
        XCTAssertEqual(compute.allocatedCPU, 2)
        XCTAssertNil(compute.spent)
        XCTAssertNil(compute.hourlyRate)
        XCTAssertNil(compute.capacity)
        XCTAssertNil(compute.resources[0].startedAt)
        XCTAssertFalse(compute.idleDetectionAvailable)
    }

    func testDaytonaPaginatesAndKeepsInventoryWhenUsagePermissionIsDenied() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent(".env")
        try Data("DAYTONA_API_KEY=fixture-only-not-a-key\n".utf8).write(to: credential)
        let client = FixtureHTTPClient([
            response(#"{"items":[{"id":"a","state":"started","cpu":1,"memory":1}],"nextCursor":"second-page"}"#),
            response(#"{"items":[{"id":"b","state":"started","cpu":2,"memory":2}],"nextCursor":null}"#),
            response(#"{"organizationId":"org-1"}"#),
            HTTPResponse(status: 403, data: Data(), retryAfter: nil),
            HTTPResponse(status: 401, data: Data(), retryAfter: nil),
            HTTPResponse(status: 401, data: Data(), retryAfter: nil),
            HTTPResponse(status: 401, data: Data(), retryAfter: nil),
        ])
        var config = SourceConfiguration(id: "daytona", integration: .daytona, label: "Personal")
        config.credentialFile = credential.path
        let sources = try await LiveDaytonaIntegration(configuration: config, client: client).fetchSources()
        XCTAssertEqual(sources[0].compute?.resources.count, 2)
        XCTAssertTrue(sources[0].capabilities?.contains { $0.id == "limits" && $0.status == .accessRequired } == true)
        XCTAssertTrue(sources[0].capabilities?.contains { $0.id == "spending" && $0.status == .accessRequired } == true)
        XCTAssertTrue(sources[0].hasLimitedAccess)
        let requests = await client.urls
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests[1].contains("cursor=second-page"))
        XCTAssertTrue(requests.allSatisfy { !$0.contains("fixture-only") })
    }

    func testModalCurrentDayReplacesDailyBucketWithoutDoubleCounting() throws {
        let day = UsageCalendar.dateString(now)
        let month = UsageCalendar.dateString(UsageCalendar.monthStart(now))
        let daily = try json("""
        [{"object_id":"app","description":"Worker","interval_start":"\(month)T00:00:00","cost":"2.50"},
         {"object_id":"app","description":"Worker","interval_start":"\(day)T00:00:00","cost":"100"}]
        """)
        let hourly = try json("""
        [{"object_id":"app","description":"Worker","interval_start":"\(day)T00:00:00","cost":"3"},
         {"object_id":"app","description":"Worker","interval_start":"\(day)T01:00:00","cost":"4"}]
        """)
        let containers = try json(#"[{"container_id":"container-1","app_name":"Worker","start_time":"2026-09-11 00:00:00+00:00"}]"#)
        let source = try LiveModalIntegration.normalize(containers: containers, month: daily, today: hourly,
            configuration: SourceConfiguration(id: "modal-a", integration: .modal, label: "A"), now: now)
        let compute = try XCTUnwrap(source.compute)
        XCTAssertEqual(try XCTUnwrap(compute.spent), 9.5, accuracy: 0.00001)
        XCTAssertEqual(compute.dailySpend.reduce(0, +), 9.5, accuracy: 0.00001)
        XCTAssertNil(compute.budget)
        XCTAssertNil(compute.hourlyRate)
        XCTAssertNil(compute.allocatedCPU)
        XCTAssertEqual(compute.resourceNoun, "containers")
        XCTAssertNotNil(compute.resources[0].startedAt)
    }

    func testOpenAICostsAreAccountScopedAndMissingCountsAreNotZero() throws {
        let start = UsageCalendar.monthStart(now).timeIntervalSince1970
        let buckets = try json("""
        [{"start_time":\(start),"results":[
          {"amount":{"value":5.5,"currency":"usd"},"project_id":"project-a"},
          {"amount":{"value":2,"currency":"usd"},"project_id":null}]}]
        """).array!
        let source = try LiveOpenAIIntegration.normalize(buckets: buckets,
            configuration: SourceConfiguration(id: "api-a", integration: .openaiAPI, label: "Personal"), now: now)
        let spend = try XCTUnwrap(source.spend)
        XCTAssertEqual(spend.spent, 7.5)
        XCTAssertEqual(spend.breakdown.reduce(0) { $0 + $1.spent }, spend.spent)
        XCTAssertEqual(spend.dailySpend.reduce(0, +), spend.spent)
        XCTAssertNil(spend.budget)
        XCTAssertTrue(spend.breakdown.allSatisfy { $0.requests == nil && $0.tokens == nil })
        XCTAssertThrowsError(try LiveOpenAIIntegration.normalize(buckets: buckets + buckets,
            configuration: SourceConfiguration(id: "api-a", integration: .openaiAPI, label: "Personal"), now: now))
    }

    func testModalFetchUsesOneBillingRequestAndPartitionsCurrentDay() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent(".env")
        try Data("MODAL_TOKEN_ID=fixture-id\nMODAL_TOKEN_SECRET=fixture-secret\n".utf8).write(to: credential)
        var config = SourceConfiguration(id: "modal", integration: .modal, label: "Fixture")
        config.credentialFile = credential.path
        config.environment = "fixture-env"
        let today = UsageCalendar.dateString(.now)
        let runner = ModalFixtureRunner(billing: Data("""
        [{"object_id":"app","interval_start":"\(today)T00:00:00","cost":"7.25"}]
        """.utf8))
        let source = try await LiveModalIntegration(configuration: config, executable: "/fixture/uvx", runner: runner).fetchSources()[0]
        XCTAssertEqual(try XCTUnwrap(source.compute?.spent), 7.25, accuracy: 0.00001)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.filter { $0.contains("billing") }.count, 1)
        XCTAssertTrue(calls.allSatisfy { $0.starts(with: ["--offline", "--from", "modal==1.5.5", "modal"]) })
        XCTAssertFalse(calls.joined().contains("fixture-secret"))
        let environments = await runner.environments
        XCTAssertTrue(environments.allSatisfy { $0["MODAL_ENVIRONMENT"] == "fixture-env" && $0["TZ"] == "UTC" })
    }

    func testErrorTitlesDistinguishTransientFailureFromPermissions() {
        XCTAssertEqual(IntegrationError.timeout.title, "Unavailable")
        XCTAssertEqual(IntegrationError.permission("Denied").title, "Access required")
        XCTAssertEqual(IntegrationError.authentication("Expired").title, "Connect account")
    }

    func testCodexLoginUsesBrowserLauncherAndRejectsDuplicateIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = FixtureBrowser()
        let authenticator = CodexAuthenticator(executable: "/fixture/codex", browser: browser,
            makeSession: { _, _ in FixtureCodexSession(email: "new@example.test") })
        let login = try await authenticator.signIn(profile: directory.path, existingEmails: ["existing@example.test"])
        XCTAssertEqual(login.email, "new@example.test")
        XCTAssertEqual(login.profile, directory.path)
        let calls = await browser.urls
        XCTAssertEqual(calls, ["https://auth.openai.com/fixture"])
        do {
            _ = try await authenticator.signIn(profile: directory.path, existingEmails: ["NEW@example.test"])
            XCTFail("Duplicate account must be rejected")
        } catch let error as IntegrationError {
            XCTAssertTrue(error.errorDescription?.contains("already connected") == true)
        }
    }

    func testHeadlessCodexLoginRejectsUntrustedAuthURLBeforeOpeningBrowser() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = FixtureBrowser()
        let authenticator = CodexAuthenticator(executable: "/fixture/codex", browser: browser,
            makeSession: { _, _ in FixtureCodexSession(email: "new@example.test", address: "https://auth.openai.com.example.test/login") })
        do {
            _ = try await authenticator.signIn(profile: directory.path, existingEmails: [])
            XCTFail("Unexpected authentication origin must be rejected")
        } catch let error as IntegrationError {
            if case .invalidResponse = error {} else { XCTFail("Unexpected error") }
        }
        let calls = await browser.urls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDeviceCodeReturnsInstructionsWithoutOpeningAnyBrowser() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let browser = FixtureBrowser()
        let instructions = InstructionRecorder()
        let authenticator = CodexAuthenticator(executable: "/fixture/codex", browser: browser,
            makeSession: { _, _ in FixtureCodexSession(email: "new@example.test") })
        _ = try await authenticator.signIn(profile: directory.path, existingEmails: [], method: .deviceCode) {
            await instructions.record($0)
        }
        let calls = await browser.urls
        let result = await instructions.value
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(result?.userCode, "TEST-1234")
        XCTAssertEqual(result?.url.absoluteString, "https://auth.openai.com/fixture")
        XCTAssertEqual(result?.browserOpened, false)
    }

    func testFailedBrowserLaunchStillOffersManualSignInLink() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instructions = InstructionRecorder()
        let authenticator = CodexAuthenticator(executable: "/fixture/codex", browser: FixtureBrowser(succeeds: false),
            makeSession: { _, _ in FixtureCodexSession(email: "new@example.test") })
        _ = try await authenticator.signIn(profile: directory.path, existingEmails: []) { await instructions.record($0) }
        let result = await instructions.value
        XCTAssertEqual(result?.browserOpened, false)
        XCTAssertNotNil(result?.url)
    }

    @MainActor func testDefaultBrowserAdapterUsesSystemLauncherWithoutCLI() async {
        var received: URL?
        let browser = DefaultBrowserOpener(launch: { received = $0; return true })
        let url = URL(string: "https://auth.openai.com/fixture")!
        let opened = await browser.open(url)
        XCTAssertTrue(opened)
        XCTAssertEqual(received, url)
    }

    func testCodexLoginCommitPreservesConcurrentConfigEdits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        var account = SourceConfiguration(id: "codex", integration: .codex, label: "Edited label")
        account.codexHome = "/fixture/original"
        let config = IntegrationConfiguration(sources: [account, SourceConfiguration(id: "mac", integration: .macStorage, label: "Added while signing in")])
        try config.save(to: url)
        try CodexAuthenticator.save(CodexLogin(profile: "/fixture/reconnected", email: "new@example.test"),
                                    sourceID: "codex", originalProfile: "/fixture/original", to: url)
        let updated = try IntegrationConfiguration.load(from: url)
        XCTAssertEqual(updated.sources.count, 2)
        XCTAssertEqual(updated.sources[0].label, "Edited label")
        XCTAssertEqual(updated.sources[0].codexHome, "/fixture/reconnected")
        XCTAssertThrowsError(try CodexAuthenticator.save(CodexLogin(profile: "/fixture/other", email: "new@example.test"),
                                                       sourceID: "codex", originalProfile: "/fixture/original", to: url))
    }

    func testOpenAIDeniedUsageReportsActionablePermissionError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credential = directory.appendingPathComponent(".env")
        try Data("PERSON_KEY=fixture-not-secret\n".utf8).write(to: credential)
        var config = SourceConfiguration(id: "api", integration: .openaiAPI, label: "Personal")
        config.credentialFile = credential.path; config.credentialVariables = ["OPENAI_ADMIN_KEY": "PERSON_KEY"]
        let client = FixtureHTTPClient([HTTPResponse(status: 403, data: Data(), retryAfter: nil)])
        do {
            _ = try await LiveOpenAIIntegration(configuration: config, client: client).fetchSources()
            XCTFail("Permission error expected")
        } catch let error as IntegrationError {
            XCTAssertTrue(error.errorDescription?.contains("api.usage.read") == true)
            XCTAssertFalse(error.errorDescription?.contains("fixture-not-secret") == true)
        }
    }

    func testWindowsSingleDriveResponseAndVirtualMountStaySeparate() throws {
        let drives = try LiveWindowsStorageIntegration.normalize(json(#"{"DeviceID":"C:","VolumeName":"System","DriveType":3,"Size":1000000000000,"FreeSpace":10000000000}"#))
        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(drives[0].usedPercent, 99)
        XCTAssertEqual(drives[0].freeGB, 10)
        XCTAssertTrue(drives[0].historyGB.isEmpty)
        XCTAssertTrue(drives[0].breakdown.isEmpty)
        XCTAssertThrowsError(try LiveWindowsStorageIntegration.normalize(json(#"[{"DeviceID":"C:","DriveType":3,"Size":10,"FreeSpace":20}]"#)))
    }

    func testCommandRunnerDrainsPipesAndTimesOutOnlyItsChild() async throws {
        let runner = CommandRunner()
        let result = try await runner.run(executable: "/usr/bin/printf", arguments: ["hello"], environment: [:], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello")
        do {
            _ = try await runner.run(executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 0.05)
            XCTFail("Timeout expected")
        } catch let error as IntegrationError {
            if case .timeout = error {} else { XCTFail("Expected timeout") }
        }
    }

    @MainActor
    func testFailedAccountKeepsItsOwnTimestampWithoutDiscardingSibling() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alpha = sampleSource(id: "alpha", percent: 55, date: now)
        let beta = sampleSource(id: "beta", percent: 10, date: now)
        var newerBeta = beta; newerBeta.observedAt = now.addingTimeInterval(120)
        let a = ScriptedAccount(source: alpha, script: [alpha, nil])
        let b = ScriptedAccount(source: beta, script: [beta, newerBeta])
        let cache = SnapshotCache(url: directory.appendingPathComponent("cache.json"))
        let defaults = UserDefaults(suiteName: "com.pranjal.usage.tests.\(UUID())")!
        let store = UsageStore(registry: IntegrationRegistry(adapters: [a, b], origin: .live), defaults: defaults, cache: cache)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(store.sources.count, 2)
        XCTAssertTrue(try XCTUnwrap(store.sources.first { $0.id == "alpha" }).isStale)
        XCTAssertEqual(store.sources.first { $0.id == "alpha" }?.observedAt, now)
        XCTAssertEqual(store.sources.first { $0.id == "beta" }?.observedAt, newerBeta.observedAt)
        XCTAssertFalse(try XCTUnwrap(store.sources.first { $0.id == "beta" }).isStale)
        XCTAssertEqual(store.failures.count, 1)
        XCTAssertFalse(store.addSource(.codex, label: "Must not clone live data"))
        XCTAssertEqual(cache.load().count, 2)
        XCTAssertTrue(cache.load().allSatisfy(\.isStale))
    }

    @MainActor
    func testFailedFirstFetchCreatesUnavailableSourceNotDemoData() async throws {
        let source = sampleSource(id: "missing", percent: 40, date: now)
        let adapter = ScriptedAccount(source: source, script: [nil])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageStore(registry: IntegrationRegistry(adapters: [adapter], origin: .live),
            defaults: UserDefaults(suiteName: "com.pranjal.usage.tests.\(UUID())")!, cache: SnapshotCache(url: directory.appendingPathComponent("cache.json")))
        await store.refresh()
        XCTAssertEqual(store.sources.count, 1)
        XCTAssertNotNil(store.sources[0].unavailable)
        XCTAssertNil(store.sources[0].quota)
        XCTAssertEqual(store.sources[0].origin, .live)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func response(_ text: String) -> HTTPResponse { HTTPResponse(status: 200, data: Data(text.utf8), retryAfter: nil) }
    private func sampleSource(id: String, percent: Double, date: Date) -> UsageSource {
        UsageSource(id: id, integration: .codex, account: id, observedAt: date,
                    payload: .quota(QuotaUsage(windows: [QuotaWindow(label: "Weekly", usedPercent: percent, resetsAt: nil, durationMinutes: 10080)])), origin: .live)
    }
}

@available(macOS 14.0, *)
private actor FixtureHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private(set) var urls: [String] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        urls.append(request.url!.absoluteString)
        guard !responses.isEmpty else { throw IntegrationError.invalidResponse("Fixture exhausted") }
        return responses.removeFirst()
    }
}

@available(macOS 14.0, *)
private actor ModalFixtureRunner: CommandRunning {
    let billing: Data
    private(set) var calls: [[String]] = []
    private(set) var environments: [[String: String]] = []
    init(billing: Data) { self.billing = billing }
    func run(executable: String, arguments: [String], environment: [String: String], timeout: Double) async throws -> CommandOutput {
        calls.append(arguments)
        environments.append(environment)
        return CommandOutput(status: 0, stdout: arguments.contains("billing") ? billing : Data("[]".utf8), stderr: Data())
    }
}

@available(macOS 14.0, *)
private struct FixtureCodexSession: CodexServing {
    var email: String
    var address = "https://auth.openai.com/fixture"
    func initialize() async throws {}
    func close(with error: Error) {}
    func request(_ method: String, params: [String: JSONValue], timeout: Double) async throws -> JSONValue {
        if method == "account/login/start" {
            return params["type"]?.string == "chatgptDeviceCode"
                ? .object(["verificationUrl": .string(address), "userCode": .string("TEST-1234")])
                : .object(["authUrl": .string(address)])
        }
        return .object(["account": .object(["type": .string("chatgpt"), "email": .string(email)])])
    }
    func waitForNotification(_ method: String, timeout: Double) async throws -> JSONValue {
        .object(["success": .bool(true)])
    }
}

@available(macOS 14.0, *)
private actor FixtureBrowser: BrowserOpening {
    private(set) var urls: [String] = []
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    func open(_ url: URL) async -> Bool { urls.append(url.absoluteString); return succeeds }
}

@available(macOS 14.0, *)
private actor InstructionRecorder {
    private(set) var value: CodexLoginInstructions?
    func record(_ instructions: CodexLoginInstructions) { value = instructions }
}

@available(macOS 14.0, *)
private actor ScriptedAccount: UsageIntegration {
    nonisolated let id = IntegrationID.codex
    nonisolated let descriptor: IntegrationDescriptor?
    private var script: [UsageSource?]
    init(source: UsageSource, script: [UsageSource?]) {
        descriptor = IntegrationDescriptor(sourceID: source.id, integration: .codex, label: source.account)
        self.script = script
    }
    func fetchSources() async throws -> [UsageSource] {
        guard !script.isEmpty, let value = script.removeFirst() else { throw IntegrationError.authentication("Reconnect this account.") }
        return [value]
    }
}
