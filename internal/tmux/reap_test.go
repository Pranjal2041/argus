package tmux

import (
	"context"
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

func waitForReapableShell(t *testing.T, socket, name string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		out, err := exec.Command("tmux", tmuxArgs(socket, "display-message", "-p", "-t", name, "#{pane_current_command}")...).Output()
		if err == nil && reapableShells[strings.TrimSpace(string(out))] {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session %q never reached an idle shell", name)
}

func waitForPaneCommand(t *testing.T, socket, name, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		out, err := exec.Command("tmux", tmuxArgs(socket, "display-message", "-p", "-t", name, "#{pane_current_command}")...).Output()
		if err == nil && strings.TrimSpace(string(out)) == want {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session %q never ran %q", name, want)
}

func waitForReapedSession(t *testing.T, provider *Provider, name string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, reaped := range provider.ReapAgents() {
			if reaped == name {
				return
			}
		}
		// An interactive shell may briefly run an rc-file helper after its pane
		// first reports the shell as foreground. The production reaper correctly
		// defers cleanup during that helper; test the eventual lifecycle result.
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session %q was not reaped", name)
}

func TestFinishedSpawnHasSevenDayMaximum(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.Spawn("finished", "", "true", 0); err != nil {
		t.Fatalf("spawn finished command: %v", err)
	}
	waitForSessionOption(t, socket, "finished", optDone, "1")
	waitForReapableShell(t, socket, "finished")
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
	waitForReapedSession(t, provider, "finished")
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

func TestCreateAgentShellIsImmediatelyTagged(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.CreateAgentShell("mesh-shell", ""); err != nil {
		t.Fatalf("create agent shell: %v", err)
	}

	var got *SessionInfo
	inventory := provider.ListInventory()
	for i := range inventory {
		info := inventory[i]
		if info.Name == "mesh-shell" {
			got = &info
			break
		}
	}
	if got == nil {
		t.Fatal("agent shell missing from inventory")
	}
	if !got.Agent {
		t.Fatal("agent shell was observable before @ut_agent was installed")
	}
	waitForSessionOption(t, socket, "mesh-shell", optAgentShell, "1")
	waitForSessionOption(t, socket, "mesh-shell", optOrigin, "cli-sh")
	lastUsedText := waitForSessionOption(t, socket, "mesh-shell", optLastUsed, "")
	lastUsed, err := strconv.ParseInt(lastUsedText, 10, 64)
	if err != nil || lastUsed <= 0 {
		t.Fatalf("invalid last-used marker %q", lastUsedText)
	}

	if reaped := provider.ReapAgents(); len(reaped) != 0 {
		t.Fatalf("fresh persistent shell was reaped: %v", reaped)
	}
}

func TestAgentShellDoesNotReclassifyExistingVisibleSession(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Create("human-shell", ""); err != nil {
		t.Fatalf("create visible session: %v", err)
	}
	if err := provider.CreateAgentShell("human-shell", ""); err != nil {
		t.Fatalf("attach to existing session: %v", err)
	}
	found := false
	for _, info := range provider.ListInventory() {
		if info.Name != "human-shell" {
			continue
		}
		found = true
		if info.Name == "human-shell" && info.Agent {
			t.Fatal("ut sh reclassified an existing visible session as agent-owned")
		}
	}
	if !found {
		t.Fatal("existing visible session disappeared")
	}
}

func TestAgentShellSevenDayInactivityCleanup(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.CreateAgentShell("stale-shell", ""); err != nil {
		t.Fatalf("create agent shell: %v", err)
	}
	waitForReapableShell(t, socket, "stale-shell")
	old := time.Now().Unix() - int64(session.MaxAgentRetentionSec) - 1
	if out, err := exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", "stale-shell", optLastUsed, strconv.FormatInt(old, 10))...).CombinedOutput(); err != nil {
		t.Fatalf("age last-used marker: %v: %s", err, out)
	}
	if got := provider.ReapAgents(); len(got) != 1 || got[0] != "stale-shell" {
		t.Fatalf("seven-day shell cleanup reaped %v, want [stale-shell]", got)
	}
	if provider.Has("stale-shell") {
		t.Fatal("expired agent shell still exists")
	}
}

func TestAgentShellCleanupNeverKillsForegroundJob(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.CreateAgentShell("busy-shell", ""); err != nil {
		t.Fatalf("create agent shell: %v", err)
	}
	if err := provider.SendText("busy-shell", "sleep 30", true); err != nil {
		t.Fatalf("start foreground job: %v", err)
	}
	waitForPaneCommand(t, socket, "busy-shell", "sleep")
	old := time.Now().Unix() - int64(session.MaxAgentRetentionSec) - 1
	if out, err := exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", "busy-shell", optLastUsed, strconv.FormatInt(old, 10))...).CombinedOutput(); err != nil {
		t.Fatalf("age last-used marker: %v: %s", err, out)
	}
	if got := provider.ReapAgents(); len(got) != 0 {
		t.Fatalf("busy agent shell was reaped: %v", got)
	}
	if !provider.Has("busy-shell") {
		t.Fatal("busy agent shell disappeared")
	}
}

func TestAgentShellRunRefreshesLastUse(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.CreateAgentShell("used-shell", ""); err != nil {
		t.Fatalf("create agent shell: %v", err)
	}
	old := time.Now().Unix() - int64(session.MaxAgentRetentionSec) - 1
	if out, err := exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", "used-shell", optLastUsed, strconv.FormatInt(old, 10))...).CombinedOutput(); err != nil {
		t.Fatalf("age last-used marker: %v: %s", err, out)
	}
	res := provider.Exec(session.ExecRequest{Session: "used-shell", Cmd: "true", TimeoutSec: 5})
	if res.Error != "" || res.Exit != 0 {
		t.Fatalf("run in agent shell: %+v", res)
	}
	lastUsedText := waitForSessionOption(t, socket, "used-shell", optLastUsed, "")
	lastUsed, err := strconv.ParseInt(lastUsedText, 10, 64)
	if err != nil || lastUsed <= old {
		t.Fatalf("ut run did not refresh last use: old=%d new=%q", old, lastUsedText)
	}
	if got := provider.ReapAgents(); len(got) != 0 {
		t.Fatalf("recently used shell was reaped: %v", got)
	}
}

func TestAgentShellInteractiveInputRefreshesLastUse(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.CreateAgentShell("typed-shell", ""); err != nil {
		t.Fatalf("create agent shell: %v", err)
	}
	client, err := provider.Dial(context.Background(), "typed-shell")
	if err != nil {
		t.Fatalf("dial agent shell: %v", err)
	}
	defer client.Close()

	old := time.Now().Unix() - int64(session.MaxAgentRetentionSec) - 1
	if out, err := exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", "typed-shell", optLastUsed, strconv.FormatInt(old, 10))...).CombinedOutput(); err != nil {
		t.Fatalf("age last-used marker: %v: %s", err, out)
	}
	if err := client.SendKeys(client.Pane(), []byte(" ")); err != nil {
		t.Fatalf("type in agent shell: %v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		lastUsedText := waitForSessionOption(t, socket, "typed-shell", optLastUsed, "")
		lastUsed, parseErr := strconv.ParseInt(lastUsedText, 10, 64)
		if parseErr == nil && lastUsed > old {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("interactive input did not refresh last use")
}
