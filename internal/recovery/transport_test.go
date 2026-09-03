package recovery

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func independentTransportStore(root, host, socket string, now time.Time) *Store {
	return &Store{
		Socket: socket,
		Dir:    filepath.Join(root, safeComponent(host), safeComponent(socket)),
		Root:   root,
		Host:   host,
		Now:    func() time.Time { return now },
	}
}

func TestSnapshotTransportAcrossIndependentStoresIsExplicit(t *testing.T) {
	now := time.Date(2026, 9, 2, 18, 0, 0, 0, time.UTC)
	socket := "transport-test-without-live-tmux"
	directory := t.TempDir()
	source := independentTransportStore(t.TempDir(), "source-a", socket, now)
	target := independentTransportStore(t.TempDir(), "destination-b", socket, now)
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion,
		ServerID:      "source-server-lifetime",
		Host:          source.Host,
		Socket:        socket,
		CapturedAt:    now.Add(-time.Minute),
		Entries: []Entry{{
			Name: "research", Directory: directory, Agent: AgentShell, Windows: 1, Panes: 1,
		}},
	}
	snapshot.ID = snapshotID(snapshot.ServerID)
	if err := source.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}

	body, err := source.ExportSnapshot(snapshot.ID)
	if err != nil {
		t.Fatal(err)
	}
	imported, err := target.ImportSnapshot(body)
	if err != nil {
		t.Fatal(err)
	}
	if imported.ID != snapshot.ID || imported.Host != source.Host {
		t.Fatalf("imported snapshot = %#v", imported)
	}
	if status := target.Status(""); status.Snapshot != nil || status.Available {
		t.Fatalf("an explicit import became an implicit recovery offer: %#v", status)
	}
	status := target.Status(snapshot.ID)
	if status.Error != "" || status.Snapshot == nil || status.Snapshot.ID != snapshot.ID ||
		len(status.Panels) != 1 || status.Panels[0].State != PanelReady {
		t.Fatalf("transported recovery status = %#v", status)
	}
	info, err := os.Stat(target.importedSnapshotPath(snapshot.ID))
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("imported manifest mode = %o, want 600", info.Mode().Perm())
	}
}

func TestStatusAdvertisesCurrentLiveWorkspaceAsFabricSource(t *testing.T) {
	now := time.Date(2026, 9, 2, 18, 0, 0, 0, time.UTC)
	directory := t.TempDir()
	store := independentTransportStore(t.TempDir(), "independent-host", "ut", now)
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID("live-server"), Host: store.Host, Socket: store.Socket,
		ServerID: "live-server", CapturedAt: now,
		Entries: []Entry{{Name: "dashboard", Directory: directory, Agent: AgentShell, Windows: 1, Panes: 1}},
	}
	if err := store.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	current := map[string]Entry{"dashboard": snapshot.Entries[0]}
	status := store.statusWithCurrent("", current, snapshot.ServerID)
	if status.Snapshot != nil || status.Available {
		t.Fatalf("live source was incorrectly offered for local restoration: %#v", status)
	}
	if len(status.Candidates) != 1 || status.Candidates[0].ID != snapshot.ID || status.Candidates[0].Host != snapshot.Host {
		t.Fatalf("live workspace was absent from fabric sources: %#v", status.Candidates)
	}
}

func TestStatusDoesNotAdvertiseStaleCurrentSnapshotAfterIntentionalClose(t *testing.T) {
	now := time.Date(2026, 9, 2, 18, 0, 0, 0, time.UTC)
	store := independentTransportStore(t.TempDir(), "independent-host", "ut", now)
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID("live-server"), Host: store.Host, Socket: store.Socket,
		ServerID: "live-server", CapturedAt: now,
		Entries: []Entry{{Name: "closed", Directory: t.TempDir(), Agent: AgentShell}},
	}
	if err := store.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	status := store.statusWithCurrent("", map[string]Entry{}, snapshot.ServerID)
	if len(status.Candidates) != 0 {
		t.Fatalf("stale live snapshot remained a fabric source: %#v", status.Candidates)
	}
}

