package recovery

import (
	"path/filepath"
	"testing"
)

func TestRecoveryStoreFollowsInstanceStateDir(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(t.TempDir(), "second-install")
	t.Setenv("UT_STATE_DIR", state)
	if got, want := NewStore("ljang").Root, filepath.Join(state, "recovery"); got != want {
		t.Fatalf("recovery root = %q, want %q", got, want)
	}
}
