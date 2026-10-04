package rendersource

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestVisibleMarkdownPreservesLabelsAndLiteralCode(t *testing.T) {
	for _, tc := range []struct{ source, want string }{
		{`See [the **nested** label](https://example.test/a_(b) "hidden title") now.`, "See the nested label now."},
		{"See [the reference][report].\n\n[report]: https://example.test/hidden", "See the reference."},
		{"`[literal](https://example.test/code)`", "[literal](https://example.test/code)"},
		{"```md\n[literal](https://example.test/code)\n```", "[literal](https://example.test/code)"},
		{"A &amp; B <https://example.test/visible>", "A & B https://example.test/visible"},
		{"| First | Second |\n|---|---|\n| One | Two |", "First Second One Two"},
	} {
		got := strings.Join(strings.Fields(visibleMarkdown(tc.source)), " ")
		if got != tc.want {
			t.Fatalf("visibleMarkdown(%q) = %q, want %q", tc.source, got, tc.want)
		}
	}
}

func TestResolveMatchesVisibleLinksAcrossProvidersAndCaptures(t *testing.T) {
	var source, plain, escaped strings.Builder
	source.WriteString("| Resource | Finding |\n|---|---|\n")
	plain.WriteString("Resource Finding\n")
	escaped.WriteString("Resource Finding\n")
	for i := range 24 {
		label := fmt.Sprintf("Resource %d", i)
		url := fmt.Sprintf("https://example.test/reports/%d?view=full", i)
		finding := fmt.Sprintf("Measured condition %d remains stable", i)
		fmt.Fprintf(&source, "| [%s](%s) | %s |\n", label, url, finding)
		fmt.Fprintf(&plain, "%s %s\n", label, finding)
		fmt.Fprintf(&escaped, "\x1b]8;id=row%d;%s\x1b\\%s\x1b]8;;\x1b\\ %s\n", i, url, label, finding)
	}
	for _, provider := range []string{"codex", "claude"} {
		for name, screen := range map[string]string{"plain": plain.String(), "osc8": escaped.String()} {
			for _, exact := range []bool{true, false} {
				t.Run(fmt.Sprintf("%s/%s/exact=%t", provider, name, exact), func(t *testing.T) {
					home := t.TempDir()
					path := writeProviderTurns(t, home, provider, source.String())
					ref := TranscriptRef{}
					if exact {
						ref = TranscriptRef{Provider: provider, Path: path}
					}
					got, err := ResolveWithTranscript(home, "", screen+"\n❯ Ready for input", ref)
					if err != nil || got.Source != strings.TrimSpace(source.String()) {
						t.Fatalf("visible link labels must match without changing authored Markdown: result=%#v err=%v", got, err)
					}
				})
			}
		}
	}
}

func TestRecordedDecorationsDoNotInvalidateAnswerOrHideNewProse(t *testing.T) {
	source := "The complete answer preserves the authored mathematical explanation with enough distinctive evidence to identify this response."
	for _, words := range []int{80, 240} {
		t.Run(fmt.Sprint(words), func(t *testing.T) {
			home := t.TempDir()
			path := filepath.Join(home, "session.jsonl")
			decoration := strings.Repeat("A recorded non answer status recap. ", words/6)
			writeLines(t, path,
				map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "stop_reason": "end_turn", "content": source}},
				map[string]any{"type": "system", "subtype": "away_summary", "content": decoration},
			)
			ref := TranscriptRef{Provider: "claude", Path: path}
			// A terminal may wrap the exact recorded text across arbitrary rows.
			screen := source + "\n※ recap: " + strings.ReplaceAll(decoration, ". ", ".\n") + "\n❯ Ready for input"
			got, err := ResolveWithTranscript(home, "", screen, ref)
			if err != nil || got.Source != source {
				t.Fatalf("recorded decoration invalidated the authored answer: %#v %v", got, err)
			}
			newProse := strings.Repeat("This unrecorded new response describes a separate investigation. ", 12)
			for _, staleScreen := range []string{source + "\n" + newProse + "\n" + decoration, screen + "\n" + newProse} {
				if _, err := ResolveWithTranscript(home, "", staleScreen, ref); !errors.Is(err, ErrNoMatch) {
					t.Fatalf("metadata must not hide unmatched new prose: %v", err)
				}
			}
			// Unknown system prose is not a license to ignore arbitrary screen tails.
			writeLines(t, path,
				map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": source}},
				map[string]any{"type": "system", "subtype": "unknown", "content": decoration},
			)
			if _, err := ResolveWithTranscript(home, "", screen, ref); !errors.Is(err, ErrNoMatch) {
				t.Fatalf("unrecognized prose must remain evidence against stale source: %v", err)
			}
		})
	}
}

