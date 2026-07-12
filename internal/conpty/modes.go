// Pure, cross-platform Go (like render.go, NOT build-constrained to windows) so
// it is unit-testable on any platform.
package conpty

import (
	"fmt"
	"sort"
)

// modeTracker follows the DEC private modes (CSI ? Pm h / l) an app sets on its
// terminal as output flows by, so the ConPTY snapshot can RE-EMIT the currently
// active modes when a client attaches. Without this, a mode set once at startup
// (most importantly bracketed paste, CSI ? 2004 h) is lost as soon as it scrolls
// out of the bounded output ring — and a client attaching to a long-running
// agent then pastes UNBRACKETED, so newlines submit line-by-line and only the
// last line survives. tmux restores modes on attach; ConPTY had no equivalent.
//
// It is a byte-fed state machine so a sequence split across two reads is tracked
// correctly (state persists between feed calls).
type modeTracker struct {
	state  int   // 0 ground, 1 saw ESC, 2 saw CSI, 3 collecting private params
	num    int   // current parameter being accumulated
	haveN  bool  // a digit was seen for the current parameter
	params []int // parameters collected in the current CSI ? ... sequence
	on     map[int]bool
}

func (m *modeTracker) feed(b []byte) {
	for _, c := range b {
		switch m.state {
		case 0:
			if c == 0x1b {
				m.state = 1
			}
		case 1:
			if c == '[' {
				m.state = 2
			} else {
				m.state = 0
			}
		case 2:
			if c == '?' { // a private-mode CSI (DEC modes live here)
				m.state = 3
				m.num, m.haveN = 0, false
				m.params = m.params[:0]
			} else {
				m.state = 0 // some other CSI — not a DEC private mode; ignore
			}
		case 3:
			switch {
			case c >= '0' && c <= '9':
				m.num = m.num*10 + int(c-'0')
				m.haveN = true
			case c == ';':
				if m.haveN {
					m.params = append(m.params, m.num)
				}
				m.num, m.haveN = 0, false
			case c == 'h' || c == 'l':
				if m.haveN {
					m.params = append(m.params, m.num)
				}
				if m.on == nil {
					m.on = map[int]bool{}
				}
				set := c == 'h'
				for _, p := range m.params {
					m.on[p] = set
				}
				m.state = 0
			default:
				m.state = 0 // e.g. CSI ? Pm $ p (a query) — not a set/reset
			}
		}
	}
}

// restore returns the CSI ? N h sequences for every currently-set private mode,
// sorted for determinism, to prepend to a snapshot. Empty when nothing is set.
func (m *modeTracker) restore() []byte {
	if len(m.on) == 0 {
		return nil
	}
	keys := make([]int, 0, len(m.on))
	for k, v := range m.on {
		if v {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		return nil
	}
	sort.Ints(keys)
	var out []byte
	for _, k := range keys {
		out = append(out, []byte(fmt.Sprintf("\x1b[?%dh", k))...)
	}
	return out
}
