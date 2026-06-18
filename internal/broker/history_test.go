package broker

import (
	"testing"

	"universal-tmux/internal/session"
)

// recordHistory starts a record on first sight, keeps one folder span while the cwd
// is unchanged, and appends a new span when the folder changes — so a session's
// folder history is recoverable. (histPath="" → saveHistoryLocked is a no-op.)
func TestRecordHistoryFolders(t *testing.T) {
	m := &Manager{history: map[string]*SessionHistory{}, histNode: "node1"}

	m.recordHistory([]session.Info{{Name: "logits", Path: "/data/logits", Agent: false}})
	m.recordHistory([]session.Info{{Name: "logits", Path: "/data/logits"}}) // unchanged cwd
	m.recordHistory([]session.Info{{Name: "logits", Path: "/data/logits/sub"}})

	hist := m.History()
	if len(hist) != 1 {
		t.Fatalf("want 1 record, got %d", len(hist))
	}
	r := hist[0]
	if r.Name != "logits" || r.Node != "node1" {
		t.Fatalf("bad name/node: %q/%q", r.Name, r.Node)
	}
	if len(r.Folders) != 2 {
		t.Fatalf("want 2 folder spans, got %d: %+v", len(r.Folders), r.Folders)
	}
	if r.Folders[0].Path != "/data/logits" || r.Folders[1].Path != "/data/logits/sub" {
		t.Fatalf("folder order wrong: %+v", r.Folders)
	}
	if r.First == 0 || r.Last == 0 || r.Last < r.First {
		t.Fatalf("bad timestamps: first=%d last=%d", r.First, r.Last)
	}
	if r.Alive { // nothing in sessCache
		t.Fatal("Alive should be false when not in the current session list")
	}
}
