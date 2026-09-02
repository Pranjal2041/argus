//go:build windows

package recovery

import "testing"

func TestWindowsRestoreEntryPointsShareUnsupportedContract(t *testing.T) {
	store := NewStore("ut")
	wantSnapshot := "snapshot-1"

	for name, response := range map[string]RestoreResponse{
		"normal":          store.Restore(wantSnapshot, []string{"panel"}, 1),
		"captured launch": store.RestoreCapturedLaunch(wantSnapshot, []string{"panel"}, 1),
	} {
		if response.SnapshotID != wantSnapshot {
			t.Fatalf("%s restore snapshot ID = %q, want %q", name, response.SnapshotID, wantSnapshot)
		}
		if len(response.Results) != 1 || response.Results[0].State != RestoreFailed {
			t.Fatalf("%s restore response = %#v, want one failed result", name, response)
		}
		if response.Results[0].Detail != "workspace recovery is not yet supported on Windows" {
			t.Fatalf("%s restore detail = %q", name, response.Results[0].Detail)
		}
	}
}
