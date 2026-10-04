// Package terminaltext normalizes captured terminal streams to visible text.
package terminaltext

import "strings"

// Plain removes terminal control sequences, including OSC hyperlinks (whose
// labels remain visible), and optionally text painted FAINT. It does not emulate
// cursor movement: callers provide an already laid-out terminal capture.
func Plain(b []byte, dropFaint bool) string {
	out := make([]byte, 0, len(b))
	faint := false
	for i := 0; i < len(b); {
		if b[i] == 0x1b {
			if i+1 == len(b) {
				break
			}
			switch b[i+1] {
			case '[': // CSI: parameter/intermediate bytes followed by a final byte.
				j := i + 2
				for j < len(b) && b[j] >= 0x20 && b[j] <= 0x3f {
					j++
				}
				if j < len(b) && b[j] >= 0x40 && b[j] <= 0x7e {
					if b[j] == 'm' {
						faint = sgrFaint(string(b[i+2:j]), faint)
					}
					j++
				}
				i = j
			case ']', 'P', 'X', '^', '_': // OSC, DCS, SOS, PM, APC string controls.
				osc := b[i+1] == ']'
				i += 2
				for i < len(b) {
					if osc && b[i] == 0x07 { // OSC also accepts BEL.
						i++
						break
					}
					if b[i] == 0x1b && i+1 < len(b) && b[i+1] == '\\' {
						i += 2
						break
					}
					i++
				}
			default: // Single escapes and intermediate forms such as ESC ( B.
				i++
				for i < len(b) && b[i] >= 0x20 && b[i] <= 0x2f {
					i++
				}
				if i < len(b) && b[i] >= 0x30 && b[i] <= 0x7e {
					i++
				}
			}
			continue
		}
		if (!dropFaint || !faint) && (b[i] >= 0x20 && b[i] != 0x7f || b[i] == '\n' || b[i] == '\r' || b[i] == '\t') {
			out = append(out, b[i])
		}
		i++
	}
	return string(out)
}

func sgrFaint(parameters string, faint bool) bool {
	params := strings.Split(parameters, ";")
	for i := 0; i < len(params); i++ {
		switch params[i] {
		case "2":
			faint = true
		case "0", "22", "":
			faint = false
		case "38", "48", "58":
			// RGB/palette values are not independent SGR codes. In particular a
			// color's '2' or '0' must not toggle FAINT. Colon forms are atomic.
			if i+1 < len(params) {
				switch params[i+1] {
				case "2":
					i += 4
				case "5":
					i += 2
				}
			}
		}
	}
	return faint
}
