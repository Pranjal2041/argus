package terminaltext

import "testing"

func TestPlain(t *testing.T) {
	for _, tc := range []struct {
		name, raw, want string
		dropFaint       bool
	}{
		{"osc8-st", "before \x1b]8;id=42;https://example.test/a\x1b\\visible label\x1b]8;;\x1b\\ after", "before visible label after", false},
		{"osc8-bel", "\x1b]8;;https://example.test/\avisible\x1b]8;;\a", "visible", false},
		{"other-controls", "a\x1b]0;window title\ab\x1bPpayload\x1b\\c\x1b_hidden\x1b\\d\x1b(Bé→", "abcdé→", false},
		{"faint-link", "a\x1b[2m\x1b]8;;https://example.test\aunsent draft\x1b]8;;\a\x1b[22mb", "ab", true},
		{"keep-faint", "a\x1b[2mvisible\x1b[mb", "avisibleb", false},
		{"rgb-is-not-faint", "\x1b[38;2;2;0;22mforeground\x1b[48;2;0;2;22mbackground", "foregroundbackground", true},
		{"palette-is-not-faint", "\x1b[38;5;2mgreen\x1b[48;5;2mbackground", "greenbackground", true},
		{"color-does-not-reset-faint", "a\x1b[2;38;2;0;22;2mhidden\x1b[0mb", "ab", true},
		{"colon-color", "\x1b[38:2::2:0:22mvisible\x1b[2mhidden\x1b[mb", "visibleb", true},
		{"truncated-osc", "visible\x1b]8;;incomplete", "visible", false},
		{"truncated-csi", "visible\x1b[38;2;", "visible", false},
		{"malformed-csi", "a\x1b[1;\nnext", "a\nnext", false},
		{"controls-unicode", "\aé中😎\ttext\r\n\x7f", "é中😎\ttext\r\n", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := Plain([]byte(tc.raw), tc.dropFaint); got != tc.want {
				t.Fatalf("Plain = %q, want %q", got, tc.want)
			}
		})
	}
}
