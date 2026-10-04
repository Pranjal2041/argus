package tmux

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/hinshun/vt10x"
)

// These sessions live on their own server, never the user's tmux socket.
func snapshotFixture(t *testing.T, output string, x, y int) *Client {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("argus-snapshot-test-%d", time.Now().UnixNano())
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	quoted := "'" + strings.ReplaceAll(output, "'", "'\\''") + "'"
	cmd := "printf '%s' " + quoted + "; exec sleep 30"
	if b, err := exec.Command("tmux", "-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "fixture", "-x", "40", "-y", "8", cmd).CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v: %s", err, b)
	}
	c := &Client{socket: socket, primary: "%0"}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c.paneFlag("#{cursor_x},#{cursor_y}") == fmt.Sprintf("%d,%d", x, y) {
			return c
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("fixture cursor never settled: %s", c.paneFlag("#{cursor_x},#{cursor_y}"))
	return nil
}

func TestSnapshotArrivesInsideControlOutputStream(t *testing.T) {
	fixture := snapshotFixture(t, "\x1b[2J\x1b[Hprompt> typed\x1b[90m suggestion\x1b[0m\x1b[1;14H", 13, 0)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, fixture.socket, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err = c.Resize(40, 8); err != nil {
		t.Fatal(err)
	}
	if err = c.RequestSnapshot(17); err != nil {
		t.Fatal(err)
	}
	var capture Output
	for capture.SnapshotID == 0 {
		select {
		case capture = <-c.Output():
		case <-ctx.Done():
			t.Fatal("snapshot never arrived in output stream")
		}
	}
	if capture.SnapshotID != 17 || capture.Cols != 40 || len(capture.Data) == 0 {
		t.Fatalf("invalid snapshot: id=%d size=%dx%d bytes=%d", capture.SnapshotID, capture.Cols, capture.Rows, len(capture.Data))
	}
	vt := vt10x.New(vt10x.WithSize(capture.Cols, capture.Rows))
	_, _ = vt.Write(capture.Data)
	want := vt.Cursor()
	if want.X != 13 || want.Y != 0 {
		t.Fatalf("cursor after in-band capture: %+v", want)
	}
	if err = c.SendKeys(c.Pane(), []byte("Z")); err != nil {
		t.Fatal(err)
	}
	for {
		select {
		case out := <-c.Output():
			if out.SnapshotID == 0 && len(out.Data) > 0 {
				_, _ = vt.Write(out.Data)
				if vt.Cell(13, 0).Char == 'Z' {
					return
				}
			}
		case <-ctx.Done():
			t.Fatal("live input did not continue at restored cursor")
		}
	}
}

func TestSnapshotPreservesEditingCursor(t *testing.T) {
	for _, tc := range []struct {
		name, output string
		x, y         int
	}{
		{"inline suggestion", "\x1b[2J\x1b[Hprompt> typed\x1b[90m suggestion-to-the-right\x1b[0m\x1b[1;14H", 13, 0},
		{"wrapped input", "\x1b[2J\x1b[H" + strings.Repeat("p", 37) + "abcd\x1b[90m suggested\x1b[0m\x1b[2;2H", 1, 1},
		{"alternate screen", "\x1b[?1049h\x1b[2J\x1b[Hheader\x1b[4;2Hedit\x1b[8;1Hfooter\x1b[4;6H", 5, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := snapshotFixture(t, tc.output, tc.x, tc.y)
			vt := vt10x.New(vt10x.WithSize(40, 8))
			_, _ = vt.Write(c.Snapshot())
			cursor := vt.Cursor()
			if cursor.X != tc.x || cursor.Y != tc.y {
				t.Fatalf("restored cursor=(%d,%d), shell cursor=(%d,%d)", cursor.X, cursor.Y, tc.x, tc.y)
			}
			_, _ = vt.Write([]byte("X"))
			if cell := vt.Cell(tc.x, tc.y); cell.Char != 'X' {
				t.Fatalf("new input did not land at editing cursor: %q", cell.Char)
			}
		})
	}
}

