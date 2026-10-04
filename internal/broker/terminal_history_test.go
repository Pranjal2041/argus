package broker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"universal-tmux/internal/rendersource"
)

func TestTerminalHistoryIsExactReadOnlyAndNotNewestAnswerOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	data := `{"type":"user","message":{"role":"user","content":"older question"}}
{"type":"assistant","message":{"role":"assistant","content":"older answer"}}
{"type":"user","message":{"role":"user","content":"newer question"}}
{"type":"assistant","message":{"role":"assistant","content":"newer answer"}}
`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	provider := &exactTranscriptRenderProvider{
		warmProvider: warmProvider{exists: true},
		ref:          rendersource.TranscriptRef{Provider: "claude", Path: path},
		screen:       "only the last screen is visible",
	}
	m := &Manager{prov: provider}
	history, err := m.TerminalHistory("panel")
	if err != nil || history.Origin != "conversation" || !strings.Contains(history.Text, "older answer") || !strings.Contains(history.Text, "newer answer") {
		t.Fatalf("wrong history: %#v, %v", history, err)
	}
	if provider.createCalls != 0 || provider.dialCalls != 0 {
		t.Fatal("reading history created or attached an interactive session")
	}
}

func TestTerminalHistoryFallsBackWithoutGuessingAnotherTranscript(t *testing.T) {
	provider := &exactTranscriptRenderProvider{
		warmProvider: warmProvider{exists: true},
		ref:          rendersource.TranscriptRef{Provider: "future-adapter", Path: "not-supported"},
		screen:       "captured output, unchanged",
	}
	m := &Manager{prov: provider}
	history, err := m.TerminalHistory("panel")
	if err != nil || history.Origin != "terminal" || history.Text != provider.screen {
		t.Fatalf("wrong fallback: %#v, %v", history, err)
	}
	provider.exists = false
	if _, err := m.TerminalHistory("gone"); err == nil {
		t.Fatal("history was returned for a nonexistent session")
	}
}

type renamedHistoryProvider struct {
	exactTranscriptRenderProvider
	captured string
}

func (p *renamedHistoryProvider) SessionForID(id string) (string, bool) {
	return "renamed-panel", id == "$7"
}

func (p *renamedHistoryProvider) Capture(name string, lines int) (string, error) {
	p.captured = name
	return "saved output", nil
}

func TestTerminalHistoryResolvesStableHandleBeforeSelectingItsSource(t *testing.T) {
	p := &renamedHistoryProvider{exactTranscriptRenderProvider: exactTranscriptRenderProvider{
		warmProvider: warmProvider{exists: true},
	}}
	m := &Manager{prov: p}
	if _, err := m.TerminalHistory("$7"); err != nil || p.captured != "renamed-panel" {
		t.Fatalf("history did not follow session identity: %q, %v", p.captured, err)
	}
	if _, err := m.TerminalHistory("$8"); err == nil {
		t.Fatal("dead stable handle was treated as a session name")
	}
}

func TestTerminalHistoryCorroboratesLaunchReferenceBeforeExposingIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	message := "The latest response in this session describes smooth terminal scrolling and immutable input"
	if err := os.WriteFile(path, []byte(`{"type":"assistant","message":{"role":"assistant","content":"`+message+`"}}`+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	p := &exactTranscriptRenderProvider{
		warmProvider: warmProvider{exists: true},
		ref:          rendersource.TranscriptRef{Provider: "claude", Path: path, RequireScreenMatch: true},
		screen:       "A different active conversation cannot inherit the stale launch transcript",
	}
	m := &Manager{prov: p}
	if history, err := m.TerminalHistory("panel"); err != nil || history.Origin != "terminal" || history.Text != p.screen {
		t.Fatalf("stale reference accepted: %#v, %v", history, err)
	}
	p.screen = message
	if history, err := m.TerminalHistory("panel"); err != nil || history.Origin != "conversation" {
		t.Fatalf("live reference rejected: %#v, %v", history, err)
	}
}
