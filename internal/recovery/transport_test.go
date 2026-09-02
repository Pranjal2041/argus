package recovery

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("imported manifest mode = %o, want 600", info.Mode().Perm())
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
