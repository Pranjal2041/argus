package broker

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testEnvelope(t *testing.T, ts int64, allowDestructive bool, data string) []byte {
	t.Helper()
	var raw json.RawMessage = []byte(data)
	body, err := json.Marshal(userDataEnvelope{
		UpdatedAt: ts, Data: raw, AllowDestructive: allowDestructive,
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func isolatedUserDataHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("UT_BACKUP_ROOT", filepath.Join(home, "backups"))
	return home
}

func TestDecodeUnattendedMode(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		want UnattendedModeState
	}{
		{"missing", "", UnattendedModeState{}},
		{"named data", `{"updatedAt":42,"data":{"enabled":true}}`, UnattendedModeState{Enabled: true, UpdatedAt: 42}},
		{"scalar compatibility", `{"updatedAt":43,"data":true}`, UnattendedModeState{Enabled: true, UpdatedAt: 43}},
		{"malformed data stays off", `{"updatedAt":44,"data":"yes"}`, UnattendedModeState{UpdatedAt: 44}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := decodeUnattendedMode([]byte(tc.body)); got != tc.want {
				t.Fatalf("decode = %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestUnattendedModePersistsThroughUserDataStore(t *testing.T) {
	isolatedUserDataHome(t)
	_ = os.Remove(userDataPath(unattendedModeKey))

	if got := UnattendedMode(); got.Enabled {
		t.Fatalf("new mode unexpectedly enabled: %+v", got)
	}
	on := SetUnattendedMode(true)
	if !on.Enabled || on.UpdatedAt == 0 {
		t.Fatalf("enable did not persist: %+v", on)
	}
	if got := UnattendedMode(); got != on {
		t.Fatalf("persisted mode = %+v, want %+v", got, on)
	}
	off := SetUnattendedMode(false)
	if off.Enabled || off.UpdatedAt < on.UpdatedAt {
		t.Fatalf("disable did not win: before=%+v after=%+v", on, off)
	}
}

func TestUserDataMigratesHostnameStoresToStablePath(t *testing.T) {
	isolatedUserDataHome(t)
	dir := brokerStateDir()
	older := testEnvelope(t, 100, false, `[{"id":"old"}]`)
	newer := testEnvelope(t, 200, false, `[{"id":"new"},{"id":"newer"}]`)
	if err := os.WriteFile(filepath.Join(dir, "userdata-todos-Old-Mac.json"), older, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "userdata-todos-New-Mac.local.json"), newer, 0o600); err != nil {
		t.Fatal(err)
	}

	got := UserData("todos")
	if string(got) != string(newer) {
		t.Fatalf("migration picked %s, want newest %s", got, newer)
	}
	stable, err := os.ReadFile(userDataPath("todos"))
	if err != nil {
		t.Fatalf("stable store was not created: %v", err)
	}
	if string(stable) != string(newer) {
		t.Fatalf("stable store = %s, want %s", stable, newer)
	}
}

func TestUserDataMigrationPrefersCompleteCopyOnTimestampTie(t *testing.T) {
	isolatedUserDataHome(t)
	dir := brokerStateDir()
	empty := testEnvelope(t, 100, false, `[]`)
	full := testEnvelope(t, 100, false, `[{"id":"kept"}]`)
	if err := os.WriteFile(filepath.Join(dir, "userdata-notes-a.json"), empty, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "userdata-notes-b.json"), full, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := UserData("notes"); string(got) != string(full) {
		t.Fatalf("migration picked %s, want complete copy %s", got, full)
	}
}

func TestUserDataRejectsUnapprovedDestructiveReplacement(t *testing.T) {
	isolatedUserDataHome(t)
	full := testEnvelope(t, 100, false, `[{"id":"board","items":[{"id":"one"},{"id":"two"}]}]`)
	if got := SetUserData("todos", full); string(got) != string(full) {
		t.Fatalf("initial write = %s, want %s", got, full)
	}

	accidental := testEnvelope(t, 200, false, `[{"id":"empty-misc","items":[]}]`)
	winner := SetUserData("todos", accidental)
	if identifiedRecordCount(winner) != 3 {
		t.Fatalf("accidental reset won: %s", winner)
	}
	if userDataUpdatedAt(winner) <= 200 {
		t.Fatalf("preserved state did not get an authoritative timestamp: %s", winner)
	}
	if stored := UserData("todos"); string(stored) != string(winner) {
		t.Fatalf("stored winner = %s, returned winner = %s", stored, winner)
	}
}

func TestUserDataAcceptsExplicitDestructiveReplacement(t *testing.T) {
	isolatedUserDataHome(t)
	full := testEnvelope(t, 100, false, `[{"id":"one"},{"id":"two"}]`)
	SetUserData("workflows", full)
	empty := testEnvelope(t, time.Now().UnixMilli()+1000, true, `[]`)
	if got := SetUserData("workflows", empty); string(got) != string(empty) {
		t.Fatalf("explicit deletion = %s, want %s", got, empty)
	}
}

func TestUserDataRejectsMalformedIncomingEnvelope(t *testing.T) {
	isolatedUserDataHome(t)
	full := testEnvelope(t, 100, false, `[{"id":"kept"}]`)
	SetUserData("notes", full)
	if got := SetUserData("notes", []byte(`{"updatedAt":200}`)); string(got) != string(full) {
		t.Fatalf("malformed envelope replaced data: %s", got)
	}
}
