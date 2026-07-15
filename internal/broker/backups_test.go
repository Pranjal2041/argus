package broker

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDailyUserDataBackupKeepsFirstStateAndSevenDays(t *testing.T) {
	home := isolatedUserDataHome(t)
	root := filepath.Join(home, "backups")
	start := time.Date(2026, 7, 1, 10, 0, 0, 0, time.Local)

	first := testEnvelope(t, 100, false, `[{"id":"first"}]`)
	if err := backupUserDataBlobAt("todos", first, start); err != nil {
		t.Fatal(err)
	}
	if err := backupUserDataBlobAt("todos", testEnvelope(t, 101, false, `[{"id":"later"}]`), start.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	dayOne := filepath.Join(root, "2026-07-01", "broker", "userdata-todos.json")
	if got, err := os.ReadFile(dayOne); err != nil || string(got) != string(first) {
		t.Fatalf("day-one recovery point = %s, %v; want first observed state", got, err)
	}

	for day := 1; day < 8; day++ {
		now := start.AddDate(0, 0, day)
		body := testEnvelope(t, int64(100+day), false, `[{"id":"daily"}]`)
		if err := backupUserDataBlobAt("todos", body, now); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "2026-07-01")); !os.IsNotExist(err) {
		t.Fatalf("oldest backup should have expired, stat err = %v", err)
	}
	for day := 2; day <= 8; day++ {
		path := filepath.Join(root, time.Date(2026, 7, day, 0, 0, 0, 0, time.Local).Format("2006-01-02"))
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("retained backup %s: %v", path, err)
		}
	}
}

func TestDurableStateBackupCoversBrokerMacAndLabMetadata(t *testing.T) {
	home := isolatedUserDataHome(t)
	labRoot := filepath.Join(home, "test-lab")
	t.Setenv("UT_LAB_ROOT", labRoot)
	t.Setenv("UT_BACKUP_INCLUDE_HUB_STATE", "1")
	mustWrite := func(path, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	mustWrite(filepath.Join(brokerStateDir(), "history-test.json"), `[]`)
	mustWrite(filepath.Join(brokerStateDir(), "hidden-test.json"), `["panel"]`)
	mustWrite(filepath.Join(brokerStateDir(), "ignored.log"), `not durable state`)
	mustWrite(filepath.Join(home, "Library", "Preferences", "dev.universaltmux.mac.plist"), `plist-bytes`)
	mustWrite(filepath.Join(labRoot, "store-id"), `store-1`)
	mustWrite(filepath.Join(labRoot, "sets", "s-one", "set.json"), `{"name":"one"}`)
	mustWrite(filepath.Join(labRoot, "sets", "s-one", "runs", "R1", "log.txt"), `large artifact`)

	now := time.Date(2026, 7, 14, 9, 0, 0, 0, time.Local)
	if err := backupDurableStateAt(now); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(home, "backups", "2026-07-14")
	for _, relative := range []string{
		"manifest.json",
		filepath.Join("broker", "history-test.json"),
		filepath.Join("broker", "hidden-test.json"),
		filepath.Join("macos", "dev.universaltmux.mac.plist"),
		filepath.Join("lab", "store-id"),
		filepath.Join("lab", "sets", "s-one", "set.json"),
	} {
		if _, err := os.Stat(filepath.Join(root, relative)); err != nil {
			t.Errorf("missing backup %s: %v", relative, err)
		}
	}
	for _, relative := range []string{
		filepath.Join("broker", "ignored.log"),
		filepath.Join("lab", "sets", "s-one", "runs", "R1", "log.txt"),
	} {
		if _, err := os.Stat(filepath.Join(root, relative)); !os.IsNotExist(err) {
			t.Errorf("transient/large file was backed up: %s", relative)
		}
	}
}
