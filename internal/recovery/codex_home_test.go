//go:build !windows

package recovery

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestCodexRolloutsFollowProcessCodexHome(t *testing.T) {
	home := t.TempDir()
	customHome := filepath.Join(home, ".codex2")
	wanted := filepath.Join(customHome, "sessions", "2026", "08", "20", "rollout-wanted.jsonl")
	defaultHomeRollout := filepath.Join(home, ".codex", "sessions", "2026", "08", "20", "rollout-default.jsonl")
	unrelated := filepath.Join(home, "elsewhere", "rollout-unrelated.jsonl")
	for _, path := range []string{wanted, defaultHomeRollout, unrelated} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	state := processState{Environment: map[string]string{
		"HOME": home, "CODEX_HOME": customHome,
	}}
	got := codexRollouts([]string{defaultHomeRollout, unrelated, wanted}, state)
	if !reflect.DeepEqual(got, []string{wanted}) {
		t.Fatalf("custom CODEX_HOME rollouts = %#v, want only %#v", got, wanted)
	}
}
