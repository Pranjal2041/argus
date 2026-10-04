//go:build !windows

package recovery

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestInspectCodexRolloutsSelectsRootAmongSubagents(t *testing.T) {
	dir := t.TempDir()
	rootID := "019f630d-5663-7722-bc65-5fd298a497ec"
	root := writeCodexRollout(t, dir, "root.jsonl", rootID, rootID)
	childA := writeCodexRollout(t, dir, "child-a.jsonl", "119f630d-5663-7722-bc65-5fd298a497ec", rootID)
	childB := writeCodexRollout(t, dir, "child-b.jsonl", "219f630d-5663-7722-bc65-5fd298a497ec", rootID)

	id, path, err := inspectCodexRollouts([]string{childA, root, childB})
	if err != nil {
		t.Fatal(err)
	}
	if id != rootID || path != root {
		t.Fatalf("selected (%q, %q), want root (%q, %q)", id, path, rootID, root)
	}
}

func TestInspectCodexRolloutsRejectsAmbiguousRoots(t *testing.T) {
	dir := t.TempDir()
	firstID := "019f630d-5663-7722-bc65-5fd298a497ec"
	secondID := "119f630d-5663-7722-bc65-5fd298a497ec"
	first := writeCodexRollout(t, dir, "first.jsonl", firstID, firstID)
	second := writeCodexRollout(t, dir, "second.jsonl", secondID, secondID)

	if _, _, err := inspectCodexRollouts([]string{first, second}); err == nil {
		t.Fatal("expected ambiguous root rollouts to be rejected")
	}
}

func TestClosedTranscriptUsesExactLaunchIdentityWithScreenRequirement(t *testing.T) {
	root := t.TempDir()
	sessions := filepath.Join(root, "sessions")
	if err := os.MkdirAll(sessions, 0700); err != nil {
		t.Fatal(err)
	}
	id := "019f630d-5663-7722-bc65-5fd298a497ec"
	otherID := "119f630d-5663-7722-bc65-5fd298a497ec"
	path := writeCodexRollout(t, sessions, "rollout-any-date-"+id+".jsonl", id, id)
	other := writeCodexRollout(t, sessions, "rollout-any-date-"+otherID+".jsonl", otherID, otherID)
	state := processState{Argv: []string{"codex", "resume", id}, Environment: map[string]string{"CODEX_HOME": root}}
	got, err := inspectCodexTranscript(nil, state)
	if err != nil || got.ID != id || got.Path != path || !got.RequireScreenMatch {
		t.Fatalf("closed transcript: %#v, %v", got, err)
	}
	// A live descriptor takes precedence over stale launch arguments.
	got, err = inspectCodexTranscript([]string{other}, state)
	if err != nil || got.ID != otherID || got.RequireScreenMatch {
		t.Fatalf("open transcript: %#v, %v", got, err)
	}
	if _, err := inspectCodexTranscript([]string{path, other}, state); err == nil {
		t.Fatal("ambiguous live roots fell back to launch arguments")
	}
	writeCodexRollout(t, sessions, "rollout-other-date-"+id+".jsonl", id, id)
	if _, err := inspectCodexTranscript(nil, state); err == nil {
		t.Fatal("duplicate exact transcripts were guessed")
	}
}

func TestClosedTranscriptRejectsUnprovenMetadataAndLaunchSelectors(t *testing.T) {
	for _, tc := range []struct {
		name, actualID, parentID string
		argv                     []string
	}{
		{"wrong metadata", "119f630d-5663-7722-bc65-5fd298a497ec", "", nil},
		{"child transcript", "019f630d-5663-7722-bc65-5fd298a497ec", "119f630d-5663-7722-bc65-5fd298a497ec", nil},
		{"no exact selector", "019f630d-5663-7722-bc65-5fd298a497ec", "", []string{"codex", "resume", "--last"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			sessions := filepath.Join(root, "sessions")
			if err := os.MkdirAll(sessions, 0700); err != nil {
				t.Fatal(err)
			}
			id := "019f630d-5663-7722-bc65-5fd298a497ec"
			writeCodexRollout(t, sessions, "rollout-date-"+id+".jsonl", tc.actualID, tc.parentID)
			argv := tc.argv
			if argv == nil {
				argv = []string{"codex", "resume", id}
			}
			if _, err := inspectCodexTranscript(nil, processState{Argv: argv, Environment: map[string]string{"CODEX_HOME": root}}); err == nil {
				t.Fatal("unproven transcript accepted")
			}
		})
	}
}

func writeCodexRollout(t *testing.T, dir, name, id, sessionID string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	line := fmt.Sprintf(`{"type":"session_meta","payload":{"id":%q,"session_id":%q}}`+"\n", id, sessionID)
	if err := os.WriteFile(path, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
