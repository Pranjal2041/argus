import XCTest

/// This is deliberately a source-parity test, not another reimplementation of
/// Usage's behavior in test expectations. Provider fixes belong in the baseline.
final class OriginalUsageSourceTests: XCTestCase {
    private var package: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testOriginalProviderAndTransportImplementationsAreCopiedUnchanged() throws {
        let root = package.appendingPathComponent("vendor/usage/integrations")
        let adapted: Set<String> = ["Configuration.swift", "ConnectionSetup.swift", "Integration.swift",
            "codex/BrowserOpening.swift", "codex/CodexAuthentication.swift", "claude/ClaudeAuthentication.swift"]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard !adapted.contains(relative) else { continue }
            let original = try String(contentsOf: url)
            var embedded = try normalized("integrations/" + relative)
            if relative == "CommandRunner.swift" {
                // An extension used only by added private-profile providers;
                // original providers keep the original subprocess environment.
                embedded = embedded.replacingOccurrences(of:
                    "        // Added private-profile integrations must not inherit the host's login.\n" +
                    "        if environment[\"HOME\"] != nil { inherited = UsageProcessEnvironment.make(overrides: environment) }\n", with: "")
            }
            if relative == "codex/LiveCodexIntegration.swift" {
                // The same original guard handles both a missing login and an
                // API-key login. Its text must not claim all failures are API keys.
                embedded = embedded.replacingOccurrences(of:
                    "This profile has no active ChatGPT login for usage. Reconnect this account.",
                    with: "Sign in with a ChatGPT account. API-key logins do not expose ChatGPT quota windows.")
            }
            XCTAssertEqual(embedded, original, relative)
            checked += 1
        }
        XCTAssertEqual(checked, 22, "Every original provider, transport, and cache must remain covered")
    }

    func testRegistryFetchAndStoreRefreshAreTheOriginalImplementation() throws {
        let originalRegistry = try original("integrations/Integration.swift")
        let registry = try normalized("integrations/Integration.swift")
        XCTAssertEqual(try between(registry, "    func fetchAll()", "\n}\n"),
                       try between(originalRegistry, "    func fetchAll()", "\n}\n"))
        let upstreamStore = try original("Sources/Core/UsageStore.swift")
        let embeddedStore = try normalized("Sources/Core/UsageStore.swift")
        let refresh = try between(embeddedStore, "    func refreshFromUsage(", "    func reloadCollectorConfiguration()")
            .replacingOccurrences(of: "func refreshFromUsage(", with: "func refresh(")
        XCTAssertEqual(refresh, try between(upstreamStore, "    func refresh(", "    func authorizeSavedCredential("))
    }

    func testClaudeOAuthDiffIsLimitedToCredentialOwnership() throws {
        let baseline = try original("integrations/claude/ClaudeAuthentication.swift")
            .replacingOccurrences(of: "\"usage-credential-", with: "\"argus-usage-credential-")
            .replacingOccurrences(of: "if let originalReference, !config.sources.contains",
                                  with: "if let originalReference, originalReference.hasPrefix(\"argus-usage-\"), !config.sources.contains")
        XCTAssertEqual(try normalized("integrations/claude/ClaudeAuthentication.swift"), baseline)
    }

    func testRecurringRefreshRetainsTheOriginalSleepThenRefreshLoop() throws {
        let originalView = try original("Sources/UI/RootView.swift")
        let controller = try String(contentsOf: package.appendingPathComponent("Sources/UsageKit/UsageController.swift"))
        let loop = "            while !Task.isCancelled {\n" +
            "                do { try await Task.sleep(for: .seconds(store.refreshInterval)) } catch { break }\n" +
            "                await store.refresh()\n" +
            "            }"
        XCTAssertTrue(originalView.contains(loop))
        XCTAssertTrue(controller.contains(loop.replacingOccurrences(of: "store.refreshInterval", with: "refreshSeconds")
            .replacingOccurrences(of: "await store.refresh()", with: "await refresh()")))
    }

    func testWorkspaceEventsCannotAddAnotherAutomaticCollectionDriver() throws {
        let service = try String(contentsOf: package.appendingPathComponent("Sources/UniversalTmuxMac/WorkspaceServices.swift"))
        let recovery = try between(service, "        networkObserver =", "\n    }\n")
        XCTAssertFalse(recovery.contains("usage"), "Route recovery must not trigger provider requests")
        XCTAssertFalse(service.contains("usageRefreshRequested"))
        XCTAssertTrue(service.contains("!commands.isEmpty {"), "The second task is only for explicit refresh commands")
    }

    func testCodexSignInDiffIsLimitedToBrowserHandoff() throws {
        let baseline = try between(original("integrations/codex/CodexAuthentication.swift"),
            "    func signIn(", "    /// Re-read before committing")
            .replacingOccurrences(of: "method: CodexLoginMethod = .browser,\n",
                                  with: "method: CodexLoginMethod = .browser, opensBrowser: Bool = true,\n")
            .replacingOccurrences(of: "let opened = method == .browser ?", with: "let opened = method == .browser && opensBrowser ?")
            .replacingOccurrences(of: "await onInstructions(CodexLoginInstructions(url: url, userCode: code, browserOpened: opened))",
                with: "await onInstructions(CodexLoginInstructions(url: url, userCode: code, browserOpened: opened,\n            opensBrowserAutomatically: method == .browser))")
        XCTAssertEqual(try between(normalized("integrations/codex/CodexAuthentication.swift"),
            "    func signIn(", "    /// Re-read before committing"), baseline)
    }

    private func original(_ path: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("vendor/usage/" + path))
    }
    private func normalized(_ path: String) throws -> String {
        try String(contentsOf: package.appendingPathComponent("Sources/UsageKit/" + path))
            .replacingOccurrences(of: "@available(macOS 14.0, *)\n", with: "")
    }
    private func between(_ source: String, _ start: String, _ end: String) throws -> String {
        let begin = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let finish = try XCTUnwrap(source.range(of: end, range: begin..<source.endIndex)?.lowerBound)
        return String(source[begin..<finish])
    }
}
