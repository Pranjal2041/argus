package labsvc

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Key is a human-approved credential. One key corresponds to exactly one
// experiment set and is inert until the human approves it. Authorization is
// bound to the Lab store, not the hostname: every node mounting one shared
// store (for example babel-*) can use the same key, while an unrelated store
// cannot. Machine records where the request originated; each run separately
// records where it actually executed. Each key lives in its own file under
// keys/, rewritten whole via rename, so status changes stay atomic on NFS.
type Key struct {
	Key     string `json:"key"`
	Set     string `json:"set,omitempty"` // assigned at approval
	Project string `json:"project"`
	Machine string `json:"machine"`         // request origin; never an authorization boundary
	Store   string `json:"store,omitempty"` // stable StoreID; absent on legacy records
	Cwd     string `json:"cwd"`
	Session string `json:"session,omitempty"` // tmux session at login (advisory, for the hub)
	Status  string `json:"status"`            // pending | active | denied | revoked
	Note    string `json:"note,omitempty"`
	Created string `json:"created"`
	Decided string `json:"decided,omitempty"`
}

// Hostname is the short host name recorded as request/run provenance and used
// to select machine-scoped guidance. It is deliberately not a key boundary.
func Hostname() string {
	h, _ := os.Hostname()
	if i := strings.Index(h, "."); i > 0 {
		h = h[:i]
	}
	return h
}

func (s *Store) keysDir() string { return filepath.Join(s.root, "keys") }