func TestSnapshotPreservesPendingWrapIncludingTrailingSpaces(t *testing.T) {
	for _, line := range []string{strings.Repeat("x", 40), strings.Repeat("x", 38) + "  "} {
		c := snapshotFixture(t, "\x1b[2J\x1b[H"+line, 40, 0)
		vt := vt10x.New(vt10x.WithSize(40, 8))
		_, _ = vt.Write(c.Snapshot())
		_, _ = vt.Write([]byte("Z"))
		if vt.Cell(0, 1).Char != 'Z' {
			t.Fatalf("pending wrap lost: %q", vt.String())
		}
	}
}

func TestCapturedControlLookingTextRemainsData(t *testing.T) {
	c := &Client{primary: "%0", outCh: make(chan Output, 4)}
	c.handleLine("ARGUS_SNAPSHOT_BEGIN:17 40 8 0 0 0 1 1 0 0 0 7 0 0 0 0 0")
	c.handleLine("%end 100 1 1")
	c.handleLine("%begin 100 2 1")
	for _, line := range []string{"%output %0 not-live", "ARGUS_SNAPSHOT_END:17", "%layout-change @0 bad", "", "", "", "", ""} {
		c.handleLine(line)
	}
	c.handleLine("%end 100 2 1")
	c.handleLine("%begin 100 3 1")
	c.handleLine("ARGUS_SNAPSHOT_END:17")
	if len(c.outCh) != 1 {
		t.Fatalf("capture leaked into live stream: %d events", len(c.outCh))
	}
	out := <-c.outCh
	if out.SnapshotID != 17 || !strings.Contains(string(out.Data), "%output %0 not-live") || !strings.Contains(string(out.Data), "ARGUS_SNAPSHOT_END:17") {
		t.Fatal("capture text was treated as control protocol")
	}
}

func TestSnapshotRestoresApplicationMouseModes(t *testing.T) {
	for _, tc := range []struct {
		name, modes, tracking, encoding string
	}{
		{"full-screen SGR any-event", "\x1b[?1049h\x1b[?1003h\x1b[?1006h", "1003", "1006"},
		{"normal-screen legacy buttons", "\x1b[?1000h", "1000", ""},
		{"UTF8 button tracking", "\x1b[?1002h\x1b[?1005h", "1002", "1005"},
		{"disabled after application exit", "\x1b[?1003h\x1b[?1006h\x1b[?1003l\x1b[?1006l", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fixture := snapshotFixture(t, tc.modes+"\x1b[2J\x1b[Hready", 5, 0)
			check := func(data []byte) {
				t.Helper()
				wire := string(data)
				for _, mode := range []string{"1000", "1002", "1003", "1005", "1006"} {
					want := mode == tc.tracking || mode == tc.encoding
					if strings.Contains(wire, "\x1b[?"+mode+"h") != want {
						t.Fatalf("mode %s enabled=%v: %q", mode, want, wire)
					}
					if !strings.Contains(wire, "\x1b[?"+mode+"l") {
						t.Fatalf("snapshot does not clear stale mode %s: %q", mode, wire)
					}
				}
			}
			check(fixture.Snapshot())
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			client, err := Dial(ctx, fixture.socket, "fixture")
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if err := client.RequestSnapshot(23); err != nil {
				t.Fatal(err)
			}
			for {
				select {
				case out := <-client.Output():
					if out.SnapshotID == 23 {
						check(out.Data)
						return
					}
				case <-ctx.Done():
					t.Fatal("ordered mouse snapshot never arrived")
				}
			}
		})
	}
}

func TestSnapshotRejectsMissingMouseMetadata(t *testing.T) {
	if got := decodeScreenSnapshot([]byte("40 8 0 0 0 1 1 0 0 0 7\n" + strings.Repeat("\n", 8))).ANSI(); got != nil {
		t.Fatal("partial metadata must not silently erase application input state")
	}
}
