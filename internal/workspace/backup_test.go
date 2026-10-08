package workspace

import (
	"path/filepath"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestDailyBackupsAreReadableIdempotentAndRetainSevenDays(t *testing.T) {
	s := testStore(t)
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	for i := 0; i < 10; i++ {
		if err := s.BackupDaily(); err != nil {
			t.Fatal(err)
		}
		if err := s.BackupDaily(); err != nil {
			t.Fatal(err)
		}
		now = now.Add(24 * time.Hour)
	}
	files, err := filepath.Glob(filepath.Join(s.root, "backups", "*.db"))
	if err != nil || len(files) != 7 {
		t.Fatalf("backups: %d, %v", len(files), err)
	}
	if filepath.Base(files[0]) != "2026-01-04.db" {
		t.Fatalf("wrong retention boundary: %s", files[0])
	}
	for _, file := range files {
		db, err := bolt.Open(file, 0600, &bolt.Options{ReadOnly: true})
		if err != nil {
			t.Fatal(err)
		}
		err = db.View(func(tx *bolt.Tx) error {
			for err := range tx.Check() {
				return err
			}
			return nil
		})
		db.Close()
		if err != nil {
			t.Fatal(err)
		}
	}
}
