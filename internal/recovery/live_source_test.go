//go:build !windows

package recovery

import (
	"encoding/json"
	"os"
	"testing"

	"universal-tmux/internal/rendersource"
)

// Opt-in read-only diagnostic: it neither attaches to a pane nor sends input,
// starts an agent, changes focus, or starts/replaces the user's broker.
func TestInspectLiveAgentSourceWhenRequested(t *testing.T) {
	name := os.Getenv("UT_TEST_AGENT_SESSION")
	if name == "" {
		t.Skip("no live pane requested")
	}
	socket := os.Getenv("UT_TEST_AGENT_SOCKET")
	if socket == "" {
		socket = "ut"
	}
	ref, err := InspectAgentSession(socket, name)
	if err != nil {
		t.Fatal(err)
	}
	screen, err := tmuxCommand(socket, "capture-pane", "-p", "-S", "-100", "-t", "="+name+":").CombinedOutput()
	if err != nil {
		t.Fatalf("capture: %v: %s", err, screen)
	}
	result, err := rendersource.ResolveWithTranscript("", "", string(screen), rendersource.TranscriptRef{
		Provider: ref.Agent, Path: ref.Path, SessionID: ref.ID, RequireScreenMatch: ref.RequireScreenMatch,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("provider=%s session=%s source-bytes=%d confidence=%.3f", ref.Agent, ref.ID, len(result.Source), result.Confidence)
	if path := os.Getenv("UT_TEST_AGENT_SOURCE_OUTPUT"); path != "" {
		body, err := json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, body, 0600); err != nil {
			t.Fatal(err)
		}
	}
}
