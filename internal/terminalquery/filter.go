// Package terminalquery separates terminal queries from display output. It
// operates on OUTPUT, never on input: an escape sequence typed or pasted by a
// user (including mouse reports) must not be mistaken for an automatic reply.
package terminalquery

import (
	"bytes"
	"strconv"
	"strings"
)

// Filter is one incremental parser per live pane. Feed returns an active stream
// (display + queries) and a passive stream (display only). Only the terminal
// endpoint may consume the active stream. Replay uses a fresh, passive parser,
// never the live parser. An incomplete control is retained across Feed calls.
// Ordinary text and opaque strings (images, titles, hyperlinks, clipboard
// writes) stream without waiting for a terminator or buffering their payload.
type Filter struct {
	kind    byte
	pending []byte
	opaque  bool
	escape  bool
	discard bool
	utf8    int
}

// Valid queries are small. Bound malformed, unterminated query candidates;
// opaque display payloads are streamed and do not count against this limit.
const maxControl = 64 * 1024

func (f *Filter) Feed(data []byte) (active, passive []byte) {
	active = make([]byte, 0, len(data))
	passive = make([]byte, 0, len(data))
	emit := func(b []byte) { active = append(active, b...); passive = append(passive, b...) }
	finish := func() {
		if !f.discard {
			active = append(active, f.pending...)
			passive = append(passive, withoutQuery(f.pending)...)
		}
		f.kind, f.opaque, f.escape, f.discard = 0, false, false, false
		f.pending = nil
	}
	for _, b := range data {
		// A UTF-8 continuation byte is not an eight-bit C1 control. For
		// example U+061B contains 0x9b and must not start a CSI sequence.
		c1 := f.utf8 == 0 || b < 0x80 || b >= 0xc0
		switch {
		case b >= 0xc2 && b <= 0xdf:
			f.utf8 = 1
		case b >= 0xe0 && b <= 0xef:
			f.utf8 = 2
		case b >= 0xf0 && b <= 0xf4:
			f.utf8 = 3
		case b >= 0x80 && b <= 0xbf && f.utf8 > 0:
			f.utf8--
		default:
			f.utf8 = 0
		}
		if f.opaque {
			if f.escape && b != '\\' {
				// ESC also ends a string when the next command is not ST.
				// Close the passive string before deciding whether that next
				// command is a query; otherwise its ESC could escape filtering.
				passive = append(passive, '\x1b', '\\')
				f.kind, f.pending, f.opaque, f.escape = 'e', []byte{0x1b}, false, false
			} else if b == 0x1b {
				f.escape = true // retain ESC until its following byte arrives
				continue
			} else {
				if f.escape {
					emit([]byte{0x1b})
				}
				emit([]byte{b})
				if b == 0x18 || b == 0x1a || (c1 && b == 0x9c) || ((f.kind == ']' || f.kind == '_') && b == 7) || (f.escape && b == '\\') {
					f.kind, f.opaque, f.escape = 0, false, false
				}
				continue
			}
		}
		if (f.kind == ']' || f.kind == 'P') && f.escape && b != '\\' {
			if !f.discard {
				prefix := f.pending[:len(f.pending)-1]
				active = append(active, prefix...)
				terminated := append(append([]byte{}, prefix...), 0x1b, '\\')
				passive = append(passive, withoutQuery(terminated)...)
			}
			f.kind, f.pending, f.escape, f.discard = 'e', []byte{0x1b}, false, false
		}
		if f.kind == 0 {
			switch {
			case b == 5: // ENQ (answerback)
				active = append(active, b)
			case b == 0x1b:
				f.kind, f.pending = 'e', []byte{b}
			case c1 && (b == 0x9b || b == 0x9d || b == 0x90):
				f.kind = map[byte]byte{0x9b: '[', 0x9d: ']', 0x90: 'P'}[b]
				f.pending = []byte{b}
			case c1 && (b == 0x98 || b == 0x9e || b == 0x9f):
				f.kind, f.opaque = 'X', true
				emit([]byte{b})
			default:
				emit([]byte{b})
			}
			continue
		}
		if b == 0x18 || b == 0x1a { // CAN/SUB cancel an unfinished control.
			if !f.discard {
				emit(f.pending)
			}
			emit([]byte{b})
			f.kind, f.pending, f.discard, f.escape = 0, nil, false, false
			continue
		}
		if (f.kind == '[' || f.kind == 'e') && b == 0x1b {
			if !f.discard {
				emit(f.pending)
			}
			f.kind, f.pending, f.discard = 'e', []byte{b}, false
			continue
		}
		if !f.discard {
			f.pending = append(f.pending, b)
			if len(f.pending) > maxControl {
				f.pending, f.discard = nil, true
			}
		}
		switch f.kind {
		case 'e':
			if len(f.pending) == 2 && strings.ContainsRune("[]P", rune(b)) {
				f.kind = b
			} else if len(f.pending) == 2 && strings.ContainsRune("X^_", rune(b)) {
				emit(f.pending)
				f.kind, f.opaque, f.pending = b, true, nil
			} else if b >= 0x30 && b <= 0x7e {
				finish()
			}
		case '[':
			if b >= 0x40 && b <= 0x7e {
				finish()
			}
		case ']', 'P':
			if (f.kind == ']' && b == 7) || (c1 && b == 0x9c) || (f.escape && b == '\\') {
				finish()
				continue
			}
			f.escape = b == 0x1b
			if !f.discard && opaqueString(f.kind, controlBody(f.pending)) {
				emit(f.pending)
				f.pending, f.opaque = nil, true
			}
		}
	}
	return active, passive
}