func (s *Store) writeKey(k Key) error {
	if err := os.MkdirAll(s.keysDir(), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(k, "", " ")
	if err != nil {
		return err
	}
	// A unique temp file matters on a shared store: two Babel nodes can race to
	// migrate the same legacy key. Both renames may safely publish identical
	// content; neither writer can steal the other's fixed temp path.
	tmp, err := os.CreateTemp(s.keysDir(), ".tmp-"+k.Key+"-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, filepath.Join(s.keysDir(), k.Key+".json"))
}

// CreateKeyRequest files a pending key. The suggested project name usually
// comes from the folder the agent ran in; the human can rename at approval.
// The session name is advisory context so the hub can say WHO is asking.
func (s *Store) CreateKeyRequest(project, cwd, session string) (Key, error) {
	kh, err := randomHex(16)
	if err != nil {
		return Key{}, err
	}
	k := Key{
		Key:     kh,
		Project: project,
		Machine: Hostname(),
		Store:   s.StoreID(),
		Cwd:     cwd,
		Session: session,
		Status:  "pending",
		Created: time.Now().UTC().Format(time.RFC3339),
	}
	if k.Store == "" {
		return Key{}, errors.New("could not establish Lab store identity")
	}
	return k, s.writeKey(k)
}

// Keys lists every key on this store, oldest first.
func (s *Store) Keys() ([]Key, error) {
	ents, err := os.ReadDir(s.keysDir())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var ks []Key
	for _, d := range ents {
		if !strings.HasSuffix(d.Name(), ".json") || strings.HasPrefix(d.Name(), ".") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(s.keysDir(), d.Name()))
		if err != nil {
			continue
		}
		var k Key
		if json.Unmarshal(b, &k) == nil && k.Key != "" {
			ks = append(ks, k)
		}
	}
	sort.Slice(ks, func(i, j int) bool { return ks[i].Created < ks[j].Created })
	return ks, nil
}

// Lookup resolves a full key or an unambiguous prefix (at least 6 chars).
func (s *Store) Lookup(prefix string) (Key, error) {
	if len(prefix) < 6 {
		return Key{}, errors.New("key (or prefix) must be at least 6 characters")
	}
	ks, err := s.Keys()
	if err != nil {
		return Key{}, err
	}
	var hits []Key
	for _, k := range ks {
		if strings.HasPrefix(k.Key, prefix) {
			hits = append(hits, k)
		}
	}
	switch len(hits) {
	case 0:
		return Key{}, fmt.Errorf("no key matches %q", prefix)
	case 1:
		return hits[0], nil
	default:
		return Key{}, fmt.Errorf("%d keys match %q, give more characters", len(hits), prefix)
	}
}

// Decide approves or denies a pending key. Approval creates the set and
// activates the key; a non-empty project renames the set's project label.
func (s *Store) Decide(prefix string, approve bool, project, note string) (Key, error) {
	k, err := s.Lookup(prefix)
	if err != nil {
		return k, err
	}
	if k.Status != "pending" {
		return k, fmt.Errorf("key %s is %s, not pending", k.Key[:8], k.Status)
	}
	k.Decided = time.Now().UTC().Format(time.RFC3339)
	k.Note = note
	if k.Store == "" {
		k.Store = s.StoreID() // migrate pending keys created before store-bound access
	}
	if k.Store == "" {
		return k, errors.New("could not establish Lab store identity")
	}
	if !approve {
		k.Status = "denied"
		return k, s.writeKey(k)
	}
	if project != "" {
		k.Project = project
	}
	set, err := s.newSet(k)
	if err != nil {
		return k, err
	}
	k.Set = set
	k.Status = "active"
	if err := s.writeKey(k); err != nil {
		return k, err
	}
	_, err = s.Append(s.SetDir(set), Event{
		Author: "human", Kind: "set-created",
		Text: "set created for project " + k.Project,
		Data: map[string]any{"project": k.Project, "machine": k.Machine, "store": k.Store,
			"cwd": k.Cwd, "key": k.Key[:8]},
	})
	return k, err
}

// Revoke deactivates a key. The set and its records stay; only access ends.
func (s *Store) Revoke(prefix string) (Key, error) {
	k, err := s.Lookup(prefix)
	if err != nil {
		return k, err
	}
	if k.Status != "active" && k.Status != "pending" {
		return k, fmt.Errorf("key %s is already %s", k.Key[:8], k.Status)
	}
	k.Status = "revoked"
	k.Decided = time.Now().UTC().Format(time.RFC3339)
	return k, s.writeKey(k)
}

// ActiveKey resolves the key a CLI command should use: the explicit value
// beats $UT_LAB_KEY. It enforces status and the store boundary. A legacy key
// without Store is adopted by the store that already contains both the key and
// its assigned set, then atomically rewritten; its old Machine remains origin
// provenance and never prevents use from another node mounting that store.
func (s *Store) ActiveKey(val string) (Key, error) {
	if val == "" {
		val = os.Getenv("UT_LAB_KEY")
	}
	if val == "" {
		return Key{}, errors.New("no key: export UT_LAB_KEY or pass --key (request one with `ut lab login`)")
	}
	k, err := s.Lookup(val)
	if err != nil {
		return k, err
	}
	switch k.Status {
	case "active":
	case "pending":
		return k, fmt.Errorf("key %s is pending approval — ask the human to run `ut lab approve %s`", k.Key[:8], k.Key[:8])
	default:
		return k, fmt.Errorf("key %s is %s", k.Key[:8], k.Status)
	}
	currentStore := s.StoreID()
	if currentStore == "" {
		return k, errors.New("could not establish Lab store identity")
	}
	if k.Store != "" && k.Store != currentStore {
		return k, fmt.Errorf("key %s belongs to Lab store %s, but this machine is using store %s",
			k.Key[:8], shortStore(k.Store), shortStore(currentStore))
	}
	if k.Set == "" {
		return k, fmt.Errorf("active key %s has no experiment set", k.Key[:8])
	}
	meta, err := s.Meta(k.Set)
	if err != nil {
		return k, fmt.Errorf("key %s points to missing set %s: %w", k.Key[:8], k.Set, err)
	}
	if meta.Store != "" && meta.Store != currentStore {
		return k, fmt.Errorf("set %s belongs to Lab store %s, but this machine is using store %s",
			k.Set, shortStore(meta.Store), shortStore(currentStore))
	}
	if k.Store == "" {
		k.Store = currentStore
		if err := s.writeKey(k); err != nil {
			return k, fmt.Errorf("migrate legacy key to store identity: %w", err)
		}
	}
	return k, nil
}

func shortStore(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// SetMeta mirrors sets/<id>/set.json, written once at approval.
type SetMeta struct {
	ID      string `json:"id"`
	Project string `json:"project"`
	Machine string `json:"machine"`         // key-request origin, retained for provenance
	Store   string `json:"store,omitempty"` // authorization/storage boundary
	Cwd     string `json:"cwd"`
	Created string `json:"created"`
}

func (s *Store) newSet(k Key) (string, error) {
	if err := os.MkdirAll(filepath.Join(s.root, "sets"), 0o755); err != nil {
		return "", err
	}
	for i := 0; i < 20; i++ {
		id := "s-" + strings.ToLower(NewULID()[20:])
		dir := s.SetDir(id)
		if err := os.Mkdir(dir, 0o755); err != nil {
			if os.IsExist(err) {
				continue
			}
			return "", err
		}
		m := SetMeta{ID: id, Project: k.Project, Machine: k.Machine, Store: k.Store, Cwd: k.Cwd,
			Created: time.Now().UTC().Format(time.RFC3339)}
		b, _ := json.MarshalIndent(m, "", " ")
		if err := os.WriteFile(filepath.Join(dir, "set.json"), b, 0o644); err != nil {
			return "", err
		}
		return id, nil
	}
	return "", errors.New("could not allocate a set id")
}

// Meta reads a set's set.json.
func (s *Store) Meta(set string) (SetMeta, error) {
	var m SetMeta
	b, err := os.ReadFile(filepath.Join(s.SetDir(set), "set.json"))
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return m, err
	}
	// Virtual migration keeps old set.json records readable and makes every API
	// response explicit without rewriting an otherwise immutable metadata file.
	if m.Store == "" {
		m.Store = s.StoreID()
	}
	return m, nil
}

// Sets lists every set on this store, oldest first.
func (s *Store) Sets() ([]SetMeta, error) {
	ents, err := os.ReadDir(filepath.Join(s.root, "sets"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var ms []SetMeta
	for _, d := range ents {
		if !d.IsDir() {
			continue
		}
		if m, err := s.Meta(d.Name()); err == nil {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool { return ms[i].Created < ms[j].Created })
	return ms, nil
}

// NewRun claims the next run id (R1, R2, …) with an exclusive mkdir, which is
// atomic on NFS, so two concurrent runs can never share an id.
func (s *Store) NewRun(set string) (string, error) {
	base := filepath.Join(s.SetDir(set), "runs")
	if err := os.MkdirAll(base, 0o755); err != nil {
		return "", err
	}
	n := 1
	if ents, err := os.ReadDir(base); err == nil {
		n = len(ents) + 1
	}
	for ; n < 1000000; n++ {
		id := "R" + strconv.Itoa(n)
		err := os.Mkdir(filepath.Join(base, id), 0o755)
		if err == nil {
			return id, nil
		}
		if !os.IsExist(err) {
			return "", err
		}
	}
	return "", errors.New("could not allocate a run id")
}

// Runs lists a set's run ids in numeric order.
func (s *Store) Runs(set string) ([]string, error) {
	ents, err := os.ReadDir(filepath.Join(s.SetDir(set), "runs"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var ids []string
	for _, d := range ents {
		if d.IsDir() && strings.HasPrefix(d.Name(), "R") {
			ids = append(ids, d.Name())
		}
	}
	sort.Slice(ids, func(i, j int) bool {
		a, _ := strconv.Atoi(ids[i][1:])
		b, _ := strconv.Atoi(ids[j][1:])
		return a < b
	})
	return ids, nil
}
