// This file is deliberately NOT build-constrained to windows (unlike the rest of
// package conpty): it is pure, cross-platform Go (vt10x is portable), so keeping it
// here makes the rendering unit-testable on any platform (see render_test.go).
package conpty

import (
	"strings"

	"github.com/hinshun/vt10x"
)

// ConPTY default session size, shared with the windows backend (conpty.go).
const (
	defCols = 120
	defRows = 30
)

// renderRing reconstructs a ConPTY session's CURRENT SCREEN as plain text, for the
// command-center status updater (GET /recent). ConPTY is itself a terminal emulator
// that repaints its viewport with cursor addressing — it is NOT an append-only log,
// so simply stripping escapes from the raw ring loses any line that was cursor-
// overwritten or scrolled (verified: a burst of flowing output came back empty).
// The only correct way to read it back is to emulate it the way the client's
// terminal does: feed the raw ring through a vt10x virtual terminal sized to the
// session and dump the resulting grid. That deterministically yields what the
// session actually shows (the recent conversation plus the agent's input/footer) —
// which is exactly what the status model needs.
//
// Faint (SGR 2) text — Claude Code's dim autosuggestion — is blanked out first (see
// blankFaint) so the summarizer doesn't read the placeholder as the user's intent
// (parity with the tmux backend's dropDimAndAnsi). vt10x doesn't track the dim
// attribute, so we remove it from the byte stream rather than from the grid.
//
// cols/rows are the session's current ConPTY size; 0 (never sized) falls back to the
// ConPTY defaults. Output is the visible screen (its natural bound), so the caller's
// line budget isn't needed to cap it.
func renderRing(b []byte, cols, rows int) string {
	if len(b) == 0 {
		return ""
	}
	if cols <= 0 || cols > 1000 {
		cols = defCols
	}
	if rows <= 0 || rows > 1000 {
		rows = defRows
	}
	vt := vt10x.New(vt10x.WithSize(cols, rows))
	_, _ = vt.Write(blankFaint(b))
	screen := vt.String()

	lines := strings.Split(screen, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t")
	}
	end := len(lines)
	for end > 0 && lines[end-1] == "" { // trim trailing blank rows
		end--
	}
	start := 0
	for start < end && lines[start] == "" { // trim leading blank rows
		start++
	}
	return strings.Join(lines[start:end], "\n")
}

// blankFaint overwrites faint (SGR 2) ASCII characters with spaces, copying every
// escape sequence and every other byte through verbatim. Blanking (rather than
// deleting) keeps each character's column so the virtual terminal lays out the rest
// of the screen exactly as it would have — only the dim text becomes blanks. SGR
// faint state is tracked across the stream: 2 turns it on; 0/22 (and a bare ESC[m)
// turn it off; parameters within one SGR are applied left-to-right.
func blankFaint(b []byte) []byte {
	out := make([]byte, 0, len(b))
	faint := false
	for i := 0; i < len(b); {
		c := b[i]
		if c == 0x1b && i+1 < len(b) && b[i+1] == '[' { // CSI: copy verbatim, track faint on SGR
			j := i + 2
			for j < len(b) && !(b[j] >= 0x40 && b[j] <= 0x7e) {
				j++
			}
			if j < len(b) && b[j] == 'm' { // SGR
				for _, par := range strings.Split(string(b[i+2:j]), ";") {
					switch par {
					case "2":
						faint = true
					case "0", "22", "":
						faint = false
					}
				}
			}
			seqEnd := j + 1
			if j >= len(b) {
				seqEnd = len(b)
			}
			out = append(out, b[i:seqEnd]...)
			i = seqEnd
			continue
		}
		// Blank only printable ASCII faint chars (the autosuggestion is ASCII); leaving
		// multibyte bytes untouched avoids miscounting a rune's display width.
		if faint && c >= 0x20 && c < 0x7f {
			out = append(out, ' ')
			i++
			continue
		}
		out = append(out, c)
		i++
	}
	return out
}