func TestMissingDirectorySuggestsOnlyAvailableFolderFromExplicitLineage(t *testing.T) {
	now := time.Date(2026, 9, 3, 18, 0, 0, 0, time.UTC)
	store := independentTransportStore(t.TempDir(), "destination", "ut", now)
	available := t.TempDir()
	ancestor := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID("ancestor"), Host: "source", Socket: "ut",
		ServerID: "ancestor", CapturedAt: now.Add(-time.Hour),
		Entries: []Entry{{Name: "research", Directory: available, Agent: AgentShell}},
	}
	broken := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID("broken"), Host: "source", Socket: "ut",
		ServerID: "broken", CapturedAt: now, RecoverySourceID: ancestor.ID,
		Entries: []Entry{{Name: "research", Directory: "/missing/virtualized/path", Agent: AgentShell}},
	}
	if err := store.saveLocked(ancestor); err != nil {
		t.Fatal(err)
	}
	if err := store.saveLocked(broken); err != nil {
		t.Fatal(err)
	}
	status := store.statusWithCurrent(broken.ID, map[string]Entry{}, "current")
	if len(status.Panels) != 1 || status.Panels[0].State != PanelMissingDirectory ||
		status.Panels[0].SuggestedDirectory != available {
		t.Fatalf("lineage suggestion = %#v", status.Panels)
	}
	if status.Panels[0].Directory != broken.Entries[0].Directory {
		t.Fatalf("captured directory was silently rewritten: %#v", status.Panels[0])
	}
}

func TestSnapshotTransportRejectsInvalidIdentitySocketAndAge(t *testing.T) {
	now := time.Date(2026, 9, 2, 18, 0, 0, 0, time.UTC)
	store := independentTransportStore(t.TempDir(), "destination", "ut", now)
	valid := Snapshot{
		SchemaVersion: SchemaVersion, ServerID: "server", Host: "source", Socket: "ut",
		CapturedAt: now, Entries: []Entry{{Name: "panel", Directory: "/tmp", Agent: AgentShell}},
	}
	valid.ID = snapshotID(valid.ServerID)
	tests := []struct {
		name   string
		mutate func(*Snapshot)
		want   string
	}{
		{"identity", func(snapshot *Snapshot) { snapshot.ID = "tampered" }, "server identity"},
		{"socket", func(snapshot *Snapshot) { snapshot.Socket = "other" }, "tmux socket"},
		{"age", func(snapshot *Snapshot) { snapshot.CapturedAt = now.Add(-8 * 24 * time.Hour) }, "retention"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			snapshot := valid
			test.mutate(&snapshot)
			body, _ := json.Marshal(snapshot)
			if _, err := store.ImportSnapshot(body); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("ImportSnapshot error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestSnapshotTransportHTTPRouteRoundTrip(t *testing.T) {
	now := time.Date(2026, 9, 2, 18, 0, 0, 0, time.UTC)
	store := independentTransportStore(t.TempDir(), "source", "ut", now)
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ServerID: "http-server", Host: store.Host, Socket: store.Socket,
		CapturedAt: now, Entries: []Entry{{Name: "panel", Directory: "/tmp", Agent: AgentShell}},
	}
	snapshot.ID = snapshotID(snapshot.ServerID)
	if err := store.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	RegisterSnapshotRoutes(mux, store)
	statusRequest := httptest.NewRequest(http.MethodGet, "/recovery/status?socket=ut&snapshot="+snapshot.ID, nil)
	statusResponse := httptest.NewRecorder()
	mux.ServeHTTP(statusResponse, statusRequest)
	if statusResponse.Code != http.StatusOK || !strings.Contains(statusResponse.Body.String(), snapshot.ID) {
		t.Fatalf("status response = %d %s", statusResponse.Code, statusResponse.Body.String())
	}

	request := httptest.NewRequest(http.MethodGet, "/recovery/snapshot?id="+snapshot.ID+"&socket=ut", nil)
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), snapshot.ID) {
		t.Fatalf("GET response = %d %s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodPost, "/recovery/snapshot?socket=other", strings.NewReader(response.Body.String()))
	conflict := httptest.NewRecorder()
	mux.ServeHTTP(conflict, request)
	if conflict.Code != http.StatusConflict {
		t.Fatalf("socket mismatch response = %d, want %d", conflict.Code, http.StatusConflict)
	}
}
