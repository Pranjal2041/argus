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
	Socket  string
	Dir     string
	Root    string
	Host    string
	Cluster string
	Now     func() time.Time
	mu      sync.Mutex
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
	root := filepath.Join(home, ".universal-tmux", "recovery")
	return &Store{
		Socket:  socket,
		Dir:     filepath.Join(root, safeComponent(host), safeComponent(socket)),
		Root:    root,
		Host:    host,
		Cluster: recoveryCluster(host),
		Now:     time.Now,
	}
}

func recoveryCluster(host string) string {
	short := strings.ToLower(strings.TrimSpace(host))
	if index := strings.IndexByte(short, '.'); index >= 0 {
		short = short[:index]
	}
	if strings.HasPrefix(short, "ut-") {
		short = strings.TrimPrefix(short, "ut-")
	}
	if strings.HasPrefix(short, "babel-") {
		return "babel"
	}
	return ""
}

// CaptureEnabled keeps process inspection off generic Linux brokers while
// enabling it automatically on Babel, where snapshots are needed before a
// scheduler allocation disappears.
func CaptureEnabled(goos, host, override string) bool {
	return goos == "darwin" || override == "1" || recoveryCluster(host) == "babel"
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
	if err := s.saveLocked(*snapshot); err != nil {
		return err
	}
	return s.pruneClusterLocked(snapshot.CapturedAt)
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

func (s *Store) pruneClusterLocked(now time.Time) error {
	if s.Cluster == "" || s.Root == "" {
		return nil
	}
	cutoff := now.Add(-RetentionDays * 24 * time.Hour)
	hosts, err := os.ReadDir(s.Root)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	for _, host := range hosts {
		if !host.IsDir() || recoveryCluster(host.Name()) != s.Cluster {
			continue
		}
		directory := filepath.Join(s.Root, host.Name(), safeComponent(s.Socket))
		items, err := loadSnapshotsFromDir(directory)
		if err != nil {
			continue
		}
		for _, item := range items {
			if item.CapturedAt.Before(cutoff) {
				_ = os.Remove(filepath.Join(directory, "snapshot-"+safeComponent(item.ID)+".json"))
			}
		}
	}
	receipts := filepath.Join(s.Root, "_clusters", safeComponent(s.Cluster), safeComponent(s.Socket), "receipts")
	_ = filepath.WalkDir(receipts, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil || entry.IsDir() {
			return nil
		}
		if info, err := entry.Info(); err == nil && info.ModTime().Before(cutoff) {
			_ = os.Remove(path)
		}
		return nil
	})
	return nil
}

func (s *Store) loadAll() ([]Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadAllLocked()
}

func (s *Store) loadAllLocked() ([]Snapshot, error) {
	return loadSnapshotsFromDir(s.Dir)
}

func loadSnapshotsFromDir(directory string) ([]Snapshot, error) {
	entries, err := os.ReadDir(directory)
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
		body, err := os.ReadFile(filepath.Join(directory, entry.Name()))
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

func (s *Store) loadCluster() ([]Snapshot, error) {
	if s.Cluster == "" || s.Root == "" {
		return s.loadAll()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	hosts, err := os.ReadDir(s.Root)
	if errors.Is(err, os.ErrNotExist) {
		return []Snapshot{}, nil
	}
	if err != nil {
		return nil, err
	}
	var items []Snapshot
	for _, host := range hosts {
		if !host.IsDir() || recoveryCluster(host.Name()) != s.Cluster {
			continue
		}
		loaded, err := loadSnapshotsFromDir(filepath.Join(s.Root, host.Name(), safeComponent(s.Socket)))
		if err != nil {
			continue
		}
		for _, snapshot := range loaded {
			if snapshot.Socket == s.Socket && recoveryCluster(snapshot.Host) == s.Cluster {
				items = append(items, snapshot)
			}
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CapturedAt.After(items[j].CapturedAt) })
	return items, nil
}

func sameRecoveryHost(a, b string) bool {
	canonical := func(value string) string {
		value = strings.ToLower(strings.TrimSpace(value))
		if index := strings.IndexByte(value, '.'); index >= 0 {
			value = value[:index]
		}
		return strings.TrimPrefix(value, "ut-")
	}
	return canonical(a) == canonical(b)
}

type recoveryReceipt struct {
	SchemaVersion int       `json:"schemaVersion"`
	SourceID      string    `json:"sourceId"`
	Panel         string    `json:"panel"`
	TargetHost    string    `json:"targetHost"`
	TargetServer  string    `json:"targetServer,omitempty"`
	RestoredAt    time.Time `json:"restoredAt"`
}

func (s *Store) receiptPath(sourceID, panel string) string {
	sum := sha256.Sum256([]byte(panel))
	return filepath.Join(s.Root, "_clusters", safeComponent(s.Cluster), safeComponent(s.Socket),
		"receipts", safeComponent(sourceID), hex.EncodeToString(sum[:12])+".json")
}

func (s *Store) hasReceipt(sourceID, panel string) bool {
	if s.Cluster == "" || s.Root == "" {
		return false
	}
	body, err := os.ReadFile(s.receiptPath(sourceID, panel))
	if err != nil {
		return false
	}
	var receipt recoveryReceipt
	return json.Unmarshal(body, &receipt) == nil && receipt.SchemaVersion == SchemaVersion &&
		receipt.SourceID == sourceID && receipt.Panel == panel
}

func (s *Store) markRestored(source Snapshot, panel string, targetServer string) error {
	if s.Cluster == "" || sameRecoveryHost(source.Host, s.Host) {
		return nil
	}
	receipt := recoveryReceipt{
		SchemaVersion: SchemaVersion, SourceID: source.ID, Panel: panel,
		TargetHost: s.Host, TargetServer: targetServer, RestoredAt: s.Now().UTC(),
	}
	body, err := json.MarshalIndent(receipt, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(s.receiptPath(source.ID, panel), append(body, '\n'), 0o600)
}

func (s *Store) remainingEntries(snapshot Snapshot) []Entry {
	if s.Cluster == "" || sameRecoveryHost(snapshot.Host, s.Host) {
		return snapshot.Entries
	}
	entries := make([]Entry, 0, len(snapshot.Entries))
	for _, entry := range snapshot.Entries {
		if !s.hasReceipt(snapshot.ID, entry.Name) {
			entries = append(entries, entry)
		}
	}
	return entries
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
