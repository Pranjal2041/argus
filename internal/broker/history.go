package broker

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"

	"universal-tmux/internal/session"
)

// FolderSpan is one stretch of time a session's active folder (cwd) stayed at Path.
// A session accrues several when the user cd's around, newest last.
type FolderSpan struct {
	Path  string `json:"path"`
	First int64  `json:"first"` // unix seconds the folder was first seen
	Last  int64  `json:"last"`  // unix seconds it was last seen
}

// SessionHistory is the durable record of a session that has existed on this node:
// its name, the node it ran on, and every folder it was in (with timestamps). It
// outlives the session so the user can recover "where was X running" after it's gone.
type SessionHistory struct {
	Name    string       `json:"name"`
	Node    string       `json:"node"`
	Agent   bool         `json:"agent"` // was a mesh (ut spawn) session
	Folders []FolderSpan `json:"folders"`
	First   int64        `json:"first"` // first ever seen (unix sec)
	Last    int64        `json:"last"`  // last seen (≈ when it ended, if not alive)
	Alive   bool         `json:"alive"` // currently present (set at read time, not stored)
}

const (
	histMaxFoldersPerSession = 50
	histMaxRecords           = 2000
	histTTLDays              = 90
)

// historyStatePath is a per-HOST file (like hiddenStatePath) so brokers on different
// nodes keep their own session history without clobbering each other over NFS.
func historyStatePath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	dir := filepath.Join(home, ".universal-tmux")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "history-"+host+".json")
}

func histNodeName() string {
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	return host
}

func (m *Manager) loadHistory() {
	b, err := os.ReadFile(m.histPath)
	if err != nil {
		return
	}
	var recs []*SessionHistory
	if json.Unmarshal(b, &recs) != nil {
		return
	}
	cutoff := time.Now().Unix() - int64(histTTLDays)*24*3600
	m.histMu.Lock()
	for _, r := range recs {
		if r == nil || r.Name == "" || r.Last < cutoff {
			continue // drop stale entries
		}
		r.Alive = false
		m.history[r.Name] = r
	}
	m.histMu.Unlock()
}

// saveHistoryLocked writes the history to disk. Caller holds histMu.
func (m *Manager) saveHistoryLocked() {
	if m.histPath == "" {
		return
	}
	recs := make([]*SessionHistory, 0, len(m.history))
	for _, r := range m.history {
		recs = append(recs, r)
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].Last > recs[j].Last })
	if len(recs) > histMaxRecords { // keep the most-recent records
		for _, r := range recs[histMaxRecords:] {
			delete(m.history, r.Name)
		}
		recs = recs[:histMaxRecords]
	}
	if b, err := json.Marshal(recs); err == nil {
		_ = os.WriteFile(m.histPath, b, 0o644)
	}
	m.histDirty = false
}

// recordHistory folds the current session list into the durable history: a new
// session starts a record, a changed cwd appends a folder span, and lastSeen ticks
// forward. A STRUCTURAL change (new session or new folder) persists immediately so a
// short-lived session isn't lost on a crash; plain lastSeen updates are flushed on a
// timer by the refresh loop.
func (m *Manager) recordHistory(list []session.Info) {
	now := time.Now().Unix()
	structural := false
	m.histMu.Lock()
	for _, s := range list {
		if s.Name == "" {
			continue
		}
		rec := m.history[s.Name]
		if rec == nil {
			rec = &SessionHistory{Name: s.Name, Node: m.histNode, First: now}
			m.history[s.Name] = rec
			structural = true
		}
		rec.Last = now
		rec.Agent = s.Agent
		if p := s.Path; p != "" {
			n := len(rec.Folders)
			if n == 0 || rec.Folders[n-1].Path != p {
				rec.Folders = append(rec.Folders, FolderSpan{Path: p, First: now, Last: now})
				if len(rec.Folders) > histMaxFoldersPerSession {
					rec.Folders = rec.Folders[len(rec.Folders)-histMaxFoldersPerSession:]
				}
				structural = true
			} else {
				rec.Folders[n-1].Last = now
			}
		}
	}
	m.histDirty = true
	if structural {
		m.saveHistoryLocked()
	}
	m.histMu.Unlock()
}

// flushHistory persists pending lastSeen updates (called periodically off the loop).
func (m *Manager) flushHistory() {
	m.histMu.Lock()
	if m.histDirty {
		m.saveHistoryLocked()
	}
	m.histMu.Unlock()
}

// History returns every recorded session this node knows about, newest activity first.
// It is the union of this node's own in-memory records AND any sibling node history
// files sharing the same state dir — e.g. every SLURM node of a cluster on one NFS home.
// That lets an online node surface the history of nodes that are currently offline, so a
// session's record doesn't disappear just because the node it ran on went away. On a
// machine that shares its home with no one (a Mac, a Windows box) there is only the one
// file, so this is just its own history. Alive is set from THIS node's live sessions only.
func (m *Manager) History() []SessionHistory {
	live := map[string]bool{}
	m.sessMu.Lock()
	for _, s := range m.sessCache {
		live[s.Name] = true
	}
	m.sessMu.Unlock()

	cutoff := time.Now().Unix() - int64(histTTLDays)*24*3600
	type histKey struct {
		node, name string
		first      int64
	}
	seen := map[histKey]bool{}

	m.histMu.Lock()
	out := make([]SessionHistory, 0, len(m.history))
	for _, r := range m.history {
		rec := *r
		rec.Alive = live[r.Name]
		out = append(out, rec)
		seen[histKey{rec.Node, rec.Name, rec.First}] = true
	}
	m.histMu.Unlock()

	// Fold in sibling node files (other nodes sharing this NFS home). Read-only, so a
	// half-written sibling just fails to parse and is skipped until the next read.
	if m.histPath != "" {
		dir := filepath.Dir(m.histPath)
		if files, err := filepath.Glob(filepath.Join(dir, "history-*.json")); err == nil {
			for _, f := range files {
				if f == m.histPath {
					continue // own node — already covered by the fresher in-memory copy
				}
				b, err := os.ReadFile(f)
				if err != nil {
					continue
				}
				var recs []*SessionHistory
				if json.Unmarshal(b, &recs) != nil {
					continue
				}
				for _, r := range recs {
					if r == nil || r.Name == "" || r.Last < cutoff {
						continue
					}
					k := histKey{r.Node, r.Name, r.First}
					if seen[k] {
						continue
					}
					seen[k] = true
					rec := *r
					rec.Alive = false // another node's session — not live on this one
					out = append(out, rec)
				}
			}
		}
	}

	sort.Slice(out, func(i, j int) bool { return out[i].Last > out[j].Last })
	return out
}
