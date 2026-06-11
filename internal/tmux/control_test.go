package tmux

import (
	"strings"
	"testing"
)

// The "working" signal is any known agent footer hint in the last few
// non-blank screen lines — "esc to interrupt" (Claude/Codex) OR
// "/stop to interrupt" (some agent modes).
func TestScreenHasInterrupt(t *testing.T) {
	cases := []struct {
		name   string
		screen string
		want   bool
	}{
		{"esc hint", "output\n\n✶ Cogitating… (12s · esc to interrupt)\n", true},
		{"stop hint", "output\n\nRunning task… (/stop to interrupt)\n", true},
		{"case-insensitive", "…(ESC TO INTERRUPT)\n", true},
		{"idle prompt", "$ ls\nfoo bar\n$ \n", false},
		{"hint scrolled out of footer", "esc to interrupt\n1\n2\n3\n4\n5\n6\n7\n8\n9\n", false},
		// the footer grew suffixes and the pane width wrapped it MID-PHRASE —
		// adjacent lines must be checked joined
		{"wrapped mid-phrase", "out\n\n• Working (1m 42s • esc to inte\nrrupt) · 1 background terminal running\n\n› \n  model · ~/dir\n", true},
		// a blank line is never a wrap: fragments across it must NOT join
		{"blank breaks join", "esc to inte\n\nrrupt\n", false},
	}
	for _, c := range cases {
		if got := screenHasInterrupt([]byte(c.screen)); got != c.want {
			t.Errorf("%s: screenHasInterrupt = %v, want %v", c.name, got, c.want)
		}
	}
}

// "waiting" = a numbered option dialog at the bottom of the screen: the
// selected row ("❯ 1. Yes") PLUS at least one more numbered option. The bare
// "❯" composer prompt and a typed numbered draft must NOT count.
func TestScreenHasWaitingPrompt(t *testing.T) {
	dialog := `tool call output

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again this session
   3. No, and tell Claude what to do differently

`
	boxed := "│ Do you want to make this edit?\n│ ❯ 1. Yes\n│   2. No\n"
	cases := []struct {
		name   string
		screen string
		want   bool
	}{
		{"claude permission dialog", dialog, true},
		{"boxed dialog", boxed, true},
		{"idle composer prompt", "some output\n\n❯ \n", false},
		{"typed numbered draft", "output\n\n❯ 1. fix the bug first\n", false},
		{"numbered list in chat", " 1. step one\n 2. step two\n\n❯ \n", false},
		{"dialog scrolled away", dialog + strings.Repeat("filler line\n", 16), false},
	}
	for _, c := range cases {
		if got := screenHasWaitingPrompt([]byte(c.screen)); got != c.want {
			t.Errorf("%s: screenHasWaitingPrompt = %v, want %v", c.name, got, c.want)
		}
	}
}

// layoutSize parses the WxH out of tmux layout strings as emitted by
// %layout-change — the authoritative pane size all viewers must render at.
func TestLayoutSize(t *testing.T) {
	cases := []struct {
		layout string
		w, h   int
		ok     bool
	}{
		{"ac1d,97x31,0,0,0", 97, 31, true},
		{"bdbd,139x53,0,0,0", 139, 53, true},
		// split layout: the leading size is still the whole window's
		{"fa1c,208x62,0,0{104x62,0,0,1,103x62,105,0,2}", 208, 62, true},
		{"garbage", 0, 0, false},
		{"ac1d,notasize,0", 0, 0, false},
		{"ac1d,0x0,0", 0, 0, false},
		{"", 0, 0, false},
	}
	for _, c := range cases {
		w, h, ok := layoutSize(c.layout)
		if w != c.w || h != c.h || ok != c.ok {
			t.Errorf("layoutSize(%q) = (%d,%d,%v), want (%d,%d,%v)", c.layout, w, h, ok, c.w, c.h, c.ok)
		}
	}
}
