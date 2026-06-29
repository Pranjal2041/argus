package conpty

import (
	"strings"
	"testing"
)

// TestRenderRing feeds a realistic raw ConPTY stream (OSC title spinner, SGR color,
// a CSI erase + carriage-return overwrite, a cursor-move, a faint autosuggestion,
// trailing blanks) and checks renderRing produces the clean plain text the
// command-center status updater expects.
func TestRenderRing(t *testing.T) {
	raw := "\x1b]0;⡀ working\x07" + // OSC title (must drop)
		"\x1b[32mUser:\x1b[0m fix the JSON preview\n" + // colored line
		"\x1b[1mClaude:\x1b[0m switching LazyVStack to VStack.\n" +
		"Building\x1b[K\rBuild complete!\n" + // CSI erase + CR overwrite -> "Build complete!"
		"\x1b[2A\x1b[2K" + // cursor up + erase line (drop)
		"⠸ Running tests (3s)\r⠼ Running tests (4s)\n" + // CR spinner -> last write
		"\x1b[2mPress enter to send a follow-up\x1b[22m\n" + // FAINT autosuggestion (drop)
		"> \n\n\n" // input box + trailing blanks (trim)

	got := renderRing([]byte(raw), 300)

	mustContain := []string{
		"User: fix the JSON preview",
		"Claude: switching LazyVStack to VStack.",
		"Build complete!",
		"Running tests (4s)",
	}
	for _, s := range mustContain {
		if !strings.Contains(got, s) {
			t.Errorf("expected output to contain %q\n--- got ---\n%s", s, got)
		}
	}
	mustNotContain := []string{
		"Building",     // overwritten via CR
		"(3s)",         // earlier spinner frame
		"follow-up",    // faint autosuggestion
		"working",      // OSC title text
		"\x1b",         // any leftover escape byte
	}
	for _, s := range mustNotContain {
		if strings.Contains(got, s) {
			t.Errorf("expected output NOT to contain %q\n--- got ---\n%s", s, got)
		}
	}
	if strings.HasSuffix(got, "\n\n") {
		t.Errorf("trailing blank lines were not trimmed\n--- got ---\n%q", got)
	}
}

// TestRenderRingTail checks the line cap returns the LAST n lines.
func TestRenderRingTail(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 50; i++ {
		b.WriteString("line\n")
	}
	got := renderRing([]byte(b.String()), 10)
	if n := strings.Count(got, "line"); n != 10 {
		t.Errorf("expected 10 tailed lines, got %d", n)
	}
}

// TestRenderRingEmpty: empty ring -> empty string, no panic.
func TestRenderRingEmpty(t *testing.T) {
	if got := renderRing(nil, 100); got != "" {
		t.Errorf("expected empty string for nil ring, got %q", got)
	}
}
