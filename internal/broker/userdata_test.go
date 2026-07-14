package broker

import (
	"os"
	"testing"
)

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
	home := t.TempDir()
	t.Setenv("HOME", home)
	// UserHomeDir uses USERPROFILE on Windows and HOME on Unix. Setting both
	// keeps this test hermetic on every broker target.
	t.Setenv("USERPROFILE", home)
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
