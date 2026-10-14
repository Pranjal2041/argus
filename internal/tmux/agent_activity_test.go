package tmux

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"universal-tmux/internal/rendersource"
)

func TestVisibleActivityOnRealTerminal(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	for _, tc := range []struct{ name, frame, want string }{
		{"single", "Working (esc to interrupt)", "working"},
		{"repeated", "Thinking (esc twice to interrupt)", "working"},
		{"command", "Working (/stop to interrupt)", "working"},
		{"dialog", "Choose\n❯ 1. Allow\n 2. Deny", "waiting"},
		{"completed", "Done\n❭ ", "idle"},
	} {
		// Only this test's private server receives input. Keep the paint resident
		// without any title update, matching both interactive and silent TUIs.
		cmd := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", tc.name, "-x", "80", "-y", "24",
			"printf '%s' '"+tc.frame+"'; sleep 30")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("new test pane: %v %s", err, out)
		}
		deadline := time.Now().Add(3 * time.Second)
		for {
			got := provider.DetectState(tc.name)
			if got == tc.want {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s: state = %q, want %q", tc.name, got, tc.want)
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	if got := provider.DetectState("not-a-session"); got != "" {
		t.Fatalf("failed capture invented %q", got)
	}
}

// Optional passive verification against an explicitly selected live session.
// It never sends input, attaches a client, resizes, or changes session state.
func TestLiveAgentFeatureContractWhenRequested(t *testing.T) {
	name := os.Getenv("UT_TEST_LIVE_SESSION")
	if name == "" {
		t.Skip("live session not requested")
	}
	socket := os.Getenv("UT_TEST_LIVE_SOCKET")
	if socket == "" {
		socket = "ut"
	}
	p := NewProvider(socket)
	state := p.DetectState(name)
	if want := os.Getenv("UT_TEST_LIVE_STATE"); want != "" && state != want {
		t.Fatalf("activity: got %q, want %q", state, want)
	}
	ref, err := p.AgentTranscript(name)
	if err != nil {
		t.Fatal(err)
	}
	if ref.Provider == "" || ref.SessionID == "" || ref.Path == "" {
		t.Fatal("incomplete process-owned conversation")
	}
	screen, err := p.CaptureHistory(name, 400)
	if err != nil {
		t.Fatal(err)
	}
	history, err := rendersource.HistoryWithScreen(ref, screen)
	if err != nil {
		t.Fatalf("public conversation history: %v", err)
	}
	grid, err := p.CaptureRenderScreen(name, 400)
	if err != nil {
		t.Fatal(err)
	}
	result, err := rendersource.ResolveWithTranscript("", "", rendersource.MatchingScreen(grid), ref)
	if err != nil && !errors.Is(err, rendersource.ErrNoMatch) {
		t.Fatal(err)
	}
	mode := result.Origin
	if errors.Is(err, rendersource.ErrNoMatch) {
		mode = "live terminal (no complete matching answer on screen)"
	}
	t.Logf("provider=%s state=%s publicMessages=%d rendering=%s", ref.Provider, state, len(history), mode)
}

// Opt-in submission regression probe is confined to a dedicated server, never
// user panels. It also exposes applications that ignore a correctly framed
// post-paste submit; do not hide that failure with a provider-specific delay.
func TestIsolatedLiveAgentSendWhenRequested(t *testing.T) {
	socket := os.Getenv("UT_TEST_SEND_PROBE_SOCKET")
	if socket == "" {
		t.Skip("isolated send probe not requested")
	}
	if !strings.HasPrefix(socket, "ut-agent-parity-probe") {
		t.Fatal("send probe requires its own isolated server")
	}
	p := NewProvider(socket)
	if err := p.SendText("probe", "This is an isolated Argus input test. Do not use tools or access files. Print the integers from 601 through 900, with no other text.", true); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if p.DetectState("probe") == "working" {
			t.Log("one SendText call submitted the prompt and detected a running turn")
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("prompt was not submitted as a running turn")
}
