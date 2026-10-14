import AppKit
import SwiftUI
import XCTest
@testable import UniversalTmuxMac

final class AgentCLITests: XCTestCase {
    private let uuid = "019f630d-5663-7722-bc65-5fd298a497ec"

    func testDefaultsAndCapabilitiesPreserveExistingChoices() throws {
        let suite = "argus-agent-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for purpose in AgentTaskPurpose.allCases {
            XCTAssertEqual(purpose.selectedProvider(defaults: defaults), purpose.defaultProvider)
            defaults.set("devin", forKey: purpose.preferenceKey)
            XCTAssertEqual(purpose.selectedProvider(defaults: defaults), .devin)
            defaults.set("unknown-future-cli", forKey: purpose.preferenceKey)
            XCTAssertEqual(purpose.selectedProvider(defaults: defaults), purpose.defaultProvider)
        }
        XCTAssertEqual(AgentTaskPurpose.status.defaultProvider, .codex)
        XCTAssertEqual(AgentTaskPurpose.gitInsight.defaultProvider, .claude)
        XCTAssertEqual(AgentTaskPurpose.wrappedPersona.defaultProvider, .claude)
        XCTAssertFalse(AgentTaskPurpose.weeklyProgress.supportedProviders.contains(.claude))
    }

    func testAllAdaptersResumeOnlyAnExplicitConversation() {
        let file = URL(fileURLWithPath: "/tmp/result")
        for provider in AgentProvider.allCases {
            let id = provider == .devin ? "gentle-birch" : uuid
            let request = AgentGenerationRequest(provider: provider, purpose: .status, prompt: "question",
                conversation: AgentConversation(provider: provider, id: id))
            let args = AgentCLIRunner.arguments(request, directory: file, finalURL: file,
                exportURL: file, promptURL: file, configURL: file)
            XCTAssertTrue(args.contains(id))
            XCTAssertFalse(args.contains("--continue"))
            XCTAssertFalse(args.contains("--last"))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
            if provider == .devin {
                XCTAssertTrue(args.contains("--export"))
                XCTAssertTrue(args.contains("--prompt-file"))
                XCTAssertTrue(args.contains("auto"))
            }
            if provider == .claude {
                let index = args.firstIndex(of: "--tools")!
                XCTAssertEqual(args[index + 1], "")
            }
        }
    }

    func testReadOnlyDevinConfigPreservesModelButCannotWriteOrRunTools() {
        let config = AgentCLIRunner.devinConfiguration(writesWorkspace: false, directory: URL(fileURLWithPath: "/tmp/work"),
            userConfiguration: ["agent": ["model": "my-selected-model"], "permissions": ["allow": ["exec"]]])
        XCTAssertEqual((config["agent"] as? [String: String])?["model"], "my-selected-model")
        let deny = (config["permissions"] as? [String: [String]])?["deny"] ?? []
        for rule in ["Write(/**)", "exec", "edit", "mcp__*", "Fetch(*)"] { XCTAssertTrue(deny.contains(rule)) }
        XCTAssertEqual(config["subagents_enabled"] as? Bool, false)
        XCTAssertEqual(config["auto_update"] as? Bool, false)
    }

    func testATIFExtractionExcludesPrivateContentAndRespectsNewestTurn() throws {
        let data = Data(#"""
        {"schema_version":"ATIF-v1.7","session_id":"gentle-birch","steps":[
          {"source":"system","message":"PRIVATE SYSTEM"},
          {"source":"user","message":"question"},
          {"source":"agent","message":"checking","tool_calls":[{"arguments":"PRIVATE ARGUMENTS"}]},
          {"source":"agent","message":"# Final answer","reasoning_content":"PRIVATE REASONING"}]}
        """#.utf8)
        let result = try AgentCLIRunner.devinResult(data)
        XCTAssertEqual(result.text, "# Final answer")
        XCTAssertEqual(result.conversation, AgentConversation(provider: .devin, id: "gentle-birch"))
        let unanswered = Data(#"{"schema_version":"ATIF-v1.7","session_id":"gentle-birch","steps":[{"source":"agent","message":"old answer"},{"source":"user","message":"new question"}]}"#.utf8)
        let empty = try AgentCLIRunner.devinResult(unanswered)
        XCTAssertThrowsError(try AgentCLIRunner.validate(empty, for: AgentGenerationRequest(provider: .devin, purpose: .status, prompt: "")))
    }

    func testWorkspaceConfigurationCannotInheritSandboxEscapeRules() {
        let config = AgentCLIRunner.devinConfiguration(writesWorkspace: true, directory: URL(fileURLWithPath: "/tmp/work"),
            userConfiguration: ["sandbox": ["excluded": ["allow": ["Exec(**)"]], "denied_domains": ["blocked.example"]]])
        let sandbox = config["sandbox"] as? [String: Any]
        let exclusions = sandbox?["excluded"] as? [String: [String]]
        XCTAssertEqual(exclusions?["deny"], ["Exec(**)"])
        XCTAssertNil(exclusions?["allow"])
        XCTAssertEqual(sandbox?["denied_domains"] as? [String], ["blocked.example"])
        XCTAssertEqual((config["permissions"] as? [String: [String]])?["allow"], ["Write(/tmp/work/**)"])
        XCTAssertEqual((config["permissions"] as? [String: [String]])?["deny"], ["write", "edit", "mcp__*"])
    }

    func testProviderAndConversationMismatchesFailBeforeLaunching() async throws {
        let runner = AgentCLIRunner(executableOverride: URL(fileURLWithPath: "/does/not/exist"))
        do {
            _ = try await runner.run(AgentGenerationRequest(provider: .devin, purpose: .status, prompt: "",
                conversation: AgentConversation(provider: .codex, id: uuid)))
            XCTFail("cross-provider resume accepted")
        } catch AgentCLIError.providerMismatch {} catch { XCTFail("wrong failure: \(error)") }
        let request = AgentGenerationRequest(provider: .devin, purpose: .status, prompt: "",
            conversation: AgentConversation(provider: .devin, id: "first-thread"))
        let result = AgentGenerationResult(provider: .devin, text: "answer",
            conversation: AgentConversation(provider: .devin, id: "neighbor-thread"), costUSD: 0)
        XCTAssertThrowsError(try AgentCLIRunner.validate(result, for: request))
    }

    func testEveryAdapterUsesTheSharedProcessAndFinalAnswerContract() async throws {
        for provider in AgentProvider.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-cli-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("fixture")
            let id = provider == .devin ? "gentle-birch" : uuid
            let output: String
            switch provider {
            case .codex:
                output = "printf '%s' 'final answer' > \"$final\"\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"\(id)\"}'"
            case .claude:
                output = "printf '%s\\n' '{\"result\":\"final answer\",\"session_id\":\"\(id)\",\"total_cost_usd\":0.01}'"
            case .devin:
                output = "printf '%s' '{\"schema_version\":\"ATIF-v1.7\",\"session_id\":\"\(id)\",\"steps\":[{\"source\":\"agent\",\"message\":\"final answer\"}]}' > \"$export\""
            }
            let script = """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o) final="$2"; shift ;;
                --export) export="$2"; shift ;;
                --prompt-file) prompt="$2"; shift ;;
              esac
              shift
            done
            if [ -n "$prompt" ]; then [ -s "$prompt" ] || exit 19; else /bin/cat >/dev/null; fi
            \(output)
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let runner = AgentCLIRunner(executableOverride: executable)
            let result = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .status, prompt: "a fixture question"))
            XCTAssertEqual(result.text, "final answer")
            XCTAssertEqual(result.conversation, AgentConversation(provider: provider, id: id))
            let resumed = try await runner.run(AgentGenerationRequest(provider: provider, purpose: .status,
                prompt: "follow up", conversation: result.conversation))
            XCTAssertEqual(resumed.conversation, result.conversation)
        }
    }

    func testGitCachesAreSeparatedByProvider() {
        let keys = AgentProvider.allCases.map { GitInsights.key(hashes: ["abc"], level: "brief", provider: $0) }
        XCTAssertEqual(Set(keys).count, AgentProvider.allCases.count)
    }

    @MainActor
    func testProviderSettingsRenderAndReflectSelectionWithoutOpeningAWindow() throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let suite = "argus-agent-ui-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: Form { AgentProviderSettingsSection(defaults: defaults) }.formStyle(.grouped))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        func control(_ value: Any, depth: Int = 0) -> NSObject? {
            guard depth < 40, let node = value as? NSObject else { return nil }
            let ids = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            let found = node.responds(to: ids) ? node.perform(ids)?.takeUnretainedValue() as? String : nil
            if found == "agent-provider-status" { return node }
            let nodes = node.responds(to: children) ? node.perform(children)?.takeUnretainedValue() as? [Any] : nil
            return (nodes ?? []).compactMap { control($0, depth: depth + 1) }.first
        }
        let first = try XCTUnwrap(control(host))
        // Exercise the persisted-selection binding without opening a system
        // popup menu on the user's desktop.
        defaults.set("devin", forKey: AgentTaskPurpose.status.preferenceKey)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(AgentTaskPurpose.status.selectedProvider(defaults: defaults), .devin)
        let value = NSSelectorFromString("accessibilityValue")
        XCTAssertTrue(first.responds(to: value))
        let visibleValue = first.responds(to: value) ? first.perform(value)?.takeUnretainedValue() as? String : nil
        XCTAssertEqual(visibleValue, "Devin")
        if let path = ProcessInfo.processInfo.environment["UT_AGENT_SETTINGS_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func testLiveDevinStartAndResumeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["UT_TEST_LIVE_DEVIN"] == "1" else { throw XCTSkip("live CLI test not requested") }
        let first = try await AgentCLIRunner().run(AgentGenerationRequest(provider: .devin, purpose: .status,
            prompt: "This is an Argus integration check. Do not use tools. Reply with exactly ARGUS_START_OK.", timeout: 60))
        XCTAssertEqual(first.text.trimmingCharacters(in: .whitespacesAndNewlines), "ARGUS_START_OK")
        let second = try await AgentCLIRunner().run(AgentGenerationRequest(provider: .devin, purpose: .status,
            prompt: "Do not use tools. Reply with exactly ARGUS_RESUME_OK.", conversation: first.conversation, timeout: 60))
        XCTAssertEqual(second.text.trimmingCharacters(in: .whitespacesAndNewlines), "ARGUS_RESUME_OK")
        XCTAssertEqual(first.conversation, second.conversation)
    }

    @MainActor
    func testWeeklyBadgeReflectsProviderWithoutChangingUserSettings() throws {
        _ = NSApplication.shared
        let suite = "argus-agent-badge-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("devin", forKey: AgentTaskPurpose.weeklyProgress.preferenceKey)
        let host = NSHostingView(rootView: WeeklyProgressProviderBadge(scale: 1, defaults: defaults)
            .padding(20).background(Theme.appBackground))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 70)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        if let path = ProcessInfo.processInfo.environment["UT_AGENT_BADGE_SCREENSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
