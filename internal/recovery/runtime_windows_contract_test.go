//go:build windows

package recovery

import (
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type fakeWindowsRuntime struct {
	mu       sync.Mutex
	identity RuntimeIdentity
	entries  []Entry
}

func (runtime *fakeWindowsRuntime) RecoveryIdentity() (RuntimeIdentity, error) {
	return runtime.identity, nil
}

func (runtime *fakeWindowsRuntime) RecoveryEntries() ([]Entry, error) {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	return append([]Entry(nil), runtime.entries...), nil
}

func (runtime *fakeWindowsRuntime) RestoreShell(name, directory string) error {
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	runtime.entries = append(runtime.entries, Entry{
		Name: name, Directory: directory, Agent: AgentShell, Windows: 1, Panes: 1,
	})
	return nil
}

func windowsRuntimeStore(root string, runtime WorkspaceRuntime, now time.Time) *Store {
	store := NewStoreWithRuntime("ut", runtime)
	store.Root = root
	store.Host = "windows-host"
	store.Cluster = ""
	store.Dir = filepath.Join(root, "windows-host", "ut")
	store.Now = func() time.Time { return now }
	return store
}

func TestConPTYWorkspaceCaptureAndRestoreFollowsSharedLineage(t *testing.T) {
	now := time.Date(2026, 9, 2, 20, 0, 0, 0, time.UTC)
	root := t.TempDir()
	directory := t.TempDir()
	sourceRuntime := &fakeWindowsRuntime{
		identity: RuntimeIdentity{BootID: "boot", ServerID: "conpty-old", ServerPID: 10, ServerStarted: 100},
		entries:  []Entry{{Name: "spatial", Directory: directory, Agent: AgentShell, Windows: 1, Panes: 1}},
	}
	source := windowsRuntimeStore(root, sourceRuntime, now.Add(-time.Minute))
	oldSnapshot, err := source.Capture()
	if err != nil {
		t.Fatal(err)
	}

	targetRuntime := &fakeWindowsRuntime{
		identity: RuntimeIdentity{BootID: "boot", ServerID: "conpty-new", ServerPID: 20, ServerStarted: 200},
	}
	target := windowsRuntimeStore(root, targetRuntime, now)
	emptySnapshot, err := target.Capture()
	if err != nil {
		t.Fatal(err)
	}
	if emptySnapshot.RecoverySourceID != oldSnapshot.ID || emptySnapshot.RecoveryComplete {
		t.Fatalf("new ConPTY lineage = %#v, want pending source %s", emptySnapshot, oldSnapshot.ID)
	}
	status := target.Status("")
	if !status.Available || status.Snapshot == nil || status.Snapshot.ID != oldSnapshot.ID || status.ReadyCount != 1 {
		t.Fatalf("Windows recovery status = %#v", status)
	}
	response := target.Restore(oldSnapshot.ID, []string{"spatial"}, 1)
	if len(response.Results) != 1 || response.Results[0].State != RestoreRestored {
		t.Fatalf("Windows restore response = %#v", response)
	}
	completed, err := target.Capture()
	if err != nil {
		t.Fatal(err)
	}
	if completed.RecoverySourceID != oldSnapshot.ID || !completed.RecoveryComplete {
		t.Fatalf("completed ConPTY lineage = %#v", completed)
	}
}

func TestWindowsCapturedLaunchFailsClosedWithoutProcessEvidence(t *testing.T) {
	store := NewStore("ut")
	response := store.RestoreCapturedLaunch("snapshot-1", []string{"panel"}, 1)
	if len(response.Results) != 1 || response.Results[0].State != RestoreFailed {
		t.Fatalf("captured launch response = %#v", response)
	}
}
