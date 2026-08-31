package rendersource

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestResolveCodexUsesMatchingAuthoritativeMarkdown(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	source := `## Result

| Condition | Exact |
|---|---:|
| Gold answer | **0.42** |

\[
R_{\rm TP}=D_{\rm KL}(p^*\Vert p)-D_{\rm KL}(p^*\Vert q_{c,\lambda}).
\]

The variance term comes from the log normalizer, not an added regularizer.`
	writeCodex(t, home, "matching.jsonl", cwd, source)
	writeCodex(t, home, "newer-unrelated.jsonl", cwd,
		"The deployment finished successfully and all unrelated service checks passed without errors.")

	screen := `## Result
Condition Exact
Gold answer 0.42
[
R_{\rm TP}=D_{\rm KL}(p^*\Vert p)-D_{\rm KL}(p^*\Vert q_{c,\lambda}).
]
The variance term comes from the log normalizer, not an added regularizer.`
	got, err := Resolve(home, cwd, screen)
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != source {
		t.Fatalf("resolved wrong source:\n%s", got.Source)
	}
	if got.Origin != "codex-transcript" || got.Confidence < 0.58 {
		t.Fatalf("unexpected provenance: %#v", got)
	}
}

func TestResolveUsesExactTranscriptFromCustomCodexHome(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	source := `## Custom home result

The exact process-owned transcript preserves this complete response with enough distinctive words to prove the visible overlap.`
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "20", "rollout-custom.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant",
			"content": []map[string]any{{"type": "output_text", "text": source}},
		}},
	)

	got, err := ResolveWithTranscript(home, cwd,
		"Custom home result The exact process-owned transcript preserves this complete response with enough distinctive words to prove the visible overlap.",
		TranscriptRef{Provider: "codex", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != source || got.Origin != "codex-transcript" {
		t.Fatalf("unexpected custom-home result: %#v", got)
	}
}

func TestResolveClaudeTextBlocks(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	source := "# Finding\n\nThe **measured value** is $x^2 + y^2$, with a stable confidence interval."
	path := filepath.Join(home, ".claude", "projects", claudeProjectKey(cwd), "session.jsonl")
	writeLines(t, path,
		map[string]any{"type": "assistant", "cwd": cwd, "message": map[string]any{
			"role": "assistant", "content": []map[string]any{{"type": "text", "text": source}},
		}},
	)

	got, err := Resolve(home, cwd,
		"# Finding\n\nThe measured value is x^2 + y^2, with a stable confidence interval.")
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != source || got.Origin != "claude-transcript" {
		t.Fatalf("unexpected result: %#v", got)
	}
}

func TestExactClaudeTranscriptKeepsOneActiveTurnAcrossToolResults(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	path := filepath.Join(home, ".claude-custom", "projects", "project", "session.jsonl")
	first := "I found the shared source-selection failure and am validating the provider-independent transcript contract."
	last := "The remaining work is to preserve every authored progress block in this active turn across intervening tool results."
	writeLines(t, path,
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": "Fix the renderer.",
		}},
		map[string]any{"type": "assistant", "cwd": cwd, "message": map[string]any{
			"role": "assistant", "stop_reason": "tool_use",
			"content": []map[string]any{{"type": "text", "text": first}},
		}},
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "tool_result", "content": "ok"}},
		}},
		map[string]any{"type": "assistant", "cwd": filepath.Join(cwd, "nested"), "message": map[string]any{
			"role": "assistant", "stop_reason": "tool_use",
			"content": []map[string]any{{"type": "text", "text": last}},
		}},
	)

	got, err := ResolveWithTranscript(home, cwd, last, TranscriptRef{Provider: "claude", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	want := first + "\n\n" + last
	if got.Source != want || got.Origin != "claude-transcript" {
		t.Fatalf("active Claude source = %#v, want %q", got, want)
	}
}

func TestExactClaudeTranscriptUsesFinalTextFromCompletedTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	path := filepath.Join(home, ".claude-custom", "projects", "project", "session.jsonl")
	progress := "I am checking the implementation before reporting the completed result to the user."
	final := "The implementation is complete and the full authored document now renders from the exact process-owned transcript."
	writeLines(t, path,
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "text", "text": "Complete it."}},
		}},
		map[string]any{"type": "assistant", "cwd": cwd, "message": map[string]any{
			"role": "assistant", "stop_reason": "tool_use",
			"content": []map[string]any{{"type": "text", "text": progress}},
		}},
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": []map[string]any{{"type": "tool_result", "content": "ok"}},
		}},
		map[string]any{"type": "assistant", "cwd": cwd, "message": map[string]any{
			"role": "assistant", "stop_reason": "end_turn",
			"content": []map[string]any{{"type": "text", "text": final}},
		}},
	)

	got, err := ResolveWithTranscript(home, cwd, final, TranscriptRef{Provider: "claude", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != final {
		t.Fatalf("completed Claude source = %q, want final text %q", got.Source, final)
	}
}

func TestExactTranscriptDoesNotResurrectPreviousTurnBeforeAgentResponds(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	path := filepath.Join(home, ".claude-custom", "projects", "project", "session.jsonl")
	previous := "The previous response is complete and has enough distinctive visible text to match the pane with confidence."
	writeLines(t, path,
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": "First turn.",
		}},
		map[string]any{"type": "assistant", "cwd": cwd, "message": map[string]any{
			"role": "assistant", "stop_reason": "end_turn",
			"content": []map[string]any{{"type": "text", "text": previous}},
		}},
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": "A new turn with no response yet.",
		}},
	)

	_, err := ResolveWithTranscript(home, cwd, previous, TranscriptRef{Provider: "claude", Path: path})
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected exact current empty turn to reject stale source, got %v", err)
	}
}

