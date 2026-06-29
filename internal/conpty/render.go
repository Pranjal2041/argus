// This file is deliberately NOT build-constrained to windows (unlike the rest of
// package conpty): renderRing is pure byte-processing with no OS dependency, so
// keeping it here makes it unit-testable on any platform (see render_test.go).
package conpty

import "strings"

// renderRing turns the raw ConPTY output ring into plain text for Capture. It:
//   - drops faint (SGR 2) runs — Claude Code's dim autosuggestion, which the
//     summarizer must NOT read as the user's intent (mirrors the tmux backend's
//     dropDimAndAnsi so both platforms feed the model the same kind of text);
//   - strips every other escape sequence (CSI cursor moves, clears, colors; OSC
//     titles; lone ESC pairs) and other control bytes, keeping printable text;
//   - folds each line to the text after its LAST carriage return, so in-place
//     spinner/footer redraws (CR-overwrites) collapse to their final state;
//   - trims trailing blank lines and returns the last `lines` lines.
//
// Cursor-addressed redraws (ESC[A then re-emit) can't be perfectly de-duplicated
// without a full screen emulator, but those are the bottom input box only; the
// scrolled conversation above is emitted once and comes through clean — enough for
// an accurate status summary.
func renderRing(b []byte, lines int) string {
	out := make([]byte, 0, len(b))
	faint := false
	for i := 0; i < len(b); {
		c := b[i]
		if c == 0x1b { // ESC
			if i+1 < len(b) && b[i+1] == '[' { // CSI: params then a final byte 0x40-0x7e
				j := i + 2
				for j < len(b) && !(b[j] >= 0x40 && b[j] <= 0x7e) {
					j++
				}
				if j < len(b) && b[j] == 'm' { // SGR - track faint across the stream
					for _, par := range strings.Split(string(b[i+2:j]), ";") {
						switch par {
						case "2":
							faint = true
						case "0", "22", "":
							faint = false
						}
					}
				}
				if j < len(b) {
					i = j + 1
				} else {
					i = len(b)
				}
				continue
			}
			if i+1 < len(b) && b[i+1] == ']' { // OSC: terminated by BEL or ST (ESC\)
				j := i + 2
				for j < len(b) && b[j] != 0x07 && b[j] != 0x1b {
					j++
				}
				if j < len(b) && b[j] == 0x1b && j+1 < len(b) && b[j+1] == '\\' {
					j++ // also consume the backslash of ST
				}
				if j < len(b) {
					i = j + 1
				} else {
					i = len(b)
				}
				continue
			}
			i += 2 // other ESC x - drop ESC and the following byte
			continue
		}
		if c < 0x20 && c != '\n' && c != '\r' && c != '\t' {
			i++ // drop other control bytes
			continue
		}
		if !faint {
			out = append(out, c)
		}
		i++
	}

	folded := make([]string, 0, 256)
	for _, ln := range strings.Split(string(out), "\n") {
		if k := strings.LastIndexByte(ln, '\r'); k >= 0 {
			ln = ln[k+1:] // keep only the last write to this line
		}
		folded = append(folded, strings.TrimRight(ln, " \t"))
	}
	end := len(folded)
	for end > 0 && folded[end-1] == "" { // trim trailing blank lines
		end--
	}
	folded = folded[:end]
	if len(folded) > lines {
		folded = folded[len(folded)-lines:]
	}
	return strings.Join(folded, "\n")
}
