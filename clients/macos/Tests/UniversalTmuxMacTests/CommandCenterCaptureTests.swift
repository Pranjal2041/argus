import XCTest
@testable import UniversalTmuxMac

final class CommandCenterCaptureTests: XCTestCase {
    func testInterruptGrammarAndWrappedTimerNormalization() {
        for hint in ["esc to interrupt", "esc twice to interrupt", "Escape 2 times to interrupt", "/stop to interrupt"] {
            let first = "Useful result\n\nThinking · 3s (\(hint)) · (42c)\n❭ \n"
            let second = "Useful result\n\nThinking · 1m 12s (\(hint)) · (2985c)\n❭ \n"
            XCTAssertEqual(AgentTerminalChrome.contentKey(first), AgentTerminalChrome.contentKey(second))
            XCTAssertNotEqual(AgentTerminalChrome.contentKey(first), AgentTerminalChrome.contentKey(second.replacingOccurrences(of: "Useful result", with: "New result")))
            let chars = Array(hint)
            for split in 1..<chars.count {
                let wrapped = String(chars[..<split]) + "\n" + String(chars[split...])
                let lines = "Thinking (\(wrapped))\n❭ ".components(separatedBy: "\n")
                XCTAssertEqual(AgentTerminalChrome.interruptRows(lines), [0, 1], "\(hint), split \(split)")
            }
        }
        let history = "esc twice to interrupt\n" + String(repeating: "new output\n", count: 9)
        XCTAssertTrue(AgentTerminalChrome.interruptRows(history.components(separatedBy: "\n")).isEmpty)
    }

    func testRepeatedInterruptAndLiveComposerAreNotSubstantiveOutput() {
        let chrome = "⠦ Thinking · 1m 14s (esc twice to interrupt) · (2957c)\n────\n(bypass permissions on)\n❭ Guide Devin while it works\n────\nClaude Opus · ctrl+o details · opt+t thinking"
        XCTAssertTrue(ccCaptureLooksTransient(chrome, state: "working"))
        XCTAssertFalse(ccCaptureLooksTransient("API Error\n" + chrome, state: "working"))
        XCTAssertFalse(ccCaptureLooksTransient("Built the dashboard and verified all six routes.\n" + chrome, state: "working"))
        XCTAssertFalse(ccCaptureLooksTransient(chrome, state: "idle"))
        let tokenBar = chrome.components(separatedBy: "\n").dropLast().joined(separator: "\n") + "\nConfigured Model 5.5 · Context: 796k / 1.0M tokens (79%)"
        XCTAssertTrue(ccCaptureLooksTransient(tokenBar, state: "working"))
        XCTAssertEqual(AgentTerminalChrome.contentKey(tokenBar), AgentTerminalChrome.contentKey(tokenBar.replacingOccurrences(of: "796k", with: "797k")))
    }

    func testKeyboardInstructionsAndQuotedAnswerRemainSubstantive() {
        for answer in ["Press ctrl+x to cut the selected text, then paste it into the destination.",
                       "> This is a complete quoted answer with important instructions and results."] {
            XCTAssertFalse(ccCaptureLooksTransient(answer, state: "working"))
            XCTAssertNotEqual(AgentTerminalChrome.contentKey(answer), AgentTerminalChrome.contentKey(answer + " Changed."))
        }
    }

    func testStatusCommandPinsGPT6LunaHighAndKeepsConversationDurable() {
        let output = URL(fileURLWithPath: "/tmp/status.txt")
        let initial = CodexStatusCommand.initialArguments(finalMessageURL: output)
        let resumed = CodexStatusCommand.resumeArguments(
            sessionID: "019f630d-5663-7722-bc65-5fd298a497ec",
            finalMessageURL: output
        )

        XCTAssertEqual(CodexStatusCommand.model, "gpt-6-luna")
        XCTAssertEqual(CodexStatusCommand.model, AgentArtifactTitleProvider.model)
        XCTAssertEqual(initial.filter { $0.hasPrefix("gpt-") }, ["gpt-6-luna"])
        XCTAssertTrue(initial.contains("model_reasoning_effort=\"high\""))
        XCTAssertTrue(initial.contains("read-only"))
        XCTAssertFalse(initial.contains("--ephemeral"))
        XCTAssertEqual(Array(resumed.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(resumed.contains("019f630d-5663-7722-bc65-5fd298a497ec"))
        XCTAssertEqual(resumed.filter { $0.hasPrefix("gpt-") }, ["gpt-6-luna"])
        XCTAssertTrue(resumed.contains("model_reasoning_effort=\"high\""))
        XCTAssertFalse(resumed.contains("--ephemeral"))
    }

    func testStatusCommandParsesCodexSessionID() {
        let stream = #"{"type":"thread.started","thread_id":"019f630d-5663-7722-bc65-5fd298a497ec"}"#
            + "\n" + #"{"type":"turn.started"}"#
        XCTAssertEqual(
            CodexStatusCommand.sessionID(in: stream),
            "019f630d-5663-7722-bc65-5fd298a497ec"
        )
    }

    func testWorkingChromeOnlyCaptureIsTransient() {
        let chrome = """
        ◦                 •

        ›

          · ~\\spatial_bench                         Goal achieved (1h 12m)
        """
        XCTAssertTrue(ccCaptureLooksTransient(chrome, state: "working"))
    }

    func testSameSparseCaptureIsAllowedWhenSessionIsIdle() {
        XCTAssertFalse(ccCaptureLooksTransient("›", state: "idle"))
    }

    func testShortErrorIsNeverDiscarded() {
        XCTAssertFalse(ccCaptureLooksTransient("API Error", state: "working"))
    }

    func testSubstantiveWorkingCaptureIsAccepted() {
        let output = "R8 progressed to 28 actions and 29 frames; verifier is still running."
        XCTAssertFalse(ccCaptureLooksTransient(output, state: "working"))
    }

    func testLiveWorkingSignalOverridesQuietModelLabels() {
        for label in ["idle", "look", "milestone"] {
            let generated = AgentStatus(label: label, oneLiner: "Tests completed.",
                                        lookAtThis: nil, updatedAt: Date())
            let reconciled = ccReconcileLiveState(generated, state: "working")
            XCTAssertEqual(reconciled.label, "working")
            XCTAssertEqual(reconciled.oneLiner, generated.oneLiner)
        }
    }

    func testLiveWorkingSignalDoesNotSuppressAttentionLabels() {
        for label in ["needs-decision", "stuck", "drifting", "no-progress"] {
            let generated = AgentStatus(label: label, oneLiner: "Action is needed.",
                                        lookAtThis: nil, updatedAt: Date())
            XCTAssertEqual(ccReconcileLiveState(generated, state: "working").label, label)
        }
    }

    func testStaleWorkingStateDoesNotOverrideCurrentIdle() {
        let generated = AgentStatus(label: "idle", oneLiner: "Done.",
                                    lookAtThis: nil, updatedAt: Date())
        XCTAssertEqual(ccReconcileLiveState(generated, state: "idle").label, "idle")
    }
}
