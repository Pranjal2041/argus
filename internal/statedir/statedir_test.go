package statedir

import (
	"path/filepath"
	"testing"
)

func TestDirDefaultsToHomeAndHonorsOverride(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("UT_STATE_DIR", "")
	if got, want := Dir(), filepath.Join(home, ".universal-tmux"); got != want {
		t.Fatalf("default = %q, want %q", got, want)
	}
	override := filepath.Join(t.TempDir(), "second-install")
	t.Setenv("UT_STATE_DIR", override)
	if got := Dir(); got != override {
		t.Fatalf("override = %q, want %q", got, override)
	}
}
