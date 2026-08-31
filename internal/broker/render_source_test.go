package broker

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"universal-tmux/internal/rendersource"
	"universal-tmux/internal/session"
)

type staleRenderDirectoryProvider struct{ warmProvider }

func (*staleRenderDirectoryProvider) RenderWorkingDirectory(string) (string, bool) {
	return "", false
}

type liveRenderDirectoryProvider struct{ warmProvider }

func (*liveRenderDirectoryProvider) RenderWorkingDirectory(string) (string, bool) {
	return `C:\Users\pranjala\spatial_bench`, true
}

func TestRenderWorkingDirectoryRejectsStaleBackendPath(t *testing.T) {
	provider := &staleRenderDirectoryProvider{}
	if got := renderWorkingDirectory(provider, "spatial_ue", `C:\Users\pranjala`); got != "" {
		t.Fatalf("stale ConPTY directory remained authoritative: %q", got)
	}
}

func TestRenderWorkingDirectoryUsesLiveBackendPath(t *testing.T) {
	provider := &liveRenderDirectoryProvider{}
	want := `C:\Users\pranjala\spatial_bench`
	if got := renderWorkingDirectory(provider, "spatial_ue", `C:\Users\pranjala`); got != want {
		t.Fatalf("render cwd = %q, want %q", got, want)
	}
}

func TestRenderWorkingDirectoryKeepsCachedPathForExistingBackends(t *testing.T) {
	provider := &warmProvider{}
	want := "/Users/pranjal/Developer/universal_tmux"
	if got := renderWorkingDirectory(provider, "universal_tmux", want); got != want {
		t.Fatalf("render cwd = %q, want %q", got, want)
	}
}

type exactTranscriptRenderProvider struct {
	warmProvider
	ref    rendersource.TranscriptRef
	screen string
}

func (p *exactTranscriptRenderProvider) Capture(string, int) (string, error) {
	return p.screen, nil
}

func (p *exactTranscriptRenderProvider) AgentTranscript(string) (rendersource.TranscriptRef, error) {
	return p.ref, nil
}

func TestRenderSourceConsumesProviderNeutralExactTranscript(t *testing.T) {
	cwd := filepath.Join(t.TempDir(), "project")
	path := filepath.Join(t.TempDir(), "custom-agent-home", "session.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	source := "## Exact report\n\nThe provider-neutral broker contract returns the complete authored response for this live pane."
	lines := []any{
		map[string]any{"type": "user", "cwd": cwd, "message": map[string]any{
			"role": "user", "content": "Render this turn.",
		}},
		map[string]any{"type": "assistant", "cwd": filepath.Join(cwd, "nested"), "message": map[string]any{
			"role": "assistant", "stop_reason": "end_turn",
			"content": []map[string]any{{"type": "text", "text": source}},
		}},
	}
	var encoded []byte
	for _, line := range lines {
		body, err := json.Marshal(line)
		if err != nil {
			t.Fatal(err)
		}
		encoded = append(encoded, body...)
		encoded = append(encoded, '\n')
	}
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatal(err)
	}

	provider := &exactTranscriptRenderProvider{
		warmProvider: warmProvider{exists: true},
		ref:          rendersource.TranscriptRef{Provider: "claude", Path: path},
		screen:       "Exact report The provider-neutral broker contract returns the complete authored response for this live pane.",
	}
	manager := &Manager{prov: provider, sessCache: []session.Info{{Name: "panel", Path: cwd}}}
	got, err := manager.RenderSource("panel")
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != source || got.Origin != "claude-transcript" {
		t.Fatalf("RenderSource() = %#v, want exact provider-neutral source", got)
	}
}
