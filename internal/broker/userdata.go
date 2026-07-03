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

// ---- journal inbox --------------------------------------------------------
// The phone can't write into the Mac app's journal files directly, so the SYNC
// HOST's broker (the Mac's) keeps a small append-only INBOX: the phone POSTs
// utterance events as JSONL, the Mac app periodically peeks, ingests them into
// its canonical day files (deduped by event id), and acks by byte offset.
// Unlike /userdata this is append-only — last-write-wins is the wrong primitive
// for a log.

var journalMu sync.Mutex

func journalInboxPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	dir := filepath.Join(home, ".universal-tmux")
	_ = os.MkdirAll(dir, 0o755)
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	return filepath.Join(dir, "journal-inbox-"+host+".jsonl")
}

// JournalAppend appends raw JSONL bytes to the inbox (a trailing newline is
// added if missing so concatenated posts never merge lines).
func JournalAppend(body []byte) error {
	if len(body) == 0 {
		return nil
	}
	journalMu.Lock()
	defer journalMu.Unlock()
	f, err := os.OpenFile(journalInboxPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(body); err != nil {
		return err
	}
	if body[len(body)-1] != '\n' {
		if _, err := f.Write([]byte{'\n'}); err != nil {
			return err
		}
	}
	return nil
}

// JournalPeek returns the inbox content and its size as the ack cursor.
func JournalPeek() (int64, []byte) {
	journalMu.Lock()
	defer journalMu.Unlock()
	b, err := os.ReadFile(journalInboxPath())
	if err != nil {
		return 0, nil
	}
	return int64(len(b)), b
}

// JournalAck drops the first off bytes (the consumer ingested them). Appends
// that raced in after the peek are preserved; if the file shrank below off
// (shouldn't happen — single consumer), it is cleared rather than corrupted.
func JournalAck(off int64) error {
	if off <= 0 {
		return nil
	}
	journalMu.Lock()
	defer journalMu.Unlock()
	p := journalInboxPath()
	b, err := os.ReadFile(p)
	if err != nil {
		return nil // nothing to ack
	}
	if off >= int64(len(b)) {
		return os.WriteFile(p, nil, 0o644)
	}
	return os.WriteFile(p, b[off:], 0o644)
}
