package recovery

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

type Store struct {
	Socket string
	Dir    string
	Now    func() time.Time
	mu     sync.Mutex
}

func NewStore(socket string) *Store {
	if socket == "" {
		socket = "ut"
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	return &Store{
		Socket: socket,
		Dir:    filepath.Join(home, ".universal-tmux", "recovery", safeComponent(host), safeComponent(socket)),
		Now:    time.Now,
	}
}

func safeComponent(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "default"
	}
	var b strings.Builder
	for _, r := range value {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func snapshotID(serverID string) string {
	sum := sha256.Sum256([]byte(serverID))
	return hex.EncodeToString(sum[:12])
}

func (s *Store) snapshotPath(id string) string {
	return filepath.Join(s.Dir, "snapshot-"+safeComponent(id)+".json")
}

func writeAtomic(path string, body []byte, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".recovery-write-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err := f.Chmod(mode); err != nil {
		_ = f.Close()
		return err
	}
	if _, err := f.Write(body); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) saveLocked(snapshot Snapshot) error {
	body, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return err
	}
	if err := writeAtomic(s.snapshotPath(snapshot.ID), append(body, '\n'), 0o600); err != nil {
		return err
	}
	return s.pruneLocked(snapshot.CapturedAt)
}

// saveCaptured establishes recovery lineage exactly once per tmux server
// lifetime. A current server can satisfy its predecessor, but can never later
// become "incomplete" merely because the user intentionally closes a panel.
func (s *Store) saveCaptured(snapshot *Snapshot) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	items, err := s.loadAllLocked()
	if err != nil {
		return err
	}
	var existing *Snapshot
	for index := range items {
		if items[index].ServerID == snapshot.ServerID {
			existing = &items[index]
			break
		}
	}
	if existing != nil {
		snapshot.RecoverySourceID = existing.RecoverySourceID
		snapshot.RecoveryComplete = existing.RecoveryComplete
	} else {
		for index := range items {
			candidate := &items[index]
			if candidate.ServerID != snapshot.ServerID && len(candidate.Entries) > 0 {
				snapshot.RecoverySourceID = candidate.ID
				break
			}
		}
	}
	if snapshot.RecoverySourceID != "" && !snapshot.RecoveryComplete {
		sourceFound := false
		for index := range items {
			if items[index].ID != snapshot.RecoverySourceID {
				continue
			}
			sourceFound = true
			if entriesSatisfied(items[index].Entries, snapshot.Entries) {
				snapshot.RecoveryComplete = true
			}
			break
		}
		if !sourceFound {
			// Retention may remove a predecessor while this server is alive. Do
			// not let a dangling reference turn into a future arbitrary match.
			snapshot.RecoverySourceID = ""
			snapshot.RecoveryComplete = true
		}
	}
	return s.saveLocked(*snapshot)
}

func entriesMatch(expected, live Entry) bool {
	if expected.Agent == AgentShell {
		return live.Agent == AgentShell && filepath.Clean(live.Directory) == filepath.Clean(expected.Directory)
	}
	return expected.SessionID != "" && live.Agent == expected.Agent && live.SessionID == expected.SessionID
}

func entriesSatisfied(expected, live []Entry) bool {
	byName := make(map[string]Entry, len(live))
	for _, entry := range live {
		byName[entry.Name] = entry
	}
	for _, entry := range expected {
		current, ok := byName[entry.Name]
		if !ok || !entriesMatch(entry, current) {
			return false
		}
	}
	return len(expected) > 0
}

func (s *Store) pruneLocked(now time.Time) error {
	items, err := s.loadAllLocked()
	if err != nil {
		return err
	}
	cutoff := now.Add(-RetentionDays * 24 * time.Hour)
	for index, item := range items {
		if item.CapturedAt.Before(cutoff) || index >= 16 {
			_ = os.Remove(s.snapshotPath(item.ID))
		}
	}
	return nil
}

func (s *Store) loadAll() ([]Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadAllLocked()
}

func (s *Store) loadAllLocked() ([]Snapshot, error) {
	entries, err := os.ReadDir(s.Dir)
	if errors.Is(err, os.ErrNotExist) {
		return []Snapshot{}, nil
	}
	if err != nil {
		return nil, err
	}
	items := make([]Snapshot, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasPrefix(entry.Name(), "snapshot-") || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(s.Dir, entry.Name()))
		if err != nil {
			continue
		}
		var snapshot Snapshot
		if json.Unmarshal(body, &snapshot) != nil || snapshot.SchemaVersion != SchemaVersion || snapshot.ID == "" {
			continue
		}
		items = append(items, snapshot)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CapturedAt.After(items[j].CapturedAt) })
	return items, nil
}

func (s *Store) load(id string) (Snapshot, error) {
	items, err := s.loadAll()
	if err != nil {
		return Snapshot{}, err
	}
	for _, item := range items {
		if item.ID == id {
			return item, nil
		}
	}
	return Snapshot{}, fmt.Errorf("recovery snapshot %q not found", id)
}
