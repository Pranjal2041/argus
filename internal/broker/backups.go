package broker

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const backupRetentionDays = 7

var backupMu sync.Mutex

func homeDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return os.TempDir()
	}
	return home
}

func brokerStateDir() string {
	dir := filepath.Join(homeDir(), ".universal-tmux")
	_ = os.MkdirAll(dir, 0o755)
	return dir
}

func backupRoot() string {
	if root := os.Getenv("UT_BACKUP_ROOT"); root != "" {
		return root
	}
	return filepath.Join(homeDir(), ".argus", "backups")
}

func backupDay(now time.Time) string { return now.Format("2006-01-02") }

// writeFileAtomic keeps the authoritative store valid across a crash or power loss.
func writeFileAtomic(path string, body []byte, mode fs.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".argus-write-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err := f.Chmod(mode); err != nil {
		_ = f.Close()
		return err
	}
	if _, err := f.Write(body); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// writeBackupOnce preserves the first valid state observed on a calendar day. A later
// bad write therefore cannot replace that day's recovery point.
func writeBackupOnce(root, relative string, body []byte, mode fs.FileMode, now time.Time) error {
	if len(body) == 0 {
		return nil
	}
	dst := filepath.Join(root, backupDay(now), relative)
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if errors.Is(err, os.ErrExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err = f.Write(body); err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = os.Remove(dst) // retry on the next hourly pass; never retain a partial backup
	}
	return err
}

func pruneBackupsAt(root string, now time.Time) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	loc := now.Location()
	cutoff := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc).
		AddDate(0, 0, -(backupRetentionDays - 1))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		day, err := time.ParseInLocation("2006-01-02", entry.Name(), loc)
		if err == nil && day.Before(cutoff) {
			if err := os.RemoveAll(filepath.Join(root, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}

func backupUserDataBlobAt(key string, body []byte, now time.Time) error {
	if len(body) == 0 || !json.Valid(body) {
		return nil
	}
	backupMu.Lock()
	defer backupMu.Unlock()
	root := backupRoot()
	if err := writeBackupOnce(root, filepath.Join("broker", "userdata-"+safeUserDataKey(key)+".json"), body, 0o600, now); err != nil {
		return err
	}
	return pruneBackupsAt(root, now)
}

func copyBackupSource(root, relative, source string, now time.Time, requireJSON bool) error {
	body, err := os.ReadFile(source)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if requireJSON && !json.Valid(body) {
		return nil // source may be between legacy non-atomic writes; retry next hour
	}
	return writeBackupOnce(root, relative, body, 0o600, now)
}

func backupDurableStateAt(now time.Time) error {
	backupMu.Lock()
	defer backupMu.Unlock()
	root := backupRoot()

	// Broker-owned JSON: synced planning data, hidden panels, session history, and
	// the small Jupyter state file. Executables, caches, sockets, and logs are excluded.
	entries, err := os.ReadDir(brokerStateDir())
	if err != nil {
		return err
	}
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		if !(strings.HasPrefix(name, "userdata-") || strings.HasPrefix(name, "hidden-") ||
			strings.HasPrefix(name, "history-") || name == "jupyter.json") {
			continue
		}
		if err := copyBackupSource(root, filepath.Join("broker", name), filepath.Join(brokerStateDir(), name), now, true); err != nil {
			return err
		}
	}

	// Hub-only state should not make every Linux cluster broker walk a shared Lab store.
	// UT_BACKUP_INCLUDE_HUB_STATE exists for cross-platform tests and headless hubs.
	if runtime.GOOS == "darwin" || os.Getenv("UT_BACKUP_INCLUDE_HUB_STATE") == "1" {
		// The complete macOS preference domain is small and contains other user-authored
		// state (dashboards, notebooks, detected W&B runs, settings) beyond /userdata.
		prefs := filepath.Join(homeDir(), "Library", "Preferences", "dev.universaltmux.mac.plist")
		if err := copyBackupSource(root, filepath.Join("macos", "dev.universaltmux.mac.plist"), prefs, now, false); err != nil {
			return err
		}

		// Lab artifacts can be hundreds of MB and are append-only/mirrored. Back up its
		// compact control-plane metadata instead: keys, set manifests, policies, notes,
		// approvals, proposals, and result events (all JSON), plus the store identity.
		labRoot := os.Getenv("UT_LAB_ROOT")
		if labRoot == "" {
			labRoot = filepath.Join(homeDir(), ".argus", "lab")
		}
		if err := filepath.WalkDir(labRoot, func(path string, entry fs.DirEntry, walkErr error) error {
			if errors.Is(walkErr, os.ErrNotExist) {
				return nil
			}
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() {
				if entry.Name() == "files" || entry.Name() == "snapshot" {
					return filepath.SkipDir
				}
				return nil
			}
			name := entry.Name()
			if name != "store-id" && !strings.HasSuffix(name, ".json") {
				return nil
			}
			rel, err := filepath.Rel(labRoot, path)
			if err != nil {
				return err
			}
			return copyBackupSource(root, filepath.Join("lab", rel), path, now, strings.HasSuffix(name, ".json"))
		}); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	manifest, _ := json.MarshalIndent(struct {
		CreatedAt     string   `json:"createdAt"`
		RetentionDays int      `json:"retentionDays"`
		Includes      []string `json:"includes"`
		Excludes      []string `json:"excludes"`
	}{
		CreatedAt:     now.UTC().Format(time.RFC3339),
		RetentionDays: backupRetentionDays,
		Includes:      []string{"broker JSON state", "macOS preferences on the hub", "Lab control-plane metadata on the hub"},
		Excludes:      []string{"executables", "caches", "sockets", "logs", "large immutable Lab artifacts"},
	}, "", "  ")
	if err := writeBackupOnce(root, "manifest.json", manifest, 0o600, now); err != nil {
		return err
	}

	return pruneBackupsAt(root, now)
}

// BackupDurableState creates today's immutable recovery point. Calling it repeatedly is
// cheap: existing files are never overwritten.
func BackupDurableState() error { return backupDurableStateAt(time.Now()) }

// RunDailyBackupLoop fills any newly-created metadata into today's snapshot hourly and
// creates a new snapshot after the local calendar day rolls over.
func RunDailyBackupLoop(ctx context.Context) {
	ticker := time.NewTicker(time.Hour)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := BackupDurableState(); err != nil {
				log.Printf("warn: durable-state backup: %v", err)
			}
		}
	}
}
