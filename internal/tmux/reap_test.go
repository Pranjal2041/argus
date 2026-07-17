package tmux

import (
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"universal-tmux/internal/session"
)

func waitForSessionOption(t *testing.T, socket, name, option, want string) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		out, err := exec.Command("tmux", tmuxArgs(socket, "show-options", "-v", "-t", name, option)...).Output()
		if err == nil {
			got := strings.TrimSpace(string(out))
			if want == "" || got == want {
				return got
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session %q option %s never became %q", name, option, want)
	return ""
}

func TestFinishedSpawnHasSevenDayMaximum(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.Spawn("finished", "", "true", 0); err != nil {
		t.Fatalf("spawn finished command: %v", err)
	}
	waitForSessionOption(t, socket, "finished", optDone, "1")
	doneAtText := waitForSessionOption(t, socket, "finished", optDoneAt, "")
	doneAt, err := strconv.ParseInt(doneAtText, 10, 64)
	if err != nil || doneAt <= 0 {
		t.Fatalf("invalid completion time %q", doneAtText)
	}

	// `--idle 0` skips the ordinary idle cleanup, so a recently finished
	// session remains available for its output.
	if got := provider.ReapAgents(); len(got) != 0 {
		t.Fatalf("recent --idle 0 session was reaped: %v", got)
	}

	old := time.Now().Unix() - int64(session.MaxAgentRetentionSec) - 1
	if out, err := exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", "finished", optDoneAt, strconv.FormatInt(old, 10))...).CombinedOutput(); err != nil {
		t.Fatalf("age completion marker: %v: %s", err, out)
	}
	got := provider.ReapAgents()
	if len(got) != 1 || got[0] != "finished" {
		t.Fatalf("seven-day cleanup reaped %v, want [finished]", got)
	}
	if provider.Has("finished") {
		t.Fatal("expired finished session still exists")
	}
}

func TestSevenDayMaximumNeverKillsLiveSpawn(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Spawn("live", "", "sleep 30", 0); err != nil {
		t.Fatalf("spawn live command: %v", err)
	}
	if got := provider.ReapAgents(); len(got) != 0 {
		t.Fatalf("live command was reaped: %v", got)
	}
	if !provider.Has("live") {
		t.Fatal("live command's session disappeared")
	}
}
