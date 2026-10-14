// Package agentstate defines activity semantics shared by terminal backends.
// Adapters supply the current visible screen, never a raw output suffix or history.
package agentstate

import (
	"regexp"
	"strings"
)

// Interrupt controls can require one or repeated key presses. Their meaning is
// independent of the agent name, model, elapsed timer, or spinner glyph.
var interruptHintRe = regexp.MustCompile(`(?i)(?:\besc(?:ape)?(?:[ \t]+(?:twice|again|[0-9]+[ \t]+times))?|/stop)[ \t]+to[ \t]+interrupt\b`)

const interruptScanLines = 8

// Detect classifies a successfully captured visible screen. Capture failures are
// unavailable evidence, not idle; callers retain the last successful state.
func Detect(screen []byte) string {
	if HasInterrupt(screen) {
		return "working"
	}
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	if len(lines) > waitingScanLines {
		lines = lines[len(lines)-waitingScanLines:]
	}
	if bgAgentsWaitingRe.MatchString(strings.Join(lines, "\n")) {
		return "working"
	}
	if HasWaitingPrompt(screen) {
		return "waiting"
	}
	return "idle"
}

// bgAgentsWaitingRe matches the footer an agent shows while blocked on its own
// spawned sub-agents — "Waiting for N background agents to finish". This is
// delegated WORK in progress, never a prompt for the user.
var bgAgentsWaitingRe = regexp.MustCompile(`(?i)waiting for \d+ background agents?`)

// agentsManagerRe matches the background-agents MANAGER list chrome — "↑/↓ to
// select · Enter to view", "← for agents · ↓ to manage". It reuses the same
// up/down navigation cue as a real option dialog but is NOT a user choice, so it
// must NOT count as "waiting".
var agentsManagerRe = regexp.MustCompile(`(?i)(enter to view|← for agents|↓ to manage|to manage tasks)`)

// waitingScanLines bounds the dialog scan: a selection menu renders near the
// bottom — but some agent TUIs draw a status block BELOW it, so the window is
// generous enough to still reach the menu's footer.
const waitingScanLines = 22

var (
	// The SELECTED row of a numbered option dialog: "❯ 1. Yes". The bare "❯" is
	// just the composer prompt (always on screen), so the digit is required.
	waitingSelectorRe = regexp.MustCompile(`^\s*│?\s*❯\s*\d+\.\s`)
	// Any other (unselected) option row: "  2. No, and tell Claude…".
	waitingOptionRe = regexp.MustCompile(`^\s*│?\s*\d+\.\s`)
	// The footer an interactive selection menu prints WHILE blocked on a choice
	// — e.g. "Enter to select · ↑/↓ to navigate · Esc to cancel". The most
	// robust "waiting for you to pick" signal: an explicit string the TUI emits,
	// independent of any selector GLYPH (custom agents mark the selected row with
	// COLOR, not a "❯", so the glyph heuristic alone misses them). Anchored on
	// the up/down navigation cue so ordinary prose can't trip it.
	waitingFooterRe = regexp.MustCompile(`(?i)(↑/↓|↑ ↓|↑↓|up/?down|arrow keys|use arrows).{0,40}(navigate|select|choose|move)`)
)

// HasWaitingPrompt reports whether the screen tail shows an interactive
// selection menu blocked on the user. True if EITHER:
//   - a menu footer hint is present ("↑/↓ to navigate" etc.) — robust across
//     custom TUIs that don't draw a "❯" selector; or
//   - a "❯ N." selected row PLUS another numbered option row (Claude-style
//     permission dialogs) — a single typed draft like "❯ 1. fix it" can't
//     satisfy both.
func HasWaitingPrompt(screen []byte) bool {
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	start := len(lines) - waitingScanLines
	if start < 0 {
		start = 0
	}
	tail := lines[start:]
	for _, l := range tail {
		// Skip the background-agents manager list: it shows "↑/↓ to select · Enter
		// to view", which matches the dialog-footer cue but is the agent browsing its
		// own sub-agents, not a choice put to the user.
		if waitingFooterRe.MatchString(l) && !agentsManagerRe.MatchString(l) {
			return true
		}
	}
	selector, options := false, 0
	for _, l := range tail {
		if waitingSelectorRe.MatchString(l) {
			selector = true
			options++
		} else if waitingOptionRe.MatchString(l) {
			options++
		}
	}
	return selector && options >= 2
}

// HasInterrupt reports whether any interrupt hint appears in the last few
// non-blank lines of a captured screen.
//
// ADJACENT lines are checked JOINED (no separator): the footer grows suffixes
// and wraps at the pane width, and the wrap point — which shifts as the
// elapsed-time text ticks ("8s" → "1m 42s") — can land INSIDE the phrase
// ("…esc to inte" / "rrupt) · 1 background…"), so no single captured line
// contains it. A wrapped line is always immediately followed by its
// continuation, so joining adjacent lines reconstructs the phrase; a blank
// line is never a wrap and breaks the join.
func HasInterrupt(screen []byte) bool {
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	checked := 0
	var run []string // current run of ADJACENT non-blank lines, gathered bottom-up
	runHasHint := func() bool {
		if len(run) == 0 {
			return false
		}
		var joined, spaced strings.Builder
		for i := len(run) - 1; i >= 0; i-- {
			joined.WriteString(run[i])
			spaced.WriteString(run[i])
			spaced.WriteByte(' ')
		}
		// A word-boundary wrap can lose its trailing space in capture-pane.
		return interruptHintRe.MatchString(joined.String()) || interruptHintRe.MatchString(spaced.String())
	}
	for i := len(lines) - 1; i >= 0 && checked < interruptScanLines; i-- {
		l := strings.TrimRight(lines[i], " \t")
		if strings.TrimSpace(l) == "" {
			if runHasHint() {
				return true
			}
			run = run[:0]
			continue
		}
		checked++
		run = append(run, l)
	}
	return runHasHint()
}
