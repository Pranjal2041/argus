package webartifact

import (
	"path/filepath"
	"testing"
)

func TestDefaultRootFollowsInstanceStateDir(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(t.TempDir(), "second-install")
	t.Setenv("UT_STATE_DIR", state)
	if got, want := DefaultRoot(), filepath.Join(state, "web-artifacts", "records"); got != want {
		t.Fatalf("root = %q, want %q", got, want)
	}
}
