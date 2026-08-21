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

func writeCodexRollout(t *testing.T, dir, name, id, sessionID string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	line := fmt.Sprintf(`{"type":"session_meta","payload":{"id":%q,"session_id":%q}}`+"\n", id, sessionID)
	if err := os.WriteFile(path, []byte(line), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}