func TestExactEmptyTurnBarrierAcrossProviders(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		t.Run(provider, func(t *testing.T) {
			home := t.TempDir()
			previous := "The previous answer is fully visible with enough distinctive evidence to identify the old response with confidence."
			path := writeProviderTurns(t, home, provider, previous, "")
			if _, err := ResolveWithTranscript(home, "", previous, TranscriptRef{Provider: provider, Path: path}); !errors.Is(err, ErrNoMatch) {
				t.Fatalf("a new unanswered turn must block stale source: %v", err)
			}
		})
	}
}

func writeProviderTurns(t *testing.T, home, provider string, sources ...string) string {
	t.Helper()
	path := filepath.Join(home, ".codex", "sessions", "transcript.jsonl")
	if provider == "claude" {
		path = filepath.Join(home, ".claude", "projects", "project", "transcript.jsonl")
	}
	var lines []any
	for _, source := range sources {
		if provider == "codex" {
			lines = append(lines, map[string]any{"type": "response_item", "payload": map[string]any{"type": "message", "role": "user", "content": []map[string]any{{"type": "input_text", "text": "Explain the next result."}}}})
			if source != "" {
				lines = append(lines, map[string]any{"type": "response_item", "payload": map[string]any{"type": "message", "role": "assistant", "phase": "final_answer", "content": []map[string]any{{"type": "output_text", "text": source}}}})
				lines = append(lines, map[string]any{"type": "event_msg", "payload": map[string]any{"type": "task_complete"}})
			}
		} else {
			lines = append(lines, map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": "Explain the next result."}})
			if source != "" {
				lines = append(lines, map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "stop_reason": "end_turn", "content": source}})
			}
		}
	}
	writeLines(t, path, lines...)
	return path
}

func TestHyperlinkMetadataCannotSupplyMatchEvidence(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		t.Run(provider, func(t *testing.T) {
			home := t.TempDir()
			source := "A completely unrelated answer with distinctive words that exist only in hidden hyperlink metadata."
			path := writeProviderTurns(t, home, provider, source)
			screen := "Unrelated terminal content precedes a link with a different visible label.\n\x1b]8;;https://example.test/" + strings.ReplaceAll(source, " ", "/") + "\x1b\\click here\x1b]8;;\x1b\\"
			if _, err := ResolveWithTranscript(home, "", screen, TranscriptRef{Provider: provider, Path: path}); !errors.Is(err, ErrNoMatch) {
				t.Fatalf("invisible hyperlink metadata must not count as visible evidence: %v", err)
			}
		})
	}
}

func TestCodexTaskStartedIsAnEmptyTurnBarrier(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, "transcript.jsonl")
	previous := "The previous answer remains visible but a new task has started without any authored response yet."
	writeLines(t, path,
		map[string]any{"type": "response_item", "payload": map[string]any{"type": "message", "role": "assistant", "content": []map[string]any{{"type": "output_text", "text": previous}}}},
		map[string]any{"type": "event_msg", "payload": map[string]any{"type": "task_complete"}},
		map[string]any{"type": "event_msg", "payload": map[string]any{"type": "task_started"}},
	)
	if _, err := ResolveWithTranscript(home, "", previous, TranscriptRef{Provider: "codex", Path: path}); !errors.Is(err, ErrNoMatch) {
		t.Fatalf("task lifecycle must prevent resurrection before user/assistant records arrive: %v", err)
	}
}
