package broker

import (
	"path/filepath"
	"testing"

	"universal-tmux/internal/session"
)

// SetHidden persists to disk and a fresh Manager loads it back (so a hide survives a
// broker restart). Unhiding removes it.
func TestHiddenPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hidden.json")
	m1 := &Manager{hidden: map[string]bool{}, hiddenPath: path}
	m1.SetHidden("alpha", true)
	m1.SetHidden("beta", true)
	m1.SetHidden("beta", false) // unhide
	m2 := &Manager{hidden: map[string]bool{}, hiddenPath: path}
	m2.loadHidden()
	got := m2.HiddenNames()
	if len(got) != 1 || got[0] != "alpha" {
		t.Fatalf("after restart got %v, want [alpha]", got)
	}
}

// Sessions() stamps Info.Hidden from the set without mutating the cache.
func TestSessionsStampsHidden(t *testing.T) {
	m := &Manager{hidden: map[string]bool{"x": true}, sessCache: []session.Info{{Name: "x"}, {Name: "y"}}}
	out := m.Sessions()
	byName := map[string]bool{}
	for _, s := range out {
		byName[s.Name] = s.Hidden
	}
	if !byName["x"] || byName["y"] {
		t.Fatalf("expected x hidden, y visible; got %v", byName)
	}
	if m.sessCache[0].Hidden {
		t.Fatal("Sessions() must not mutate the cache")
	}
}
