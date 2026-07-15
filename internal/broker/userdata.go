package broker

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// User-global data (Workflows, Todo Maps) is synced through ONE designated host (the
// user's Mac) so the macOS app and the phone share it without a central server. The
// broker stores one envelope per key and serves it; the clients keep a local copy and
// sync with last-write-wins. Destructive replacements must additionally declare intent,
// so a freshly-created or corrupt client cannot turn a populated store into an empty one.
var userDataMu sync.Mutex

func safeUserDataKey(key string) string {
	safe := make([]rune, 0, len(key))
	for _, r := range key {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			safe = append(safe, r)
		}
	}
	if len(safe) == 0 {
		safe = []rune("data")
	}
	return string(safe)
}

// User-global data belongs to the sync host, not to its current DHCP/mDNS hostname.
// The former hostname suffix split one Mac's data into multiple stores when its name
// changed. New stores use one stable path; readUserDataLocked migrates the old files.
func userDataPath(key string) string {
	return filepath.Join(brokerStateDir(), "userdata-"+safeUserDataKey(key)+".json")
}

func userDataUpdatedAt(b []byte) int64 {
	var m struct {
		UpdatedAt int64 `json:"updatedAt"`
	}
	_ = json.Unmarshal(b, &m)
	return m.UpdatedAt
}

type userDataEnvelope struct {
	UpdatedAt        int64           `json:"updatedAt"`
	Data             json.RawMessage `json:"data"`
	AllowDestructive bool            `json:"allowDestructive,omitempty"`
}

func decodeUserDataEnvelope(body []byte) (userDataEnvelope, bool) {
	var env userDataEnvelope
	if json.Unmarshal(body, &env) != nil || env.UpdatedAt <= 0 || len(env.Data) == 0 || !json.Valid(env.Data) {
		return userDataEnvelope{}, false
	}
	return env, true
}

func identifiedRecordCountJSON(v any) int {
	switch x := v.(type) {
	case []any:
		n := 0
		for _, item := range x {
			n += identifiedRecordCountJSON(item)
		}
		return n
	case map[string]any:
		n := 0
		if id, ok := x["id"].(string); ok && id != "" {
			n++
		}
		for _, item := range x {
			n += identifiedRecordCountJSON(item)
		}
		return n
	default:
		return 0
	}
}

func identifiedRecordCount(body []byte) int {
	env, ok := decodeUserDataEnvelope(body)
	if !ok {
		return 0
	}
	var data any
	if json.Unmarshal(env.Data, &data) != nil {
		return 0
	}
	return identifiedRecordCountJSON(data)
}

func destructiveReplacement(existing, incoming []byte) bool {
	before := identifiedRecordCount(existing)
	after := identifiedRecordCount(incoming)
	return before > 0 && after < before
}

func preservedAtNewerTimestamp(existing []byte, incomingTS int64) []byte {
	env, ok := decodeUserDataEnvelope(existing)
	if !ok {
		return existing
	}
	winnerTS := time.Now().UnixMilli()
	if winnerTS <= incomingTS {
		winnerTS = incomingTS + 1
	}
	if winnerTS <= env.UpdatedAt {
		winnerTS = env.UpdatedAt + 1
	}
	body, err := json.Marshal(userDataEnvelope{UpdatedAt: winnerTS, Data: env.Data})
	if err != nil {
		return existing
	}
	return body
}

func readUserDataLocked(key string) []byte {
	p := userDataPath(key)
	if body, err := os.ReadFile(p); err == nil {
		return body
	}

	// One-time migration from userdata-<key>-<hostname>.json. Pick the newest
	// valid envelope, breaking timestamp ties in favor of the more complete copy.
	legacy, _ := filepath.Glob(filepath.Join(brokerStateDir(), "userdata-"+safeUserDataKey(key)+"-*.json"))
	var winner []byte
	for _, candidate := range legacy {
		body, err := os.ReadFile(candidate)
		if err != nil {
			continue
		}
		if _, ok := decodeUserDataEnvelope(body); !ok {
			continue
		}
		if len(winner) == 0 || userDataUpdatedAt(body) > userDataUpdatedAt(winner) ||
			(userDataUpdatedAt(body) == userDataUpdatedAt(winner) && identifiedRecordCount(body) > identifiedRecordCount(winner)) {
			winner = body
		}
	}
	if len(winner) > 0 {
		_ = writeFileAtomic(p, winner, 0o600)
	}
	return winner
}

