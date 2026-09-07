package session

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/hinshun/vt10x"
)

func TestScreenSnapshotPreservesViewportAndContinuation(t *testing.T) {
	// Same wire fixtures run in the actual Mac terminal (TerminalSnapshotTests).
	var fixtures []struct {
		Name         string
		Snapshot     ScreenSnapshot
		ANSI         string
		NextX, NextY int
		Wide         bool
	}
	data, err := os.ReadFile("testdata/screen-snapshots.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &fixtures); err != nil {
		t.Fatal(err)
	}
	for _, tc := range fixtures {
		t.Run(tc.Name, func(t *testing.T) {
			if got := string(tc.Snapshot.ANSI()); got != tc.ANSI {
				t.Fatalf("wire fixture diverged: got %q, want %q", got, tc.ANSI)
			}
			if tc.Wide {
				return
			} // SwiftTerm checks continuation; vt10x models every rune as one cell.
			vt := vt10x.New(vt10x.WithSize(tc.Snapshot.Cols, tc.Snapshot.Rows))
			for i := 0; i < 2; i++ {
				_, _ = vt.Write([]byte(tc.ANSI))
				if tc.Name == "history-blank-rows" && vt.Cell(0, 0).Char != 'v' {
					t.Fatalf("viewport shifted: %q", vt.String())
				}
				_, _ = vt.Write([]byte("Z"))
				if vt.Cell(tc.NextX, tc.NextY).Char != 'Z' {
					t.Fatalf("input landed in wrong cell: %q", vt.String())
				}
			}
		})
	}
}

func TestScreenSnapshotRejectsIncompleteCapture(t *testing.T) {
	s := ScreenSnapshot{Cols: 40, Rows: 8, Lines: []string{"partial"}}
	if s.ANSI() != nil {
		t.Fatal("partial capture must not replace a usable display")
	}
}