func controlBody(b []byte) []byte {
	if len(b) > 0 && b[0] == 0x1b {
		return b[2:]
	}
	return b[1:]
}

func opaqueString(kind byte, b []byte) bool {
	if kind == 'P' {
		for i, c := range b {
			if c >= 0x40 && c <= 0x7e {
				return !(c == 'q' && (string(b[:i]) == "$" || string(b[:i]) == "+"))
			}
		}
		return false
	}
	i := bytes.IndexByte(b, ';')
	if i < 0 {
		return false
	}
	n, _ := strconv.Atoi(string(b[:i]))
	if n == 4 || n == 5 || n >= 10 && n <= 19 {
		return false
	}
	if n == 52 {
		// Clipboard writes may be megabytes; only the literal '?' is a read.
		j := bytes.IndexByte(b[i+1:], ';')
		return j >= 0 && len(b) > i+j+2 && b[i+j+2] != '?'
	}
	return true
}

func withoutQuery(b []byte) []byte {
	if bytes.Equal(b, []byte("\x1bZ")) {
		return nil
	} // DECID
	if len(b) < 2 {
		return b
	}
	kind := b[0]
	if kind == 0x1b {
		kind = b[1]
	}
	body := controlBody(b)
	switch kind {
	case '[', 0x9b:
		if csiQuery(body) {
			return nil
		}
	case 'P', 0x90:
		if bytes.HasPrefix(body, []byte("$q")) || bytes.HasPrefix(body, []byte("+q")) {
			return nil
		}
	case ']', 0x9d:
		return passiveOSC(b, body)
	}
	return b
}

func csiQuery(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	final, p := b[len(b)-1], string(b[:len(b)-1])
	switch final {
	case 'c', 'n': // Device attributes and device/cursor status reports.
		return true
	case 'p':
		return strings.HasSuffix(p, "$") // DECRQM
	case 'q':
		return strings.HasPrefix(p, ">") // XTVERSION (not cursor shape)
	case 'u':
		return p == "?" // Keyboard enhancement query, not push/pop/set flags.
	case 'x':
		return !strings.ContainsAny(p, "$*") // DECREQTPARM, not rectangle edits
	case 'y':
		return strings.HasSuffix(p, "*") // DECRQCRA
	case '|':
		return strings.HasSuffix(p, "'") // DECRQLP (locator position)
	case 't':
		first := strings.SplitN(p, ";", 2)[0]
		n, err := strconv.Atoi(first)
		return err == nil && (n == 11 || n >= 13 && n <= 16 || n >= 18 && n <= 21)
	}
	return false
}

func passiveOSC(original, body []byte) []byte {
	end := 1 // BEL or C1 ST
	if bytes.HasSuffix(body, []byte("\x1b\\")) {
		end = 2
	}
	parts := strings.Split(string(body[:len(body)-end]), ";")
	n, _ := strconv.Atoi(parts[0])
	if n == 52 && len(parts) == 3 && parts[2] == "?" {
		return nil
	}
	prefix, suffix := original[:len(original)-len(body)], body[len(body)-end:]
	wrap := func(s string) []byte {
		r := append([]byte{}, prefix...)
		r = append(r, s...)
		return append(r, suffix...)
	}
	if n == 4 || n == 5 {
		kept, changed := []string{parts[0]}, false
		for i := 1; i < len(parts); i += 2 {
			if i+1 < len(parts) && parts[i+1] == "?" {
				changed = true
				continue
			}
			kept = append(kept, parts[i])
			if i+1 < len(parts) {
				kept = append(kept, parts[i+1])
			}
		}
		if !changed {
			return original
		}
		if len(kept) == 1 {
			return nil
		}
		return wrap(strings.Join(kept, ";"))
	}
	if n >= 10 && n <= 19 && strings.Contains(";"+strings.Join(parts[1:], ";")+";", ";?;") {
		var out []byte
		for i, value := range parts[1:] {
			if value != "?" {
				out = append(out, wrap(strconv.Itoa(n+i)+";"+value)...)
			}
		}
		return out
	}
	return original
}