// UserData returns the stored blob for a key (nil if none stored yet).
func UserData(key string) []byte {
	userDataMu.Lock()
	defer userDataMu.Unlock()
	body := readUserDataLocked(key)
	if len(body) > 0 {
		_ = backupUserDataBlobAt(key, body, time.Now())
	}
	return body
}

// SetUserData stores body for a key unless what's already there is newer (by updatedAt).
// Returns the blob now in effect (the winner), so the caller can hand the client the
// authoritative copy in one round-trip.
func SetUserData(key string, body []byte) []byte {
	userDataMu.Lock()
	defer userDataMu.Unlock()
	p := userDataPath(key)
	existing := readUserDataLocked(key)
	incoming, valid := decodeUserDataEnvelope(body)
	if !valid {
		return existing
	}
	if len(existing) > 0 {
		_ = backupUserDataBlobAt(key, existing, time.Now())
		if userDataUpdatedAt(existing) > incoming.UpdatedAt {
			return existing
		}
		if destructiveReplacement(existing, body) && !incoming.AllowDestructive {
			log.Printf("blocked unmarked destructive userdata replacement key=%s records=%d->%d",
				safeUserDataKey(key), identifiedRecordCount(existing), identifiedRecordCount(body))
			winner := preservedAtNewerTimestamp(existing, incoming.UpdatedAt)
			if err := writeFileAtomic(p, winner, 0o600); err != nil {
				return existing
			}
			return winner
		}
	}
	if err := writeFileAtomic(p, body, 0o600); err != nil {
		return existing
	}
	if len(existing) == 0 {
		_ = backupUserDataBlobAt(key, body, time.Now())
	}
	return body
}

// UnattendedModeState is the broker-owned automation switch shared by every
// Argus client. The Mac broker is the sync host, so the mode keeps operating
// when the Lab pane (or the entire native app) is closed.
type UnattendedModeState struct {
	Enabled   bool  `json:"enabled"`
	UpdatedAt int64 `json:"updatedAt"`
}

const unattendedModeKey = "unattended-mode"

func decodeUnattendedMode(body []byte) UnattendedModeState {
	var envelope struct {
		UpdatedAt int64           `json:"updatedAt"`
		Data      json.RawMessage `json:"data"`
	}
	if json.Unmarshal(body, &envelope) != nil {
		return UnattendedModeState{}
	}
	state := UnattendedModeState{UpdatedAt: envelope.UpdatedAt}
	var data struct {
		Enabled bool `json:"enabled"`
	}
	if json.Unmarshal(envelope.Data, &data) == nil {
		state.Enabled = data.Enabled
		return state
	}
	// Accept the early scalar shape too, so a development build cannot strand
	// an enabled switch when upgrading to the named-data form.
	_ = json.Unmarshal(envelope.Data, &state.Enabled)
	return state
}

// UnattendedMode returns the durable switch; absent or malformed state is off.
func UnattendedMode() UnattendedModeState {
	return decodeUnattendedMode(UserData(unattendedModeKey))
}

// SetUnattendedMode updates the shared switch using the same last-write-wins
// envelope as the other cross-device user data.
func SetUnattendedMode(enabled bool) UnattendedModeState {
	updatedAt := time.Now().UnixMilli()
	body, _ := json.Marshal(struct {
		UpdatedAt int64 `json:"updatedAt"`
		Data      struct {
			Enabled bool `json:"enabled"`
		} `json:"data"`
	}{UpdatedAt: updatedAt, Data: struct {
		Enabled bool `json:"enabled"`
	}{Enabled: enabled}})
	return decodeUnattendedMode(SetUserData(unattendedModeKey, body))
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
