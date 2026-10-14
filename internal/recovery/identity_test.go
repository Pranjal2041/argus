package recovery

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func isolateIdentityStore(t *testing.T) {
	t.Helper()
	t.Setenv("UT_STATE_DIR", t.TempDir())
	t.Setenv("UT_LOCAL_DIR", t.TempDir())
	t.Setenv("UT_MACHINE_ID", "")
	t.Setenv("UT_PORT", "8722")
	t.Setenv("UT_LOCAL_PORT", "8722")
}

func capturedIdentityFixture(t *testing.T, store *Store, server string, entries []Entry) Snapshot {
	t.Helper()
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID(server), ServerID: server,
		Host: store.Host, Socket: store.Socket, CapturedAt: time.Now().UTC(), Entries: entries,
	}
	if err := store.saveCaptured(&snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func TestRecoveryRenameAndBackendReplacementKeepInstallationLineage(t *testing.T) {
	for _, implementation := range []string{"native", "isolated-runtime"} {
		t.Run(implementation, func(t *testing.T) {
			isolateIdentityStore(t)
			newStore := func() *Store { return NewStoreWithRuntime("ut", nil, "runtime-one") }
			if implementation == "native" {
				t.Setenv("UT_MACHINE_ID", "native-os-identity")
				newStore = func() *Store { return NewStore("ut") }
			}
			source := newStore()
			source.Host = "before-network-change.example"
			entry := Entry{Name: "work", Agent: AgentShell, Directory: t.TempDir(), Windows: 1, Panes: 1}
			prior := capturedIdentityFixture(t, source, "previous-backend", []Entry{entry})
			target := newStore()
			target.Host = "renamed-host.other-domain"
			if source.Dir != target.Dir || prior.InstallationID == "" {
				t.Fatal("display name selected storage")
			}
			empty := capturedIdentityFixture(t, target, "replacement-backend", nil)
			if empty.RecoverySourceID != prior.ID || empty.RecoveryComplete {
				t.Fatalf("lost lineage: %#v", empty)
			}
			status := target.statusWithCurrent("", map[string]Entry{}, empty.ServerID)
			if !status.Available || status.Snapshot == nil || status.Snapshot.ID != prior.ID || status.ReadyCount != 1 {
				t.Fatalf("rename hid recovery: %#v", status)
			}
			completed := capturedIdentityFixture(t, target, empty.ServerID, []Entry{entry})
			if !completed.RecoveryComplete {
				t.Fatal("restored lineage did not complete")
			}
			capturedIdentityFixture(t, target, empty.ServerID, nil)
			if afterClose := target.statusWithCurrent("", map[string]Entry{}, empty.ServerID); afterClose.Snapshot != nil {
				t.Fatal("intentional close reoffered after a hostname change")
			}
		})
	}
}

func TestDistinctRuntimeInstallationsSharingHomeAndHostnameStaySeparate(t *testing.T) {
	isolateIdentityStore(t)
	first := NewStoreWithRuntime("ut", nil, "runtime-one")
	second := NewStoreWithRuntime("ut", nil, "runtime-two")
	first.Host, second.Host = "same-host", "same-host"
	if first.Dir == second.Dir {
		t.Fatal("independent runtime stores overlap")
	}
	prior := capturedIdentityFixture(t, first, "first-backend", []Entry{{Name: "work", Agent: AgentShell, Directory: t.TempDir()}})
	empty := capturedIdentityFixture(t, second, "second-backend", nil)
	if empty.RecoverySourceID != "" {
		t.Fatal("foreign installation became automatic lineage")
	}
	status := second.statusWithCurrent("", map[string]Entry{}, empty.ServerID)
	if status.Snapshot != nil || status.Available || len(status.Candidates) != 1 || !status.SourceSelectionRequired {
		t.Fatalf("foreign source was lost or silently claimed: %#v", status)
	}
	explicit := second.statusWithCurrent(prior.ID, map[string]Entry{}, empty.ServerID)
	if !explicit.Available || explicit.Snapshot.ID != prior.ID {
		t.Fatal("explicit cross-installation recovery unavailable")
	}
}

func TestOfflineCLIUsesRuntimeBindingScopedToInstanceAndSocket(t *testing.T) {
	isolateIdentityStore(t)
	runtime := NewStoreWithRuntime("ut", nil, "runtime-one")
	if err := runtime.BindLocalIdentity(); err != nil {
		t.Fatal(err)
	}
	if cli := NewStore("ut"); cli.Dir != runtime.Dir {
		t.Fatalf("offline CLI selected %q, runtime uses %q", cli.Dir, runtime.Dir)
	}
	if other := NewStore("second"); other.InstallationID == runtime.InstallationID {
		t.Fatal("binding leaked across sockets")
	}
	t.Setenv("UT_LOCAL_PORT", "8732")
	if other := NewStore("ut"); other.InstallationID == runtime.InstallationID {
		t.Fatal("binding leaked across local endpoints")
	}
	otherRuntime := NewStoreWithRuntime("ut", nil, "runtime-two")
	if err := otherRuntime.BindLocalIdentity("8732"); err != nil {
		t.Fatal(err)
	}
	if cli := NewStore("ut"); cli.Dir != otherRuntime.Dir {
		t.Fatal("second endpoint did not resolve its own runtime")
	}
	t.Setenv("UT_LOCAL_PORT", "8722")
	if cli := NewStore("ut"); cli.Dir != runtime.Dir {
		t.Fatal("second runtime overwrote first endpoint binding")
	}
	t.Setenv("UT_MACHINE_ID", "operator-selected-installation")
	if other := NewStore("ut"); other.InstallationID == runtime.InstallationID {
		t.Fatal("binding overrode explicit identity")
	}
	t.Setenv("UT_MACHINE_ID", "")
	t.Setenv("UT_STATE_DIR", t.TempDir())
	if other := NewStore("ut"); other.InstallationID == runtime.InstallationID {
		t.Fatal("binding leaked across state roots")
	}
}

func TestLegacyCatalogDoesNotModifyManifestsOrCrossSockets(t *testing.T) {
	isolateIdentityStore(t)
	target := NewStoreWithRuntime("ut", nil, "new-installation")
	legacy := independentTransportStore(target.Root, "previous-display-name", "ut", time.Now())
	prior := Snapshot{SchemaVersion: SchemaVersion, ID: snapshotID("old"), ServerID: "old", Host: legacy.Host,
		Socket: "ut", CapturedAt: time.Now().UTC(), Entries: []Entry{{Name: "work", Agent: AgentShell, Directory: t.TempDir()}}}
	if err := legacy.saveLocked(prior); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(legacy.snapshotPath(prior.ID))
	if err != nil {
		t.Fatal(err)
	}
	status := target.statusWithCurrent("", map[string]Entry{}, "")
	if status.Snapshot != nil || !status.SourceSelectionRequired || len(status.Candidates) != 1 {
		t.Fatalf("legacy manifest was lost or auto-adopted: %#v", status)
	}
	if explicit := target.statusWithCurrent(prior.ID, map[string]Entry{}, ""); !explicit.Available {
		t.Fatalf("explicit legacy restore: %#v", explicit)
	}
	if _, err := target.ExportSnapshot(prior.ID); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(legacy.snapshotPath(prior.ID))
	if !bytes.Equal(before, after) {
		t.Fatal("catalog rewrote legacy source")
	}
	if empty := capturedIdentityFixture(t, target, "new", nil); empty.RecoverySourceID != "" {
		t.Fatal("legacy source became automatic lineage")
	}
	other := NewStoreWithRuntime("other-socket", nil, "new-installation")
	if status := other.statusWithCurrent("", map[string]Entry{}, ""); len(status.Candidates) != 0 {
		t.Fatal("catalog crossed session sockets")
	}
	if _, err := os.Stat(filepath.Join(target.Dir, "snapshot-"+prior.ID+".json")); !os.IsNotExist(err) {
		t.Fatal("legacy snapshot copied into owned lineage")
	}
}
