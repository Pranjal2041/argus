package workspace

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}
func mutation(id, collection, record string, revision uint64, data string) Mutation {
	return Mutation{ID: id, Collection: collection, RecordID: record, BaseRevision: &revision, Data: json.RawMessage(data)}
}

func TestCommitReceiptAndCursorSurviveRestart(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	info, _ := s.Enable()
	m := mutation("edit-1", "session-backlog", "broker/lifetime", 0, `{"value":true}`)
	first, err := s.Mutate(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	gotInfo, _ := s.Info()
	if gotInfo != info {
		t.Fatalf("identity changed: %+v vs %+v", gotInfo, info)
	}
	retry, err := s.Mutate(m)
	if err != nil {
		t.Fatal(err)
	}
	if retry.Cursor != first.Cursor || retry.Record.Revision != first.Record.Revision {
		t.Fatal("lost acknowledgment caused duplicate commit")
	}
	snapshot, err := s.Snapshot("")
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Records) != 1 || snapshot.Cursor != first.Cursor {
		t.Fatalf("snapshot %+v", snapshot)
	}
	changes, err := s.Changes(0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(changes.Records) != 1 || changes.Cursor != snapshot.Cursor {
		t.Fatalf("changes %+v", changes)
	}
	m.Data = json.RawMessage(`{"value":false}`)
	if _, err := s.Mutate(m); !errors.Is(err, ErrMutationReuse) {
		t.Fatalf("mutation ID reuse: %v", err)
	}
}

func TestConcurrentRetriesCommitExactlyOnce(t *testing.T) {
	s := testStore(t)
	m := mutation("same-operation", "notebooks", "notebook-1", 0, `{"path":"/work/a.ipynb"}`)
	var wg sync.WaitGroup
	for range 30 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Mutate(m); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	snapshot, _ := s.Snapshot("")
	if snapshot.Cursor != 1 || len(snapshot.Records) != 1 {
		t.Fatalf("duplicate commits: %+v", snapshot)
	}
}

func TestConflictAndDeletionPreserveState(t *testing.T) {
	s := testStore(t)
	first, _ := s.Mutate(mutation("a", "dashboards", "d", 0, `{"name":"first"}`))
	_, err := s.Mutate(mutation("b", "dashboards", "d", 0, `{"name":"stale"}`))
	var conflict *Conflict
	if !errors.As(err, &conflict) || conflict.Current.Revision != first.Cursor {
		t.Fatalf("want conflict, got %v", err)
	}
	del := mutation("delete", "dashboards", "d", first.Cursor, "")
	del.Delete = true
	deleted, err := s.Mutate(del)
	if err != nil {
		t.Fatal(err)
	}
	if !deleted.Record.Deleted {
		t.Fatal("missing tombstone")
	}
	_, err = s.Mutate(mutation("stale-create", "dashboards", "d", 0, `{"name":"resurrected"}`))
	if !errors.As(err, &conflict) {
		t.Fatal("deleted record was resurrected by stale create")
	}
	snapshot, _ := s.Snapshot("")
	if snapshot.Cursor != 2 {
		t.Fatal("failed writes advanced cursor")
	}
}

func TestActivityRevisionAcrossProvidersRenameAndRestart(t *testing.T) {
	for _, lifetime := range []string{"tmux:server:1:session:7", "conpty:4c7c3f4d"} {
		t.Run(lifetime, func(t *testing.T) {
			root := t.TempDir()
			s, err := Open(root)
			if err != nil {
				t.Fatal(err)
			}
			a, err := s.ActivityRevision(lifetime, "waiting", 100)
			if err != nil {
				t.Fatal(err)
			}
			b, _ := s.ActivityRevision(lifetime, "waiting", 100)
			if a != b {
				t.Fatal("unchanged activity changed revision")
			}
			s.Close()
			s, err = Open(root)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			c, _ := s.ActivityRevision(lifetime, "waiting", 100)
			if c != a {
				t.Fatal("restart invented activity")
			}
			d, _ := s.ActivityRevision(lifetime, "working", 101)
			if d <= c {
				t.Fatal("new activity did not invalidate acknowledgment")
			}
			e, _ := s.ActivityRevision(lifetime+"-new", "waiting", 100)
			if e <= d {
				t.Fatal("recreated session reused activity identity")
			}
		})
	}
}

func TestLeaseFencesDelayedPublisher(t *testing.T) {
	s := testStore(t)
	now := time.Unix(100, 0)
	s.now = func() time.Time { return now }
	old, err := s.Claim("usage", "collector-a", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Claim("usage", "collector-b", time.Minute); !errors.Is(err, ErrLease) {
		t.Fatal("two active collectors")
	}
	now = now.Add(2 * time.Minute)
	current, err := s.Claim("usage", "collector-b", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if current.Fence <= old.Fence {
		t.Fatal("lease fence did not advance")
	}
	m := mutation("old-response", "usage", "account", 0, `{"observedAt":1}`)
	m.Lease = &old
	if _, err := s.Mutate(m); !errors.Is(err, ErrLease) {
		t.Fatalf("stale publisher accepted: %v", err)
	}
	m.ID = "new-response"
	m.Lease = &current
	if _, err := s.Mutate(m); err != nil {
		t.Fatal(err)
	}
}

func TestEveryCollectorCollectionRequiresItsOwnLease(t *testing.T) {
	s := testStore(t)
	for _, collection := range []string{"usage", "cc-status"} {
		m := mutation("unowned-"+collection, collection, "value", 0, `{"status":"ok"}`)
		if _, err := s.Mutate(m); !errors.Is(err, ErrLease) {
			t.Fatalf("%s accepted an unowned write: %v", collection, err)
		}
		lease, err := s.Claim("wrong-collection", "worker", time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		m.Lease = &lease
		if _, err := s.Mutate(m); !errors.Is(err, ErrLease) {
			t.Fatalf("%s accepted another collection's lease: %v", collection, err)
		}
	}
}

func TestChangeCursorPaginationAndExpiry(t *testing.T) {
	s := testStore(t)
	err := s.db.Update(func(tx *bolt.Tx) error {
		for i := 0; i < eventRetention+2; i++ {
			r := Record{Collection: "journal", ID: fmt.Sprint(i), Data: json.RawMessage(`{"event":"seen"}`)}
			if err := writeRecord(tx, &r); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Changes(0, 10); !errors.Is(err, ErrCursorExpired) {
		t.Fatalf("old cursor: %v", err)
	}
	page, err := s.Changes(2, 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Records) != 7 || page.Cursor != 9 || !page.More {
		t.Fatalf("page: %+v", page)
	}
	if _, err := s.Changes(eventRetention+3, 10); !errors.Is(err, ErrCursorExpired) {
		t.Fatal("future cursor accepted")
	}
}

func TestBackupIsConsistentAndOpenable(t *testing.T) {
	s := testStore(t)
	_, _ = s.Mutate(mutation("a", "artifacts", "artifact", 0, `{"title":"saved"}`))
	root := t.TempDir()
	if err := s.Backup(filepath.Join(root, "workspace.db")); err != nil {
		t.Fatal(err)
	}
	copy, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer copy.Close()
	snapshot, _ := copy.Snapshot("")
	if snapshot.Cursor != 1 || len(snapshot.Records) != 1 {
		t.Fatal("incomplete backup")
	}
}

func TestHTTPErrorContractAndLocalEnrollment(t *testing.T) {
	s := testStore(t)
	mux := http.NewServeMux()
	s.RegisterRoutes(mux)
	r := httptest.NewRequest("POST", "/workspace/enable", nil)
	r.RemoteAddr = "100.100.1.1:3210"
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatalf("remote enrollment %d", w.Code)
	}
	r = httptest.NewRequest("POST", "/workspace/enable", nil)
	r.RemoteAddr = "127.0.0.1:3210"
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatalf("local enrollment %d", w.Code)
	}
	for _, test := range []struct {
		body string
		want int
	}{
		{`{"mutationID":"one","collection":"dashboards","id":"a","baseRevision":0,"data":{"name":"A"}}`, 200},
		{`{"mutationID":"two","collection":"dashboards","id":"a","baseRevision":0,"data":{"name":"B"}}`, 409},
		{`{"mutationID":"three","collection":"runtime-activity","id":"a","baseRevision":0,"data":{}}`, 400},
		{`{"mutationID":"four","collection":"dashboards","id":"b","data":{}}`, 400},
	} {
		w = httptest.NewRecorder()
		mux.ServeHTTP(w, httptest.NewRequest("POST", "/workspace/mutate", bytes.NewBufferString(test.body)))
		if w.Code != test.want {
			t.Fatalf("got %d want %d: %s", w.Code, test.want, w.Body.String())
		}
	}
}

func TestContentAddressedBlobRoundTripAndRange(t *testing.T) {
	s := testStore(t)
	mux := http.NewServeMux()
	s.RegisterRoutes(mux)
	data := []byte("a portable saved artifact")
	h := sha256.Sum256(data)
	path := "/workspace/blobs/" + hex.EncodeToString(h[:])
	w := httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("PUT", path, bytes.NewReader(data)))
	if w.Code != 200 {
		t.Fatalf("upload: %d %s", w.Code, w.Body.String())
	}
	r := httptest.NewRequest("GET", path, nil)
	r.Header.Set("Range", "bytes=2-9")
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, r)
	if w.Code != 206 || w.Body.String() != string(data[2:10]) {
		t.Fatalf("range %d %q", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("PUT", path, bytes.NewBufferString("wrong")))
	if w.Code != 422 {
		t.Fatal("mismatched hash accepted")
	}
	w = httptest.NewRecorder()
	mux.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
	got, _ := io.ReadAll(w.Result().Body)
	if !bytes.Equal(data, got) {
		t.Fatal("failed upload overwrote saved artifact")
	}
}
