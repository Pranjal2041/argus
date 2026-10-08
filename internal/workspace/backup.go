package workspace

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// BackupDaily keeps seven complete transaction snapshots. Immutable blobs stay
// in the content-addressed store, so older manifests remain recoverable too.
func (s *Store) BackupDaily() error {
	dir := filepath.Join(s.root, "backups")
	target := filepath.Join(dir, s.now().UTC().Format("2006-01-02")+".db")
	if _, err := os.Stat(target); err == nil {
		return nil
	}
	temporary := target + ".tmp"
	defer os.Remove(temporary)
	if err := s.Backup(temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, target); err != nil {
		return err
	}
	files, err := filepath.Glob(filepath.Join(dir, "*.db"))
	if err != nil {
		return err
	}
	sort.Strings(files)
	for len(files) > 7 {
		if err := os.Remove(files[0]); err != nil {
			return err
		}
		files = files[1:]
	}
	return nil
}

func (s *Store) RunBackupLoop(ctx context.Context, report func(error)) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		if err := s.BackupDaily(); err != nil && report != nil {
			report(err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
