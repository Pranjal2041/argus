// Package labsvc implements the Argus Lab store (LAB-DESIGN.md): append-only
// event logs, human-approved access keys, and run provenance for experiments
// carried out by coding agents. The store is plain files under ~/.argus/lab.
// Every event is its own file, written to a temp name and renamed into place,
// because several cluster nodes can serve one NFS home and appends to a shared
// file interleave on NFS; rename is atomic there, appends are not.
package labsvc

import (
	crand "crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// crockford is the base32 alphabet ULIDs use (no I, L, O, U).
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewULID returns a 26-character ULID: a 48-bit millisecond timestamp and 80
// random bits in Crockford base32. Event files are named by these; they sort
// by creation time and collide with no coordination between writers. Within
// one process the random part is MONOTONIC inside a millisecond (the standard
// monotonic-ULID rule): a single writer appending quickly gets strictly
// ordered ids, otherwise two events in the same millisecond could read back
// in either order. Across processes, same-millisecond order stays arbitrary.
func NewULID() string {
	ulidMu.Lock()
	ms := time.Now().UnixMilli()
	var rnd [10]byte
	if ms == ulidLastMs {
		rnd = ulidLastRnd
		for i := 9; i >= 0; i-- { // increment the 80-bit big-endian counter
			rnd[i]++
			if rnd[i] != 0 {
				break
			}
		}
	} else {
		_, _ = crand.Read(rnd[:])
		rnd[0] &= 0x7f // headroom so the in-ms counter cannot overflow realistically
	}
	ulidLastMs, ulidLastRnd = ms, rnd
	ulidMu.Unlock()

	v := new(big.Int).SetInt64(ms)
	v.Lsh(v, 80)
	v.Or(v, new(big.Int).SetBytes(rnd[:]))
	out := make([]byte, 26)
	mask := big.NewInt(31)
	tmp := new(big.Int)
	for i := 25; i >= 0; i-- {
		out[i] = crockford[int(tmp.And(v, mask).Int64())]
		v.Rsh(v, 5)
	}
	return string(out)
}

var (
	ulidMu      sync.Mutex
	ulidLastMs  int64
	ulidLastRnd [10]byte
)

// Event is the one primitive: everything in the store is a stream of these.
// Author is "human", "agent", or "machine". Agents get no edit or delete verb
// anywhere in this package, and nothing is ever deleted (a human "hide" event
// removes content from agent-facing reads; the bytes stay).
type Event struct {
	ID     string         `json:"id"`
	Time   string         `json:"time"`
	Author string         `json:"author"`
	Kind   string         `json:"kind"`
	Text   string         `json:"text,omitempty"`
	Data   map[string]any `json:"data,omitempty"`
}

// Root is the store directory: $UT_LAB_ROOT when set (tests), else ~/.argus/lab.
func Root() string {
	if r := os.Getenv("UT_LAB_ROOT"); r != "" {
		return r
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".argus", "lab")
}

// Store is a handle on the on-disk layout. All methods are safe for
// concurrent use from multiple processes: every write is either an exclusive
// create or a rename.
type Store struct{ root string }

func Open() (*Store, error) {
	r := Root()
	if err := os.MkdirAll(r, 0o755); err != nil {
		return nil, err
	}
	return &Store{root: r}, nil
}

func (s *Store) SetDir(set string) string { return filepath.Join(s.root, "sets", set) }
func (s *Store) RunDir(set, run string) string {
	return filepath.Join(s.SetDir(set), "runs", run)
}

// NotesDir holds human notes for a broad scope ("global", "project/<name>",
// "machine/<host>"). Set-, group-, and run-scoped notes live in the set's and
// run's own event logs instead.
func (s *Store) NotesDir(scope ...string) string {
	return filepath.Join(append([]string{s.root, "notes"}, scope...)...)
}

// Append writes one event as its own file under dir/events/. The caller sets
// author, kind, text, and data; id and time are stamped here.
func (s *Store) Append(dir string, e Event) (Event, error) {
	e.ID = NewULID()
	e.Time = time.Now().UTC().Format(time.RFC3339)
	evDir := filepath.Join(dir, "events")
	if err := os.MkdirAll(evDir, 0o755); err != nil {
		return e, err
	}
	b, err := json.MarshalIndent(e, "", " ")
	if err != nil {
		return e, err
	}
	tmp := filepath.Join(evDir, ".tmp-"+e.ID)
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return e, err
	}
	return e, os.Rename(tmp, filepath.Join(evDir, e.ID+".json"))
}

// Events reads dir/events in id (= creation) order. Agent-facing readers pass
// agentView=true, which drops hidden events and the hide markers themselves;
// the hub passes false and sees everything.
func (s *Store) Events(dir string, agentView bool) ([]Event, error) {
	evDir := filepath.Join(dir, "events")
	ents, err := os.ReadDir(evDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	names := make([]string, 0, len(ents))
	for _, d := range ents {
		if strings.HasSuffix(d.Name(), ".json") && !strings.HasPrefix(d.Name(), ".") {
			names = append(names, d.Name())
		}
	}
	sort.Strings(names)
	evs := make([]Event, 0, len(names))
	hidden := map[string]bool{}
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(evDir, n))
		if err != nil {
			continue
		}
		var e Event
		if json.Unmarshal(b, &e) != nil {
			continue
		}
		if e.Kind == "hide" {
			if t, ok := e.Data["target"].(string); ok {
				hidden[t] = true
			}
		}
		evs = append(evs, e)
	}
	if !agentView {
		return evs, nil
	}
	out := make([]Event, 0, len(evs))
	for _, e := range evs {
		if e.Kind == "hide" || hidden[e.ID] {
			continue
		}
		out = append(out, e)
	}
	return out, nil
}

// randomHex returns n random bytes hex-encoded (used for key strings).
func randomHex(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := crand.Read(raw); err != nil {
		return "", err
	}
	const hexdig = "0123456789abcdef"
	out := make([]byte, 0, n*2)
	for _, b := range raw {
		out = append(out, hexdig[b>>4], hexdig[b&15])
	}
	return string(out), nil
}

// StoreID returns this store's stable identity, created once on first ask.
// Two brokers reporting the same id share one store (cluster nodes mounting
// the same NFS home), so store-wide writes need only reach one of them.
func (s *Store) StoreID() string {
	p := filepath.Join(s.root, "store-id")
	if b, err := os.ReadFile(p); err == nil && len(b) > 0 {
		return strings.TrimSpace(string(b))
	}
	id, err := randomHex(16)
	if err != nil {
		return ""
	}
	// O_EXCL: on shared storage the first writer wins and everyone else reads
	f, err := os.OpenFile(p, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		b, _ := os.ReadFile(p)
		return strings.TrimSpace(string(b))
	}
	_, _ = f.WriteString(id)
	_ = f.Close()
	return id
}
