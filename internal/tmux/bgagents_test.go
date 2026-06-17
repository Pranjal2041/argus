package tmux

import (
	"strings"
	"testing"
)

// The background-sub-agents view from a real session (paste-E0722445): the agent
// delegated to Explore sub-agents and is waiting on THEM, not the user. It must NOT
// be classified as "waiting" (which would falsely flag it for attention).
const bgAgentsScreen = `● Agent "Map tasks subsystem" came to rest   3m 14s
● Two more in. Environments and scripts/datasets agents are still finishing — I'll wait for them before the full synthesis.
● Waiting for 2 background agents to finish
› Yes, set up the environment
  bypass permissions on (shift+tab to cycle) · ← for agents · ↓ to manage
● main                                    ↑/↓ to select · Enter to view
○ Explore  Locating robosuite editable install path        3m 50s · ↓ 112.2k tokens
○ Explore  Counting composite activity categories          3m 18s · ↓ 133.6k tokens
○ Explore  Reading dataset_registry.py task sets           3m 29s · ↓ 152.9k tokens`

// A genuine permission dialog must STILL be detected as waiting (no regression).
const realDialogScreen = `Do you want to proceed?
❯ 1. Yes
  2. No, and tell Claude what to do differently
  ↑/↓ to navigate · Enter to select · Esc to cancel`

func TestBackgroundAgentsNotWaiting(t *testing.T) {
	if !bgAgentsWaitingRe.Match([]byte(bgAgentsScreen)) {
		t.Fatal("bgAgentsWaitingRe should match 'Waiting for 2 background agents'")
	}
	if screenHasWaitingPrompt([]byte(bgAgentsScreen)) {
		t.Fatal("background-agents manager must NOT count as waiting (it's delegated work, not a user choice)")
	}
}

func TestRealDialogStillWaiting(t *testing.T) {
	if !screenHasWaitingPrompt([]byte(realDialogScreen)) {
		t.Fatal("a real permission dialog must still be detected as waiting")
	}
}

// Claude Code draws its empty-prompt autosuggestion FAINT (SGR 2). dropDimAndAnsi must
// remove it (so the summarizer can't mistake it for the user's intent) while keeping the
// real content and stripping all other escapes.
func TestDropFaintAutosuggestion(t *testing.T) {
	raw := "● healthy at step 434.\n\x1b[39m❯ \x1b[2mbenchmark the step_400 checkpoint on gym add_border\x1b[0m\x1b[39m\n\x1b[38;5;211m bypass permissions on\x1b[39m"
	got := dropDimAndAnsi([]byte(raw))
	if strings.Contains(got, "benchmark the step_400") {
		t.Fatalf("faint suggestion not stripped: %q", got)
	}
	if !strings.Contains(got, "healthy at step 434") {
		t.Fatalf("real content lost: %q", got)
	}
	if strings.Contains(got, "bypass permissions") == false {
		t.Fatalf("non-faint chrome should remain: %q", got)
	}
	if strings.Contains(got, "\x1b[") {
		t.Fatalf("ANSI escapes not stripped: %q", got)
	}
}
