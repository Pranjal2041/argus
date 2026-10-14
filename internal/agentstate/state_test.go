package agentstate

import (
	"strings"
	"testing"
)

func TestActivityControlGrammar(t *testing.T) {
	for _, hint := range []string{"esc to interrupt", "esc twice to interrupt", "Escape 2 times to interrupt", "ESC AGAIN TO INTERRUPT", "/stop to interrupt"} {
		t.Run(hint, func(t *testing.T) {
			if got := Detect([]byte("output\n\nThinking · 1m 14s (" + hint + ") · (2957c)\n────\n❭ Guide the agent while it works\n────\nmodel · ctrl+o details\n")); got != "working" {
				t.Fatalf("state = %q", got)
			}
			for split := 1; split < len(hint); split++ {
				screen := "Thinking (" + hint[:split] + "\n" + hint[split:] + ")\n❯ \n"
				if !HasInterrupt([]byte(screen)) {
					t.Fatalf("missed wrap at %d: %q", split, screen)
				}
			}
		})
	}
}

func TestActivityUsesCurrentFooterNotHistory(t *testing.T) {
	for _, screen := range []string{
		"esc twice to interrupt\n" + strings.Repeat("new output\n", 9),
		"Waiting for 2 background agents to finish\n" + strings.Repeat("new output\n", 23),
		"esc twice to\n\ninterrupt\n",
		"description of an interruption\n$ ",
	} {
		if got := Detect([]byte(screen)); got != "idle" {
			t.Fatalf("stale/non-control evidence classified %q: %q", got, screen)
		}
	}
}

func TestActivityTransitionsWithoutAgentIdentity(t *testing.T) {
	for _, hint := range []string{"esc to interrupt", "esc twice to interrupt", "/stop to interrupt"} {
		for _, frame := range []struct{ screen, want string }{
			{"❯ ", "idle"},
			{"Working (" + hint + ")\n❯ ", "working"},
			{"Choose a permission\n❯ 1. Allow\n 2. Deny\n", "waiting"},
			{"Done\n❭ ", "idle"},
		} {
			if got := Detect([]byte(frame.screen)); got != frame.want {
				t.Fatalf("%q: got %q, want %q", frame.screen, got, frame.want)
			}
		}
	}
}