func TestClaudeProjectRootUsesNearestEncodedWorkingDirectory(t *testing.T) {
	root := t.TempDir()
	project := filepath.Join(string(filepath.Separator), "Users", "alice", "work", "learning_to_sleep")
	encoded := filepath.Join(root, "-Users-alice-work-learning-to-sleep")
	if err := os.MkdirAll(encoded, 0o755); err != nil {
		t.Fatal(err)
	}

	got, ok := claudeProjectRoot(root, filepath.Join(project, "nested", "src"))
	if !ok || got != encoded {
		t.Fatalf("wanted nearest encoded project %q, got %q (ok=%v)", encoded, got, ok)
	}
}

func TestResolveRejectsUnrelatedTranscript(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	writeCodex(t, home, "unrelated.jsonl", cwd,
		"The deployment finished successfully and all unrelated service checks passed without errors.")
	_, err := Resolve(home, cwd,
		"GPU utilization reached one hundred percent while the mathematical oracle scored the final batch.")
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected ErrNoMatch, got %v", err)
	}
}

func TestResolveRejectsMatchingTranscriptFromDifferentWorkingDirectory(t *testing.T) {
	home := t.TempDir()
	wantedCWD := filepath.Join(home, "wanted")
	otherCWD := filepath.Join(home, "other")
	source := "## Exact result\n\nThe measured tensor contraction is stable across every validation shard."
	writeCodex(t, home, "wrong-project.jsonl", otherCWD, source)

	_, err := Resolve(home, wantedCWD, source)
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected cwd-mismatched transcript to be rejected, got %v", err)
	}
}

func TestResolveWithoutReliableCWDUsesScreenMatch(t *testing.T) {
	home := t.TempDir()
	actualCWD := filepath.Join(home, "spatial_bench")
	source := `## Spatial UE review

The warehouse coverage table identifies reading as the only missing capability across all forty evaluated tasks.`
	writeCodex(t, home, "windows-panel.jsonl", actualCWD, source)

	got, err := Resolve(home, "",
		"Spatial UE review The warehouse coverage table identifies reading as the only missing capability across all forty evaluated tasks.")
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != source || got.Origin != "codex-transcript" {
		t.Fatalf("unexpected unscoped Windows result: %#v", got)
	}
}

func TestResolvePrefersFinalAnswerNearestPromptOverPerfectProgressMatch(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	progress := "The derivation is now clear and I am checking the cited source before giving the final result."
	final := `## Final result

The exact reward is \(R_{\rm TP}=0.42\), and this is the answer that belongs immediately above the prompt.`
	writeCodexMessages(t, home, "session.jsonl", cwd, progress, final)
	screen := progress + `

## Final result
The exact reward is R_{\rm TP}=0.42, and this is the answer that belongs immediately above the prompt.

› Implement {feature}`

	got, err := Resolve(home, cwd, screen)
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != final {
		t.Fatalf("wanted final answer, got %q", got.Source)
	}
}

