package rendersource

import (
	"encoding/json"
	"errors"
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
	for _, source := range sources {
		values = append(values, map[string]any{"type": "response_item", "payload": map[string]any{
			"type": "message", "role": "assistant",
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
