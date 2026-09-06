package broker

import (
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
)

func TestWorkspaceMergeSharedContract(t *testing.T) {
	for _, tc := range []struct {
		name, base, local, remote, expected string
		conflict                            bool
	}{
		{"independent notes", `[{"id":"a","text":"old"}]`, `[{"id":"a","text":"old"},{"id":"b","text":"new"}]`, `[{"id":"a","text":"edited"}]`, `[{"id":"a","text":"edited"},{"id":"b","text":"new"}]`, false},
		{"nested todos", `[{"id":"board","items":[{"id":"x","done":false}]}]`, `[{"id":"board","items":[{"id":"x","done":false},{"id":"y","done":false}]}]`, `[{"id":"board","items":[{"id":"x","done":true}]}]`, `[{"id":"board","items":[{"id":"x","done":true},{"id":"y","done":false}]}]`, false},
		{"same field", `[{"id":"a","text":"old"}]`, `[{"id":"a","text":"one"}]`, `[{"id":"a","text":"two"}]`, `null`, true},
		{"delete against edit", `[{"id":"a","text":"old"}]`, `[]`, `[{"id":"a","text":"new"}]`, `null`, true},
		{"delete unchanged", `[{"id":"a","text":"old"}]`, `[]`, `[{"id":"a","text":"old"}]`, `[]`, false},
		{"two fields", `[{"id":"a","text":"old","done":false}]`, `[{"id":"a","text":"new","done":false}]`, `[{"id":"a","text":"old","done":true}]`, `[{"id":"a","text":"new","done":true}]`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var b, l, r, w any
			_ = json.Unmarshal([]byte(tc.base), &b)
			_ = json.Unmarshal([]byte(tc.local), &l)
			_ = json.Unmarshal([]byte(tc.remote), &r)
			_ = json.Unmarshal([]byte(tc.expected), &w)
			conflicts := []string{}
			got := mergeWorkspaceValue(b, l, r, "", &conflicts)
			if tc.conflict != (len(conflicts) > 0) {
				t.Fatalf("conflicts: %v", conflicts)
			}
			if !tc.conflict && !reflect.DeepEqual(got, w) {
				t.Fatalf("got %#v, want %#v", got, w)
			}
		})
	}
}
func TestWorkspaceMergeProtectsDataFromLegacyWriters(t *testing.T) {
	isolatedUserDataHome(t)
	first, status := MergeUserData("notes", []byte(`{"base":[],"data":[{"id":"a","text":"kept"}]}`))
	if status != http.StatusOK {
		t.Fatalf("%d %s", status, first)
	}
	stale := []byte(`{"updatedAt":9999999999999,"allowDestructive":true,"data":[]}`)
	if got := SetUserData("notes", stale); !reflect.DeepEqual(got, first) {
		t.Fatalf("legacy snapshot overwrote merge-protected data: %s", got)
	}
	_, status = MergeUserData("notes", []byte(`{"base":[],"data":[{"id":"a","text":"conflict"}]}`))
	if status != http.StatusConflict {
		t.Fatalf("expected conflict: %d", status)
	}
	if !reflect.DeepEqual(UserData("notes"), first) {
		t.Fatal("conflict changed stored data")
	}
	same, status := MergeUserData("notes", []byte(`{"base":[{"id":"a","text":"kept"}],"data":[{"id":"a","text":"kept"}]}`))
	if status != 200 || !reflect.DeepEqual(same, first) {
		t.Fatal("unchanged sync rewrote timestamp")
	}
}
func TestWorkspaceMergeRejectsDuplicateIDs(t *testing.T) {
	isolatedUserDataHome(t)
	_, status := MergeUserData("todos", []byte(`{"base":[],"data":[{"id":"x"},{"id":"x"}]}`))
	if status != http.StatusBadRequest {
		t.Fatalf("got %d", status)
	}
}
