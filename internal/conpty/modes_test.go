package conpty

import (
	"strings"
	"testing"
)

func TestModeTrackerBracketedPaste(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?2004h")) // agent enables bracketed paste at startup
	if r := string(m.restore()); r != "\x1b[?2004h" {
		t.Fatalf("want bracketed paste restored, got %q", r)
	}
}

func TestModeTrackerSetThenReset(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?2004h"))
	m.feed([]byte("\x1b[?2004l")) // turned off later → must NOT be restored
	if r := m.restore(); r != nil {
		t.Fatalf("want nothing restored after reset, got %q", string(r))
	}
}

func TestModeTrackerMultipleParams(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?1000;1006h")) // mouse SGR
	m.feed([]byte("\x1b[?25l"))        // hide cursor (off → not restored)
	r := string(m.restore())
	if !strings.Contains(r, "\x1b[?1000h") || !strings.Contains(r, "\x1b[?1006h") {
		t.Fatalf("want 1000h+1006h, got %q", r)
	}
	if strings.Contains(r, "?25") {
		t.Fatalf("cursor was hidden (l), must not restore: %q", r)
	}
}

// The bug's exact scenario: the mode is set, then MORE than a ring's worth of
// output flows (evicting the original ?2004h), yet restore() still reports it.
func TestModeSurvivesRingEviction(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?2004h"))
	big := make([]byte, 200*1024)
	for i := range big {
		big[i] = 'A'
	}
	m.feed(big) // simulate 200KB of later output (ring is 128KB)
	if r := string(m.restore()); r != "\x1b[?2004h" {
		t.Fatalf("mode must survive eviction, got %q", r)
	}
}

// A sequence split across two feed() calls (two ConPTY reads) must still track.
func TestModeSplitAcrossReads(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?20")) // first read ends mid-sequence
	m.feed([]byte("04h"))      // second read completes it
	if r := string(m.restore()); r != "\x1b[?2004h" {
		t.Fatalf("split sequence must track, got %q", r)
	}
}

// A query (CSI ? Pm $ p) or other non-h/l must not be mistaken for a set.
func TestModeIgnoresQuery(t *testing.T) {
	var m modeTracker
	m.feed([]byte("\x1b[?2004$p")) // DECRQM query, not a set
	if r := m.restore(); r != nil {
		t.Fatalf("query must not set a mode, got %q", string(r))
	}
}
