package tmux

import "testing"

// layoutSize parses the WxH out of tmux layout strings as emitted by
// %layout-change — the authoritative pane size all viewers must render at.
func TestLayoutSize(t *testing.T) {
	cases := []struct {
		layout string
		w, h   int
		ok     bool
	}{
		{"ac1d,97x31,0,0,0", 97, 31, true},
		{"bdbd,139x53,0,0,0", 139, 53, true},
		// split layout: the leading size is still the whole window's
		{"fa1c,208x62,0,0{104x62,0,0,1,103x62,105,0,2}", 208, 62, true},
		{"garbage", 0, 0, false},
		{"ac1d,notasize,0", 0, 0, false},
		{"ac1d,0x0,0", 0, 0, false},
		{"", 0, 0, false},
	}
	for _, c := range cases {
		w, h, ok := layoutSize(c.layout)
		if w != c.w || h != c.h || ok != c.ok {
			t.Errorf("layoutSize(%q) = (%d,%d,%v), want (%d,%d,%v)", c.layout, w, h, ok, c.w, c.h, c.ok)
		}
	}
}
