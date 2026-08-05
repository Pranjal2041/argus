// This file is deliberately NOT build-constrained to windows (unlike the rest of
// package conpty): it is pure, cross-platform Go (vt10x is portable), so keeping it
// here makes the rendering unit-testable on any platform (see render_test.go).
package conpty

import (
	"bytes"
	"strings"
	"unicode/utf8"

	"github.com/hinshun/vt10x"
)

// ConPTY default session size, shared with the windows backend (conpty.go).
const (
	defCols = 120
	defRows = 30
)

// renderRing reconstructs a complete VT stream's current screen as plain text. It
// remains the small pure helper used by tests and one-shot callers; live ConPTY
// sessions use captureScreen incrementally because their bounded raw ring is only a
// suffix and therefore is not a valid stream once its beginning has been evicted.
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
	screen := newCaptureScreen(cols, rows)
	screen.write(b)
	return screen.text()
}

// captureScreen is the broker's authoritative, incrementally-maintained view of a
// ConPTY screen. Keeping the emulator alive matters: a TUI paints most of its screen
// once, then may emit megabytes of cursor-addressed spinner updates. Re-emulating an
// arbitrary suffix of that stream loses the original paint (and a suffix can begin
// midway through an escape sequence), which made /recent intermittently blank.
//
// Resize is applied at the same moment as the real ConPTY resize, so bytes produced
// at different terminal widths are never replayed as though they all had the latest
// width. The bounded raw ring remains useful for reconnect/state detection, but it is
// no longer treated as a terminal checkpoint.
type captureScreen struct {
	vt       vt10x.Terminal
	cols     int
	rows     int
	faint    faintFilter
	utf8Tail []byte
}

func newCaptureScreen(cols, rows int) *captureScreen {
	if cols <= 0 || cols > 1000 {
		cols = defCols
	}
	if rows <= 0 || rows > 1000 {
		rows = defRows
	}
	return &captureScreen{
		vt:   vt10x.New(vt10x.WithSize(cols, rows)),
		cols: cols,
		rows: rows,
	}
}

func (s *captureScreen) resize(cols, rows int) {
	if cols <= 0 || rows <= 0 || cols > 1000 || rows > 1000 || (cols == s.cols && rows == s.rows) {
		return
	}
	s.vt.Resize(cols, rows)
	s.cols, s.rows = cols, rows
}

func (s *captureScreen) write(b []byte) {
	filtered := s.faint.filter(b)
	if len(s.utf8Tail) > 0 {
		joined := make([]byte, 0, len(s.utf8Tail)+len(filtered))
		joined = append(joined, s.utf8Tail...)
		joined = append(joined, filtered...)
		filtered = joined
		s.utf8Tail = s.utf8Tail[:0]
	}

	// vt10x keeps escape-parser state across Write calls, but an incomplete UTF-8
	// rune at the end of a pipe read must be carried into the next call explicitly.
	end := completeUTF8Prefix(filtered)
	if end > 0 {
		_, _ = s.vt.Write(filtered[:end])
	}
	if end < len(filtered) {
		s.utf8Tail = append(s.utf8Tail, filtered[end:]...)
	}
}

func completeUTF8Prefix(b []byte) int {
	for i := 0; i < len(b); {
		if b[i] < utf8.RuneSelf {
			i++
			continue
		}
		if !utf8.FullRune(b[i:]) {
			return i
		}
		_, n := utf8.DecodeRune(b[i:])
		if n == 0 {
			return i
		}
		i += n
	}
	return len(b)
}

func (s *captureScreen) text() string {
	return trimScreen(s.vt.String())
}

func trimScreen(screen string) string {
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

// faintFilter is blankFaint made streaming: ConPTY may split an SGR sequence
// across pipe reads, so both the pending escape and faint state must survive calls.
// It deliberately blanks rather than removes text to preserve terminal columns.
type faintFilter struct {
	faint   bool
	pending []byte
}

func (f *faintFilter) filter(b []byte) []byte {
	if len(f.pending) > 0 {
		joined := make([]byte, 0, len(f.pending)+len(b))
		joined = append(joined, f.pending...)
		joined = append(joined, b...)
		b = joined
		f.pending = f.pending[:0]
	}

	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		c := b[i]
		if c == 0x1b {
			if i+1 >= len(b) {
				f.pending = append(f.pending, b[i:]...)
				break
			}
			if b[i+1] == '[' {
				j := i + 2
				for j < len(b) && !(b[j] >= 0x40 && b[j] <= 0x7e) {
					j++
				}
				if j >= len(b) {
					f.pending = append(f.pending, b[i:]...)
					break
				}
				if b[j] == 'm' {
					for _, par := range strings.Split(string(b[i+2:j]), ";") {
						switch par {
						case "2":
							f.faint = true
						case "0", "22", "":
							f.faint = false
						}
					}
				}
				out = append(out, b[i:j+1]...)
				i = j + 1
				continue
			}
		}

		if f.faint && c >= 0x20 && c < 0x7f {
			out = append(out, ' ')
		} else {
			out = append(out, c)
		}
		i++
	}
	return out
}

// blankFaint overwrites faint (SGR 2) ASCII characters with spaces, copying every
// escape sequence and every other byte through verbatim. Blanking (rather than
// deleting) keeps each character's column so the virtual terminal lays out the rest
// of the screen exactly as it would have — only the dim text becomes blanks. SGR
// faint state is tracked across the stream: 2 turns it on; 0/22 (and a bare ESC[m)
// turn it off; parameters within one SGR are applied left-to-right.
func blankFaint(b []byte) []byte {
	var f faintFilter
	out := f.filter(b)
	// Preserve the historical helper's behavior for a truncated final escape: it
	// copied those bytes through rather than dropping them.
	return append(out, bytes.Clone(f.pending)...)
}
