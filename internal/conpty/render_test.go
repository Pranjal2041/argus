package conpty

import (
	"fmt"
	"strings"
	"testing"
)

// TestRenderRingFlowing: plain flowing lines must all appear (the case strip-and-tail
// dropped). 25 lines fit in a 30-row screen.
func TestRenderRingFlowing(t *testing.T) {
	var b strings.Builder
	for i := 1; i <= 25; i++ {
		fmt.Fprintf(&b, "ROW_%d\r\n", i)
	}
	got := renderRing([]byte(b.String()), 120, 30)
	for i := 1; i <= 25; i++ {
		if !strings.Contains(got, fmt.Sprintf("ROW_%d", i)) {
			t.Errorf("missing ROW_%d\n--- got ---\n%s", i, got)
		}
	}
}

// TestRenderRingRepaint: a clear-screen + reposition must reflect the FINAL screen,
// not the overwritten content — proving real emulation (not escape-stripping).
func TestRenderRingRepaint(t *testing.T) {
	in := "OLD CONTENT HERE\r\n" + // drawn first
		"\x1b[2J\x1b[H" + // clear screen + home
		"NEW CONTENT ONLY\r\n" // repainted
	got := renderRing([]byte(in), 120, 30)
	if !strings.Contains(got, "NEW CONTENT ONLY") {
		t.Errorf("expected repainted text\n--- got ---\n%s", got)
	}
	if strings.Contains(got, "OLD CONTENT HERE") {
		t.Errorf("cleared text should be gone\n--- got ---\n%s", got)
	}
}

// TestRenderRingCursorOverwrite: writing over a cell via cursor positioning must
// show the latest character, like a real terminal.
func TestRenderRingCursorOverwrite(t *testing.T) {
	in := "STATUS: starting\r" + // carriage return to column 0
		"STATUS: done    \r\n" // overwrite the line
	got := renderRing([]byte(in), 120, 30)
	if !strings.Contains(got, "STATUS: done") {
		t.Errorf("expected overwritten line\n--- got ---\n%s", got)
	}
	if strings.Contains(got, "starting") {
		t.Errorf("overwritten text should be gone\n--- got ---\n%s", got)
	}
}

// TestRenderRingFaint: faint (SGR 2) text — the dim autosuggestion — must be blanked,
// while normal text on the same line survives.
func TestRenderRingFaint(t *testing.T) {
	in := "REAL_INPUT \x1b[2mSUGGESTION_PLACEHOLDER\x1b[22m more\r\n"
	got := renderRing([]byte(in), 120, 30)
	if !strings.Contains(got, "REAL_INPUT") {
		t.Errorf("normal text should survive\n--- got ---\n%s", got)
	}
	if strings.Contains(got, "SUGGESTION_PLACEHOLDER") {
		t.Errorf("faint autosuggestion should be blanked\n--- got ---\n%s", got)
	}
}

// TestRenderRingTrims: leading/trailing blank rows are trimmed.
func TestRenderRingTrims(t *testing.T) {
	in := "\r\n\r\n\r\nactual content\r\n\r\n"
	got := renderRing([]byte(in), 120, 30)
	if got != "actual content" {
		t.Errorf("expected trimmed to %q, got %q", "actual content", got)
	}
}

// TestRenderRingEmpty: empty ring -> empty string, no panic.
func TestRenderRingEmpty(t *testing.T) {
	if got := renderRing(nil, 120, 30); got != "" {
		t.Errorf("expected empty string for nil ring, got %q", got)
	}
}

// TestRenderRingDefaultsSize: a zero size must fall back to defaults, not panic.
func TestRenderRingDefaultsSize(t *testing.T) {
	got := renderRing([]byte("hello\r\n"), 0, 0)
	if !strings.Contains(got, "hello") {
		t.Errorf("expected 'hello' with default size, got %q", got)
	}
}
