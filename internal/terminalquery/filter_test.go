package terminalquery

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSharedRendererFixtures(t *testing.T) {
	data, err := os.ReadFile("testdata/streams.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixtures []struct{ Name, Live, Passive string }
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	for _, fixture := range fixtures {
		var f Filter
		a, p := f.Feed([]byte(fixture.Live))
		if string(a) != fixture.Live || string(p) != fixture.Passive {
			t.Fatalf("fixture %s: %q / %q", fixture.Name, a, p)
		}
	}
}

func TestQueriesArePassiveAtEverySplit(t *testing.T) {
	queries := []string{
		"\x05", "\x1bZ", "\x1b[c", "\x1b[0c", "\x1b[>c", "\x1b[=c",
		"\x1b[5n", "\x1b[6n", "\x1b[?6n", "\x1b[?2004$p", "\x1b[4$p",
		"\x1b[>0q", "\x1b[?u", "\x1b[0x", "\x1b[1;1;1;1;3;3*y", "\x1b[1'|",
		"\x1b[11t", "\x1b[13;2t", "\x1b[14t", "\x1b[16t", "\x1b[18t", "\x1b[21t",
		"\x1b]10;?\a", "\x1b]11;?\x1b\\", "\x1b]12;?\a", "\x1b]4;0;?;255;?\a",
		"\x1b]52;c;?\a", "\x1bP$qm\x1b\\", "\x1bP+q544e;524742\x1b\\",
		"\x9b6n", "\x9d11;?\x9c", "\x90$qm\x9c",
	}
	for _, query := range queries {
		input := []byte("before" + query + "after")
		for split := 0; split <= len(input); split++ {
			var f Filter
			a, p := f.Feed(input[:split])
			aa, pp := f.Feed(input[split:])
			if !bytes.Equal(append(a, aa...), input) {
				t.Fatalf("active changed %q at %d", query, split)
			}
			if got := string(append(p, pp...)); got != "beforeafter" {
				t.Fatalf("query %q at %d leaked: %q", query, split, got)
			}
		}
	}
}

func TestDisplayAndInputModesAreUnchanged(t *testing.T) {
	display := "hello؛✓🎉\r\n\t\a" +
		"\x1b[38;2;10;20;30mRGB\x1b[0m\x1b[2J\x1b[4;8H\x1b7\x1b8" +
		"\x1b[?1049h\x1b[?1000h\x1b[?1006h\x1b[?1004h\x1b[?2004h\x1b[?2026h" +
		"\x1b[>1u\x1b[<u\x1b[=3u\x1b[2 q\x1b[8;24;80t\x1b[22;0t\x1b[1*x\x1b[65;1;1;2;2$x" +
		"\x1b]0;title?\a\x1b]8;;https://example.com/?q=test\x1b\\link\x1b]8;;\x1b\\" +
		"\x1b]4;0;#aabbcc;1;rgb:aa/bb/cc\a\x1b]10;#fff;#000\a\x1b]52;c;aGVsbG8=\a" +
		"\x1bPq#0;2;0;0;0!10~\x1b\\\x1b_Gf=100;image\x1b\\\x1b(B"
	var f Filter
	var active, passive []byte
	for _, b := range []byte(display) {
		a, p := f.Feed([]byte{b})
		active, passive = append(active, a...), append(passive, p...)
	}
	if string(active) != display || string(passive) != display {
		t.Fatalf("display changed\nactive=%q\npassive=%q", active, passive)
	}
}

func TestMixedColorSetAndQueryPreservesSet(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"\x1b]4;0;#fff;1;?;2;#000\a", "\x1b]4;0;#fff;2;#000\a"},
		{"\x1b]10;?;#000;?\x1b\\", "\x1b]11;#000\x1b\\"},
		{"\x9d10;#fff;?;#abc\x9c", "\x9d10;#fff\x9c\x9d12;#abc\x9c"},
	} {
		var f Filter
		a, p := f.Feed([]byte(tc.in))
		if string(a) != tc.in || string(p) != tc.want {
			t.Fatalf("mixed command %q: %q / %q", tc.in, a, p)
		}
	}
}

func TestLargeOpaquePayloadsStreamWithoutBuffering(t *testing.T) {
	for _, prefix := range []string{"\x1b]52;c;", "\x1b]1337;File=", "\x1bPq", "\x1b_Gf=100;"} {
		var f Filter
		input := prefix + strings.Repeat("X", 2*maxControl)
		a, p := f.Feed([]byte(input))
		if string(a) != input || string(p) != input || len(f.pending) != 0 {
			t.Fatalf("opaque payload %q stalled or changed", prefix)
		}
		a, p = f.Feed([]byte("\x1b\\\x1b[6ntext"))
		if string(a) != "\x1b\\\x1b[6ntext" || string(p) != "\x1b\\text" {
			t.Fatalf("opaque terminator lost: %q / %q", a, p)
		}
	}
}

func TestMalformedControlBoundedAndCancelled(t *testing.T) {
	var f Filter
	_, p := f.Feed([]byte("\x1b[" + strings.Repeat("1", maxControl*2)))
	if len(f.pending) > maxControl || len(p) != 0 {
		t.Fatal("unbounded or leaked control")
	}
	_, p = f.Feed([]byte("\x18ok\x1b[6n"))
	if string(p) != "\x18ok" {
		t.Fatalf("cancel failed: %q", p)
	}
}

func TestEscapeCanTerminateStringAndStartQuery(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"\x1b]0;title\x1b[6ntext", "\x1b]0;title\x1b\\text"},
		{"\x1b]10;?\x1b[31mred", "\x1b[31mred"},
		{"\x1bP$qm\x1b[cend", "end"},
	} {
		var f Filter
		var active, passive []byte
		for _, b := range []byte(tc.in) {
			a, p := f.Feed([]byte{b})
			active, passive = append(active, a...), append(passive, p...)
		}
		if string(active) != tc.in || string(passive) != tc.want {
			t.Fatalf("escape terminator: %q / %q", active, passive)
		}
	}
}

func FuzzChunking(f *testing.F) {
	f.Add([]byte("hello\x1b]10;?\a\x1b[6n\x1b[?2004hworld"))
	f.Add([]byte("؛\x1bPqimage\x1b\\\x1b]52;c;YWJj\a"))
	f.Fuzz(func(t *testing.T, in []byte) {
		if len(in) > 4096 {
			t.Skip()
		}
		var whole, split Filter
		a, p := whole.Feed(in)
		var aa, pp []byte
		for _, b := range in {
			x, y := split.Feed([]byte{b})
			aa, pp = append(aa, x...), append(pp, y...)
		}
		if !bytes.Equal(a, aa) || !bytes.Equal(p, pp) {
			t.Fatal("chunk boundaries changed interpretation")
		}
	})
}
