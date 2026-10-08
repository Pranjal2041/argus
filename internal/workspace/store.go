// Package workspace owns durable, versioned app state. It is independent of
// session providers and native clients; a commit includes its receipt and event.
package workspace

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
)

const Protocol = 1
const eventRetention = 20000

var buckets = []string{"meta", "records", "receipts", "events", "leases"}

type Info struct {
	Protocol    int    `json:"protocol"`
	BrokerID    string `json:"brokerID"`
	WorkspaceID string `json:"workspaceID"`
	Enabled     bool   `json:"enabled"`
}

type Record struct {
	Collection string          `json:"collection"`
	ID         string          `json:"id"`
	Revision   uint64          `json:"revision"`
	Data       json.RawMessage `json:"data,omitempty"`
	Deleted    bool            `json:"deleted,omitempty"`
	UpdatedAt  int64           `json:"updatedAt"`
}

type Mutation struct {
	ID           string          `json:"mutationID"`
	Collection   string          `json:"collection"`
	RecordID     string          `json:"id"`
	BaseRevision *uint64         `json:"baseRevision"`
	Data         json.RawMessage `json:"data,omitempty"`
	Delete       bool            `json:"delete,omitempty"`
	Lease        *Lease          `json:"lease,omitempty"`
}

type Receipt struct {
	MutationID string `json:"mutationID"`
	Record     Record `json:"record"`
	Cursor     uint64 `json:"cursor"`
}

type Snapshot struct {
	Info
	Cursor  uint64   `json:"cursor"`
	Records []Record `json:"records"`
}

type ChangePage struct {
	Cursor  uint64   `json:"cursor"`
	Records []Record `json:"records"`
	More    bool     `json:"more"`
}

type Lease struct {
	Name      string `json:"name"`
	Owner     string `json:"owner"`
	Fence     uint64 `json:"fence"`
	ExpiresAt int64  `json:"expiresAt"`
}

type Conflict struct{ Current Record }

func (e *Conflict) Error() string { return "record changed; reconcile before retrying" }

var ErrCursorExpired = errors.New("change cursor expired; read a fresh snapshot")
var ErrLease = errors.New("collector lease is not owned or has expired")
var ErrMutationReuse = errors.New("mutation ID was already used for a different change")

type savedReceipt struct {
	Hash    string  `json:"hash"`
	Receipt Receipt `json:"receipt"`
}

type Store struct {
	db      *bolt.DB
	root    string
	now     func() time.Time
	mu      sync.Mutex
	changed chan struct{}
}