func TestResolveUsesCurrentLongAnswerWhenOnlyItsPrefixIsOnScreen(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	previous := `Yes—enormously. If the ansatz is exactly as written, this is an explicit disproof.

The certificate is short enough that independent verification should be straightforward.`
	currentPrefix := `I was solving the wrong generative problem. I searched directly in polynomial coefficient space and in established normal forms. Your construction was found by factoring through carefully chosen rational coordinates and arranging for every denominator to cancel.`
	current := currentPrefix + `

The missing idea is to organize the search around rational coordinates first, then impose exact pole cancellation. That changes both the parameterization and the equations one should solve.

In one sentence: I searched for special polynomials, while the successful object is a special rational factorization whose poles cancel to produce polynomials.`
	writeCodexMessages(t, home, "session.jsonl", cwd, previous, current)

	// This is the failure mode from the live open_conjecture pane: the TUI has
	// painted a complete previous turn plus only a prefix of the much longer
	// current turn. The authoritative result must still be the FULL current turn.
	screen := previous + "\n\n" + currentPrefix
	got, err := Resolve(home, cwd, screen)
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != current {
		t.Fatalf("wanted full current answer, got %q", got.Source)
	}
}

func TestResolvePrefersShortCurrentPrefixOverLongCompletePreviousTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	previous := `No data is missing for running and solving the reconstructed task.

However, some unrecoverable original data was logically generated: the unseen summons content, full backend, hidden payment details, unopened document contents, and unobserved database records. The environment is functionally complete and internally consistent, but not a byte-for-byte copy of the original.`
	currentPrefix := "Yes. The environment can now be built without adding anything else to the task. Lock the exact task."
	current := currentPrefix + `

Use the completed filing documents as the immutable observation set, then package the complete implementation and verification workflow described below.`
	writeCodexMessages(t, home, "session.jsonl", cwd, previous, current)

	// Codex can virtualize the rest of a newly completed response while leaving a
	// complete previous response in scrollback. Recency among proven matches is
	// authoritative; response length is not.
	got, err := Resolve(home, cwd, previous+"\n\n"+currentPrefix+"\n\nGoal achieved")
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != current {
		t.Fatalf("wanted current response, got %q", got.Source)
	}
}

func TestExactCodexTranscriptUsesShortVisiblePrefixOfNewestTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	previous := `Completed one full evaluation with a detailed score report, artifact inventory, and reproducible verification notes. The prior response is fully visible in terminal scrollback and would otherwise produce a stronger overlap score.`
	currentPrefix := "Here is the complete context. The precise task description given to Codex was:"
	current := currentPrefix + `

Using the supplied hydraulic project and field-observation package, produce a calibrated regulatory model, supporting report, and complete reproducible deliverable bundle. This full authored response continues well beyond the short prefix painted by the terminal.`
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "22", "rollout-live.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "final_answer",
			"content": []map[string]any{{"type": "output_text", "text": previous}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": "Continue with the current result."}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant",
			"content": []map[string]any{{"type": "output_text", "text": current}},
		}},
	)

	got, err := ResolveWithTranscript(home, cwd, previous+"\n\n"+currentPrefix,
		TranscriptRef{Provider: "codex", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != current {
		t.Fatalf("wanted newest exact-transcript answer, got %q", got.Source)
	}
}

func TestExactCodexTranscriptNeverFallsBackToPreviousTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	previous := `The previous response is fully visible and contains enough distinctive words to pass the normal transcript overlap threshold with very high confidence.`
	current := `A completely different newest response exists in the exact rollout but has not reached the terminal screen yet. It must not cause the renderer to resurrect the previous response.`
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "22", "rollout-live.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "final_answer",
			"content": []map[string]any{{"type": "output_text", "text": previous}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": "Start another turn."}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant",
			"content": []map[string]any{{"type": "output_text", "text": current}},
		}},
	)

	_, err := ResolveWithTranscript(home, cwd, previous,
		TranscriptRef{Provider: "codex", Path: path})
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected terminal fallback instead of previous turn, got %v", err)
	}
}

