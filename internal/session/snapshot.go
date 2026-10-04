package session

import (
	"fmt"
	"strings"
)

// ScreenSnapshot is a rendered grid plus its editing position. Text alone is
// not a terminal snapshot: suggestions and full-screen widgets routinely draw
// beyond the cursor. Physical rows include empty viewport rows and history.
// Adapters translate backend state here; no shell/application names are used.
type ScreenSnapshot struct {
	Lines                                          []string
	Cols, Rows, CursorX, CursorY                   int
	Alternate, CursorVisible, Wrap, Insert, Origin bool
	ScrollTop, ScrollBottom                        int
	// Nil means the adapter cannot report mouse state. A non-nil zero value
	// explicitly turns reporting off, including modes left by a previous view.
	Mouse *MouseState
}

// MouseState is application-requested terminal state, independent of a backend
// or UI's policy for local text selection. Values are DEC private mode numbers;
// encoding zero denotes the default byte-encoded protocol.
type MouseState struct {
	Tracking int // 0, 9, 1000, 1002, 1003
	Encoding int // 0, 1005, 1006, 1015, 1016
}

func (m MouseState) ANSI() []byte {
	var out strings.Builder
	// Reset first, then enable: some emulators reset the active encoding on
	// DECRST even when the mode being reset wasn't the active one.
	for _, mode := range []int{9, 1000, 1002, 1003, 1005, 1006, 1015, 1016} {
		fmt.Fprintf(&out, "\x1b[?%dl", mode)
	}
	switch m.Tracking {
	case 9, 1000, 1002, 1003:
		fmt.Fprintf(&out, "\x1b[?%dh", m.Tracking)
	}
	switch m.Encoding {
	case 1005, 1006, 1015, 1016:
		fmt.Fprintf(&out, "\x1b[?%dh", m.Encoding)
	}
	return []byte(out.String())
}

func (s ScreenSnapshot) ANSI() []byte {
	if s.Cols < 2 || s.Rows < 2 || s.CursorX < 0 || s.CursorX > s.Cols || s.CursorY < 0 || s.CursorY >= s.Rows || len(s.Lines) < s.Rows {
		return nil // Never replace a usable display with a partial capture.
	}
	var out strings.Builder
	mode := func(number int, enabled bool) {
		suffix := 'l'
		if enabled {
			suffix = 'h'
		}
		fmt.Fprintf(&out, "\x1b[?%d%c", number, suffix)
	}
	mode(1049, s.Alternate)
	if s.Mouse != nil {
		out.Write(s.Mouse.ANSI())
	}
	// Painting must not inherit scrolling margins, insert mode, origin mode,
	// or disabled wrapping from the previous live display.
	out.WriteString("\x1b[?6l\x1b[r\x1b[4l\x1b[?7h\x1b[0m\x1b[2J\x1b[3J\x1b[H")
	out.WriteString(strings.Join(s.Lines, "\r\n"))
	out.WriteString("\x1b[0m")
	if s.ScrollTop >= 0 && s.ScrollBottom > s.ScrollTop && s.ScrollBottom < s.Rows {
		fmt.Fprintf(&out, "\x1b[%d;%dr", s.ScrollTop+1, s.ScrollBottom+1)
	}
	mode(6, s.Origin)
	mode(7, s.Wrap)
	mode(25, s.CursorVisible)
	y := s.CursorY + 1
	if s.Origin {
		y -= s.ScrollTop
	}
	if s.CursorX == s.Cols && s.Wrap {
		// CUP clamps to the last cell and loses DECAWM's pending wrap. Repaint
		// the captured cursor row to re-arm it, including wide/styled cells.
		fmt.Fprintf(&out, "\x1b[%d;1H\x1b[0m", y)
		out.WriteString(s.Lines[len(s.Lines)-s.Rows+s.CursorY])
		out.WriteString("\x1b[0m")
	} else {
		x := s.CursorX
		if x >= s.Cols {
			x = s.Cols - 1
		}
		fmt.Fprintf(&out, "\x1b[%d;%dH", y, x+1)
	}
	if s.Insert {
		out.WriteString("\x1b[4h")
	}
	return []byte(out.String())
}
