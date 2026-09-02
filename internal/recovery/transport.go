package recovery

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"time"
)

const maxSnapshotTransportBytes = 16 << 20

func (s *Store) importedDir() string {
	return filepath.Join(s.Dir, "imports")
}

func (s *Store) importedSnapshotPath(id string) string {
	return filepath.Join(s.importedDir(), "snapshot-"+safeComponent(id)+".json")
}

func (s *Store) loadImported() ([]Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return loadSnapshotsFromDir(s.importedDir())
}

func (s *Store) transportNow() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Store) validateTransportSnapshot(snapshot Snapshot) error {
	if snapshot.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported recovery snapshot schema %d", snapshot.SchemaVersion)
	}
	if snapshot.ID == "" || snapshot.ServerID == "" || snapshot.Host == "" {
		return errors.New("recovery snapshot identity is incomplete")
	}
	if snapshot.ID != snapshotID(snapshot.ServerID) {
		return errors.New("recovery snapshot ID does not match its server identity")
	}
	if snapshot.Socket != s.Socket {
		return fmt.Errorf("recovery snapshot belongs to tmux socket %q, not %q", snapshot.Socket, s.Socket)
	}
	if snapshot.CapturedAt.IsZero() {
		return errors.New("recovery snapshot has no capture time")
	}
	now := s.transportNow()
	if snapshot.CapturedAt.Before(now.Add(-RetentionDays * 24 * time.Hour)) {
		return fmt.Errorf("recovery snapshot is older than the %d-day retention window", RetentionDays)
	}
	// A little clock skew between machines is harmless; a manifest dated far in
	// the future would evade retention and should never enter the target store.
	if snapshot.CapturedAt.After(now.Add(24 * time.Hour)) {
		return errors.New("recovery snapshot capture time is implausibly far in the future")
	}
	if len(snapshot.Entries) > 1000 {
		return errors.New("recovery snapshot contains too many panels")
	}
	for _, entry := range snapshot.Entries {
		if entry.Name == "" || entry.Directory == "" {
			return errors.New("recovery snapshot contains a panel with incomplete identity")
		}
	}
	return nil
}

// ExportSnapshot returns one exact, validated manifest available through this
// broker. It can originate in the broker's local store, a shared cluster store,
// or a prior explicit import; callers never need to know that storage topology.
func (s *Store) ExportSnapshot(id string) ([]byte, error) {
	if id == "" {
		return nil, errors.New("recovery snapshot ID is required")
	}
	local, err := s.loadAll()
	if err != nil {
		return nil, err
	}
	shared, err := s.loadCluster()
	if err != nil {
		return nil, err
	}
	imported, err := s.loadImported()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, group := range [][]Snapshot{local, shared, imported} {
		for _, snapshot := range group {
			if seen[snapshot.ID] {
				continue
			}
			seen[snapshot.ID] = true
			if snapshot.ID != id {
				continue
			}
			if err := s.validateTransportSnapshot(snapshot); err != nil {
				return nil, err
			}
			body, err := json.Marshal(snapshot)
			if err != nil {
				return nil, err
			}
			return append(body, '\n'), nil
		}
	}
	return nil, fmt.Errorf("recovery snapshot %q not found", id)
}

// ImportSnapshot stages a foreign manifest for explicit inspection/restoration.
// Imports live outside the automatic capture lineage: merely looking at a
// remote source can therefore never make it the implicit predecessor of this
// machine's current tmux server.
func (s *Store) ImportSnapshot(body []byte) (Snapshot, error) {
	if len(body) == 0 || len(body) > maxSnapshotTransportBytes {
		return Snapshot{}, fmt.Errorf("recovery snapshot must be between 1 byte and %d bytes", maxSnapshotTransportBytes)
	}
	var snapshot Snapshot
	if err := json.Unmarshal(body, &snapshot); err != nil {
		return Snapshot{}, fmt.Errorf("decode recovery snapshot: %w", err)
	}
	if err := s.validateTransportSnapshot(snapshot); err != nil {
		return Snapshot{}, err
	}
	normalized, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return Snapshot{}, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := writeAtomic(s.importedSnapshotPath(snapshot.ID), append(normalized, '\n'), 0o600); err != nil {
		return Snapshot{}, err
	}
	items, err := loadSnapshotsFromDir(s.importedDir())
	if err != nil {
		return Snapshot{}, err
	}
	cutoff := s.transportNow().Add(-RetentionDays * 24 * time.Hour)
	for index, item := range items {
		if item.CapturedAt.Before(cutoff) || index >= 16 {
			_ = os.Remove(s.importedSnapshotPath(item.ID))
		}
	}
	return snapshot, nil
}