func Open(root string) (*Store, error) {
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	db, err := bolt.Open(filepath.Join(root, "workspace.db"), 0600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, root: root, now: time.Now, changed: make(chan struct{})}
	err = db.Update(func(tx *bolt.Tx) error {
		for _, name := range buckets {
			if _, err := tx.CreateBucketIfNotExists([]byte(name)); err != nil {
				return err
			}
		}
		meta := tx.Bucket([]byte("meta"))
		if meta.Get([]byte("info")) == nil {
			return putJSON(meta, []byte("info"), Info{Protocol: Protocol, BrokerID: newID(), WorkspaceID: newID()})
		}
		var info Info
		if err := json.Unmarshal(meta.Get([]byte("info")), &info); err != nil {
			return err
		}
		if info.Protocol != Protocol || info.BrokerID == "" || info.WorkspaceID == "" {
			return errors.New("unsupported or corrupt workspace identity")
		}
		return nil
	})
	if err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func putJSON(bucket *bolt.Bucket, key []byte, value any) error {
	body, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return bucket.Put(key, body)
}

func infoIn(tx *bolt.Tx) (Info, error) {
	var out Info
	err := json.Unmarshal(tx.Bucket([]byte("meta")).Get([]byte("info")), &out)
	return out, err
}

func (s *Store) Info() (Info, error) {
	var out Info
	err := s.db.View(func(tx *bolt.Tx) (err error) { out, err = infoIn(tx); return err })
	return out, err
}

// Enable is called by an explicitly selected workspace host, not by discovery.
func (s *Store) Enable() (Info, error) {
	var out Info
	err := s.db.Update(func(tx *bolt.Tx) error {
		var err error
		out, err = infoIn(tx)
		if err != nil {
			return err
		}
		out.Enabled = true
		return putJSON(tx.Bucket([]byte("meta")), []byte("info"), out)
	})
	return out, err
}

func recordKey(collection, id string) []byte { return []byte(collection + "\x00" + id) }
func seqKey(seq uint64) []byte               { var b [8]byte; binary.BigEndian.PutUint64(b[:], seq); return b[:] }

func readRecord(tx *bolt.Tx, collection, id string) (Record, error) {
	out := Record{Collection: collection, ID: id}
	if b := tx.Bucket([]byte("records")).Get(recordKey(collection, id)); b != nil {
		if err := json.Unmarshal(b, &out); err != nil {
			return out, err
		}
	}
	return out, nil
}

func (s *Store) Get(collection, id string) (Record, error) {
	var out Record
	err := s.db.View(func(tx *bolt.Tx) (err error) { out, err = readRecord(tx, collection, id); return err })
	return out, err
}

func validKey(v string) bool {
	return len(v) > 0 && len(v) <= 1024 && !strings.ContainsAny(v, "\x00\r\n")
}

func validateMutation(m Mutation) error {
	if !validKey(m.ID) || !validKey(m.Collection) || !validKey(m.RecordID) || m.BaseRevision == nil {
		return errors.New("mutationID, collection, id and baseRevision are required")
	}
	if (m.Collection == "usage" || m.Collection == "cc-status" || m.Collection == "journal") && (m.Lease == nil || m.Lease.Name != m.Collection) {
		return ErrLease
	}
	if !m.Delete {
		var obj map[string]json.RawMessage
		if len(m.Data) > 8<<20 || json.Unmarshal(m.Data, &obj) != nil || obj == nil {
			return errors.New("data must be a JSON object of at most 8 MiB")
		}
	}
	return nil
}

func mutationHash(m Mutation) string {
	// Canonicalize JSON so whitespace/key ordering on a retry is immaterial.
	var data any
	dec := json.NewDecoder(bytes.NewReader(m.Data))
	dec.UseNumber()
	_ = dec.Decode(&data)
	b, _ := json.Marshal([]any{m.Collection, m.RecordID, m.BaseRevision, data, m.Delete})
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func (s *Store) Mutate(m Mutation) (Receipt, error) {
	if err := validateMutation(m); err != nil {
		return Receipt{}, err
	}
	var result Receipt
	changed := false
	err := s.db.Update(func(tx *bolt.Tx) error {
		receipts := tx.Bucket([]byte("receipts"))
		hash := mutationHash(m)
		if raw := receipts.Get([]byte(m.ID)); raw != nil {
			var saved savedReceipt
			if err := json.Unmarshal(raw, &saved); err != nil {
				return err
			}
			if saved.Hash != hash {
				return ErrMutationReuse
			}
			result = saved.Receipt
			return nil
		}
		if m.Lease != nil {
			var lease Lease
			if json.Unmarshal(tx.Bucket([]byte("leases")).Get([]byte(m.Lease.Name)), &lease) != nil ||
				lease.Owner != m.Lease.Owner || lease.Fence != m.Lease.Fence || lease.ExpiresAt <= s.now().UnixMilli() {
				return ErrLease
			}
		}
		current, err := readRecord(tx, m.Collection, m.RecordID)
		if err != nil {
			return err
		}
		if current.Revision != *m.BaseRevision {
			return &Conflict{Current: current}
		}
		record := Record{Collection: m.Collection, ID: m.RecordID, Data: m.Data, Deleted: m.Delete, UpdatedAt: s.now().UnixMilli()}
		if m.Delete {
			record.Data = nil
		}
		if err := writeRecord(tx, &record); err != nil {
			return err
		}
		result = Receipt{MutationID: m.ID, Record: record, Cursor: record.Revision}
		if err := putJSON(receipts, []byte(m.ID), savedReceipt{Hash: hash, Receipt: result}); err != nil {
			return err
		}
		changed = true
		return nil
	})
	if err == nil && changed {
		s.signal()
	}
	return result, err
}

func writeRecord(tx *bolt.Tx, record *Record) error {
	meta := tx.Bucket([]byte("meta"))
	revision, err := meta.NextSequence()
	if err != nil {
		return err
	}
	record.Revision = revision
	if err := putJSON(tx.Bucket([]byte("records")), recordKey(record.Collection, record.ID), record); err != nil {
		return err
	}
	events := tx.Bucket([]byte("events"))
	if err := putJSON(events, seqKey(revision), record); err != nil {
		return err
	}
	if revision > eventRetention {
		return events.Delete(seqKey(revision - eventRetention))
	}
	return nil
}

func (s *Store) Snapshot(collection string) (Snapshot, error) {
	out := Snapshot{Records: []Record{}}
	err := s.db.View(func(tx *bolt.Tx) error {
		var err error
		out.Info, err = infoIn(tx)
		if err != nil {
			return err
		}
		out.Cursor = tx.Bucket([]byte("meta")).Sequence()
		return tx.Bucket([]byte("records")).ForEach(func(_, v []byte) error {
			var r Record
			if err := json.Unmarshal(v, &r); err != nil {
				return err
			}
			if collection == "" || r.Collection == collection {
				out.Records = append(out.Records, r)
			}
			return nil
		})
	})
	return out, err
}

func (s *Store) Changes(after uint64, limit int) (ChangePage, error) {
	if limit <= 0 || limit > 2000 {
		limit = 500
	}
	out := ChangePage{Cursor: after, Records: []Record{}}
	err := s.db.View(func(tx *bolt.Tx) error {
		latest := tx.Bucket([]byte("meta")).Sequence()
		if after > latest || (latest > eventRetention && after < latest-eventRetention) {
			return ErrCursorExpired
		}
		c := tx.Bucket([]byte("events")).Cursor()
		for k, v := c.Seek(seqKey(after + 1)); k != nil; k, v = c.Next() {
			if len(out.Records) == limit {
				out.More = true
				break
			}
			var r Record
			if err := json.Unmarshal(v, &r); err != nil {
				return err
			}
			out.Records = append(out.Records, r)
			out.Cursor = r.Revision
		}
		return nil
	})
	return out, err
}

func (s *Store) signal() {
	s.mu.Lock()
	close(s.changed)
	s.changed = make(chan struct{})
	s.mu.Unlock()
}
func (s *Store) watch() <-chan struct{} { s.mu.Lock(); defer s.mu.Unlock(); return s.changed }

// ActivityRevision changes only on a new activity/state for this session
// lifetime. Reopening a client or restarting a broker does not invent activity.
func (s *Store) ActivityRevision(lineage, state string, activity int64) (uint64, error) {
	if lineage == "" {
		return 0, nil
	}
	data, _ := json.Marshal(struct {
		State    string `json:"state"`
		Activity int64  `json:"activity"`
	}{state, activity})
	var revision uint64
	changed := false
	err := s.db.Update(func(tx *bolt.Tx) error {
		r, err := readRecord(tx, "runtime-activity", lineage)
		if err != nil {
			return err
		}
		if bytes.Equal(r.Data, data) {
			revision = r.Revision
			return nil
		}
		r.Data = data
		r.UpdatedAt = s.now().UnixMilli()
		if err := writeRecord(tx, &r); err != nil {
			return err
		}
		revision = r.Revision
		changed = true
		return nil
	})
	if err == nil && changed {
		s.signal()
	}
	return revision, err
}

// Claim uses a fencing token so a delayed response from a superseded collector
// cannot overwrite the current collector's snapshot, even after a restart.
func (s *Store) Claim(name, owner string, ttl time.Duration) (Lease, error) {
	if !validKey(name) || !validKey(owner) || ttl < time.Second || ttl > 5*time.Minute {
		return Lease{}, errors.New("invalid lease request")
	}
	var out Lease
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte("leases"))
		if raw := b.Get([]byte(name)); raw != nil {
			if err := json.Unmarshal(raw, &out); err != nil {
				return err
			}
		}
		now := s.now().UnixMilli()
		if out.Owner != owner && out.ExpiresAt > now {
			return ErrLease
		}
		if out.Owner != owner || out.ExpiresAt <= now {
			out.Fence++
		}
		out.Name = name
		out.Owner = owner
		out.ExpiresAt = now + ttl.Milliseconds()
		return putJSON(b, []byte(name), out)
	})
	return out, err
}

// Backup emits a transactionally consistent database, never a live-file copy.
func (s *Store) Backup(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	return s.db.View(func(tx *bolt.Tx) error { return tx.CopyFile(path, 0600) })
}

func (s *Store) String() string {
	info, _ := s.Info()
	return fmt.Sprintf("workspace %s", info.WorkspaceID)
}
