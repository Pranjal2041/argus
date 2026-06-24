package broker

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// User-global data (Workflows, Todo Maps) is synced through ONE designated host (the
// user's Mac) so the macOS app and the phone share it without a central server. The
// broker just stores an opaque blob per key and serves it; the clients keep a local copy
// and sync with last-write-wins. The blob carries its own `updatedAt` (unix millis);
// SetUserData keeps the newer of incoming vs stored so a stale client can't clobber a
// newer save.
var userDataMu sync.Mutex

func userDataPath(key string) string {
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
	safe := make([]rune, 0, len(key))
	for _, r := range key {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			safe = append(safe, r)
		}
	}
	if len(safe) == 0 {
		safe = []rune("data")
	}
	return filepath.Join(dir, "userdata-"+string(safe)+"-"+host+".json")
}

func userDataUpdatedAt(b []byte) int64 {
	var m struct {
		UpdatedAt int64 `json:"updatedAt"`
	}
	_ = json.Unmarshal(b, &m)
	return m.UpdatedAt
}

// UserData returns the stored blob for a key (nil if none stored yet).
func UserData(key string) []byte {
	userDataMu.Lock()
	defer userDataMu.Unlock()
	b, err := os.ReadFile(userDataPath(key))
	if err != nil {
		return nil
	}
	return b
}

// SetUserData stores body for a key unless what's already there is newer (by updatedAt).
// Returns the blob now in effect (the winner), so the caller can hand the client the
// authoritative copy in one round-trip.
func SetUserData(key string, body []byte) []byte {
	userDataMu.Lock()
	defer userDataMu.Unlock()
	p := userDataPath(key)
	if existing, err := os.ReadFile(p); err == nil {
		if userDataUpdatedAt(existing) > userDataUpdatedAt(body) {
			return existing
		}
	}
	_ = os.WriteFile(p, body, 0o644)
	return body
}