func TestExactCodexTranscriptKeepsAllMessagesInActiveTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	first := "I reproduced the renderer failure and identified the process-owned transcript that belongs to this exact panel."
	last := "The remaining issue is the handoff: multiple assistant progress messages belong to one active turn and must stay together."
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "23", "rollout-active.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": "Fix the renderer."}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "commentary",
			"content": []map[string]any{{"type": "output_text", "text": first}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{"type": "custom_tool_call"}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "commentary",
			"content": []map[string]any{{"type": "output_text", "text": last}},
		}},
	)

	got, err := ResolveWithTranscript(home, cwd, last,
		TranscriptRef{Provider: "codex", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	want := first + "\n\n" + last
	if got.Source != want {
		t.Fatalf("active turn source = %q, want %q", got.Source, want)
	}
}

func TestExactCodexTranscriptUsesFinalAnswerFromCompletedTurn(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	progress := "I am checking the implementation and running the focused regression suite before reporting the completed result."
	final := "The implementation is complete. Normal Codex and custom Codex homes both restore and render correctly."
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "23", "rollout-complete.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": "Implement it."}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "commentary",
			"content": []map[string]any{{"type": "output_text", "text": progress}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "final_answer",
			"content": []map[string]any{{"type": "output_text", "text": final}},
		}},
		map[string]any{"type": "event_msg", "payload": map[string]any{"type": "task_complete"}},
	)

	got, err := ResolveWithTranscript(home, cwd, final,
		TranscriptRef{Provider: "codex", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != final {
		t.Fatalf("completed turn source = %q, want final answer %q", got.Source, final)
	}
}

func TestExactCodexTranscriptAcceptsShortNewestAnswer(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	short := "Topping all four. 😎"
	path := filepath.Join(home, ".codex2", "sessions", "2026", "08", "23", "rollout-short.jsonl")
	writeLines(t, path,
		map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": "What would be better?"}},
		}},
		map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "final_answer",
			"content": []map[string]any{{"type": "output_text", "text": short}},
		}},
		map[string]any{"type": "event_msg", "payload": map[string]any{"type": "task_complete"}},
	)

	screen := "A previous detailed response remains above the prompt with plenty of unrelated terminal content.\n\n• Topping all four. 😎\n\n› Ask Codex to do anything"
	got, err := ResolveWithTranscript(home, cwd, screen,
		TranscriptRef{Provider: "codex", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != short {
		t.Fatalf("short exact source = %q, want %q", got.Source, short)
	}
}

func TestDirectoryScanStillRejectsShortAmbiguousAnswer(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	writeCodex(t, home, "short.jsonl", cwd, "Done.")
	_, err := Resolve(home, cwd, "A prior response has enough terminal words. Done. Ask Codex to do anything.")
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected unscoped short answer to remain rejected, got %v", err)
	}
}

func TestResolveDoesNotUpgradeToPreviousTurnWhenNewTailIsUnmatched(t *testing.T) {
	home := t.TempDir()
	cwd := filepath.Join(home, "project")
	previous := `The completed audit contains a verified determinant identity and a concise exact certificate for independent reproduction.`
	writeCodexMessages(t, home, "session.jsonl", cwd, previous)

	// A new response can appear before its structured transcript record is
	// flushed. Returning the previous turn is worse than retaining the exact
	// styled-terminal fallback, so substantial unmatched tail text must reject it.
	newTail := `A different investigation is now underway. It begins from a new coordinate system and follows an unrelated sequence of symbolic reductions. The current response continues with enough distinct prose to establish that the earlier certificate is no longer the answer nearest the prompt. Until this response is present in the transcript, the renderer must preserve the terminal snapshot instead of presenting stale authored Markdown from the prior turn.`
	_, err := Resolve(home, cwd, previous+"\n\n"+newTail)
	if !errors.Is(err, ErrNoMatch) {
		t.Fatalf("expected stale previous turn to be rejected, got %v", err)
	}
}

func writeCodex(t *testing.T, home, name, cwd, source string) {
	t.Helper()
	writeCodexMessages(t, home, name, cwd, source)
	path := filepath.Join(home, ".codex", "sessions", "2026", "07", "18", name)
	if name == "newer-unrelated.jsonl" {
		now := time.Now().Add(time.Minute)
		_ = os.Chtimes(path, now, now)
	}
}

func writeCodexMessages(t *testing.T, home, name, cwd string, sources ...string) {
	t.Helper()
	path := filepath.Join(home, ".codex", "sessions", "2026", "07", "18", name)
	values := []any{map[string]any{"type": "session_meta", "payload": map[string]any{"cwd": cwd}}}
	for index, source := range sources {
		values = append(values, map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "user",
			"content": []map[string]any{{"type": "input_text", "text": fmt.Sprintf("Turn %d", index+1)}},
		}})
		values = append(values, map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant", "phase": "final_answer",
			"content": []map[string]any{{"type": "output_text", "text": source}},
		}})
	}
	writeLines(t, path, values...)
}

func writeLines(t *testing.T, path string, values ...any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for _, value := range values {
		if err := enc.Encode(value); err != nil {
			t.Fatal(err)
		}
	}
}