func transportSnapshot(items []Snapshot, id string) *Snapshot {
	for index := range items {
		if items[index].ID == id {
			return &items[index]
		}
	}
	return nil
}

func mergeSnapshots(groups ...[]Snapshot) []Snapshot {
	byID := map[string]Snapshot{}
	for _, group := range groups {
		for _, snapshot := range group {
			if current, ok := byID[snapshot.ID]; !ok || snapshot.CapturedAt.After(current.CapturedAt) {
				byID[snapshot.ID] = snapshot
			}
		}
	}
	items := make([]Snapshot, 0, len(byID))
	for _, snapshot := range byID {
		items = append(items, snapshot)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CapturedAt.After(items[j].CapturedAt) })
	return items
}

type restoreRequest struct {
	SnapshotID        string   `json:"snapshotId"`
	Sessions          []string `json:"sessions"`
	Concurrency       int      `json:"concurrency"`
	UseCapturedLaunch bool     `json:"useCapturedLaunch"`
}

// RegisterSnapshotRoutes exposes the recovery boundary on the running broker.
// Status and restore execute beside the backend that owns the sessions, while
// snapshot transfer remains portable across every transport and operating
// system.
func RegisterSnapshotRoutes(mux *http.ServeMux, store *Store) {
	mux.HandleFunc("/recovery/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", "GET")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if socket := r.URL.Query().Get("socket"); socket != "" && socket != store.Socket {
			http.Error(w, fmt.Sprintf("broker serves session socket %q, not %q", store.Socket, socket), http.StatusConflict)
			return
		}
		// Make source discovery reflect the live workspace now rather than waiting
		// for the periodic capture tick. A failed refresh never erases the last
		// valid durable snapshot.
		_, _ = store.Capture()
		_ = json.NewEncoder(w).Encode(store.Status(r.URL.Query().Get("snapshot")))
	})

	mux.HandleFunc("/recovery/restore", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if socket := r.URL.Query().Get("socket"); socket != "" && socket != store.Socket {
			http.Error(w, fmt.Sprintf("broker serves session socket %q, not %q", store.Socket, socket), http.StatusConflict)
			return
		}
		var request restoreRequest
		if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, "invalid restore request: "+err.Error(), http.StatusBadRequest)
			return
		}
		var response RestoreResponse
		if request.UseCapturedLaunch {
			response = store.RestoreCapturedLaunch(request.SnapshotID, request.Sessions, request.Concurrency)
		} else {
			response = store.Restore(request.SnapshotID, request.Sessions, request.Concurrency)
		}
		_ = json.NewEncoder(w).Encode(response)
	})

	mux.HandleFunc("/recovery/snapshot", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if socket := r.URL.Query().Get("socket"); socket != "" && socket != store.Socket {
			http.Error(w, fmt.Sprintf("broker serves tmux socket %q, not %q", store.Socket, socket), http.StatusConflict)
			return
		}
		switch r.Method {
		case http.MethodGet:
			body, err := store.ExportSnapshot(r.URL.Query().Get("id"))
			if err != nil {
				http.Error(w, err.Error(), http.StatusNotFound)
				return
			}
			_, _ = w.Write(body)
		case http.MethodPost:
			body, err := io.ReadAll(io.LimitReader(r.Body, maxSnapshotTransportBytes+1))
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			snapshot, err := store.ImportSnapshot(body)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "snapshotId": snapshot.ID})
		default:
			w.Header().Set("Allow", "GET, POST")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
}
