package broker

import (
	"os"
	"strings"
	"testing"
)

// point the inbox at a temp home so tests never touch the real one
func withTempHome(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
}

func TestJournalRoundtrip(t *testing.T) {
	withTempHome(t)
	if err := JournalAppend([]byte(`{"id":"a","kind":"utterance"}`)); err != nil {
		t.Fatal(err)
	}
	if err := JournalAppend([]byte(`{"id":"b","kind":"utterance"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	off, data := JournalPeek()
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"a"`) || !strings.Contains(lines[1], `"b"`) {
		t.Fatalf("peek: %q", string(data))
	}
	if err := JournalAck(off); err != nil {
		t.Fatal(err)
	}
	if off2, data2 := JournalPeek(); off2 != 0 || len(data2) != 0 {
		t.Fatalf("after ack: off=%d data=%q", off2, string(data2))
	}
}

func TestJournalAckPreservesRacedAppends(t *testing.T) {
	withTempHome(t)
	_ = JournalAppend([]byte(`{"id":"one"}`))
	off, _ := JournalPeek()
	_ = JournalAppend([]byte(`{"id":"two"}`)) // lands after the peek
	if err := JournalAck(off); err != nil {
		t.Fatal(err)
	}
	_, data := JournalPeek()
	if !strings.Contains(string(data), `"two"`) || strings.Contains(string(data), `"one"`) {
		t.Fatalf("raced append lost or ack under-truncated: %q", string(data))
	}
}

func TestJournalAckBeyondLength(t *testing.T) {
	withTempHome(t)
	_ = JournalAppend([]byte(`{"id":"x"}`))
	if err := JournalAck(1 << 20); err != nil {
		t.Fatal(err)
	}
	if off, data := JournalPeek(); off != 0 || len(data) != 0 {
		t.Fatalf("over-ack should clear: off=%d data=%q", off, string(data))
	}
	// ack on a missing file is a no-op
	_ = os.Remove(journalInboxPath())
	if err := JournalAck(10); err != nil {
		t.Fatal(err)
	}
}
