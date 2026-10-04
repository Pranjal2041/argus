package rendersource

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestHistoryUsesChronologicalPublicMessagesAcrossAdapters(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		t.Run(provider, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "exact.jsonl")
			entry := func(role, text string) any {
				if provider == "codex" {
					kind := "output_text"
					if role == "user" {
						kind = "input_text"
					}
					return map[string]any{"type": "response_item", "payload": map[string]any{
						"type": "message", "role": role, "content": []any{map[string]any{"type": kind, "text": text}},
					}}
				}
				return map[string]any{"type": role, "message": map[string]any{
					"role": role, "content": []any{map[string]any{"type": "text", "text": text}},
				}}
			}
			writeLines(t, path, entry("user", "First question"), entry("assistant", "Progress"),
				entry("assistant", "First answer"), entry("user", "Second question"), entry("assistant", "Second answer"))
			got, err := History(TranscriptRef{Provider: provider, Path: path})
			want := []HistoryEntry{{"user", "First question"}, {"assistant", "Progress"},
				{"assistant", "First answer"}, {"user", "Second question"}, {"assistant", "Second answer"}}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("history=%#v, err=%v; want %#v", got, err, want)
			}
		})
	}
}

func TestHistoryNeverExportsPrivateReasoningOrToolPayloads(t *testing.T) {
	for _, tc := range []struct{ provider, record string }{
		{"codex", `{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"private"}]}}`},
		{"codex", `{"type":"response_item","payload":{"type":"message","role":"system","content":[{"type":"output_text","text":"private"}]}}`},
		{"codex", `{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"private"}]}}`},
		{"codex", `{"type":"event_msg","payload":{"type":"agent_message","message":"duplicate of response_item"}}`},
		{"claude", `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"tool_use","input":{"secret":"private"}}]}}`},
		{"claude", `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"private"}]}}`},
		{"claude", `{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":"another agent"}}`},
	} {
		t.Run(tc.provider+tc.record[:20], func(t *testing.T) {
			var record any
			if err := json.Unmarshal([]byte(tc.record), &record); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "exact.jsonl")
			writeLines(t, path, record)
			if entries, err := History(TranscriptRef{Provider: tc.provider, Path: path}); err == nil || len(entries) != 0 {
				t.Fatalf("non-public payload leaked: %#v, %v", entries, err)
			}
		})
	}
}

func TestHistoryRequiresSupportedExactOwnership(t *testing.T) {
	for _, ref := range []TranscriptRef{{}, {Provider: "codex"}, {Provider: "unknown", Path: "/anywhere"}} {
		if _, err := History(ref); err == nil {
			t.Fatalf("unproven source accepted: %#v", ref)
		}
	}
}

func TestHistoryScreenCorroborationIsSharedAcrossAdapters(t *testing.T) {
	message := "This response belongs to the currently visible conversation about terminal scrolling"
	for _, provider := range []string{"codex", "claude"} {
		t.Run(provider, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "exact.jsonl")
			var record any
			if provider == "codex" {
				record = map[string]any{"type": "response_item", "payload": map[string]any{
					"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": message}},
				}}
			} else {
				record = map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": message}}
			}
			writeLines(t, path, record)
			ref := TranscriptRef{Provider: provider, Path: path, RequireScreenMatch: true}
			for _, screen := range []string{"", "Unrelated text from another conversation must not select the old launch transcript"} {
				if _, err := HistoryWithScreen(ref, screen); err == nil {
					t.Fatal("uncorroborated launch identity accepted")
				}
			}
			if entries, err := HistoryWithScreen(ref, message+"\nPrompt ready"); err != nil || len(entries) != 1 {
				t.Fatalf("current screen was not matched: %#v, %v", entries, err)
			}
		})
	}
}

func TestHistoryReachesAcrossOversizedToolRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "large.jsonl")
	older := `{"type":"assistant","message":{"role":"assistant","content":"Earlier public answer"}}`
	newer := `{"type":"user","message":{"role":"user","content":"Newest public question"}}`
	tool := `{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"` + strings.Repeat("x", 10<<20) + `"}]}}`
	if err := os.WriteFile(path, []byte(older+"\n"+tool+"\n"+newer+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	entries, err := History(TranscriptRef{Provider: "claude", Path: path})
	want := []HistoryEntry{{"assistant", "Earlier public answer"}, {"user", "Newest public question"}}
	if err != nil || !reflect.DeepEqual(entries, want) {
		t.Fatalf("history=%#v, err=%v", entries, err)
	}
}

func TestHistoryTailReassemblesPublicRecordsAcrossReadBoundaries(t *testing.T) {
	path := filepath.Join(t.TempDir(), "boundary.jsonl")
	want := strings.Repeat("A public message with Unicode λ\n", 40000)
	writeLines(t, path, map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": want}})
	entries, err := History(TranscriptRef{Provider: "claude", Path: path})
	if err != nil || len(entries) != 1 || entries[0].Text != want {
		t.Fatal("record spanning chunks was not preserved", err)
	}
}
