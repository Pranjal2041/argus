package broker

import (
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"sort"
	"time"
)

// All workspace writers (Mac UI, CLI through the UI model, and Android) use
// this same three-way merge contract. Lists are maps by durable record ID,
// never offsets; conflicting edits/deletes are rejected, not timestamp-won.
func mergeWorkspaceValue(base, local, remote any, path string, conflicts *[]string) any {
	if reflect.DeepEqual(local, base) {
		return remote
	}
	if reflect.DeepEqual(remote, base) || reflect.DeepEqual(local, remote) {
		return local
	}
	if l, ok := local.(map[string]any); ok {
		if r, ok := remote.(map[string]any); ok {
			b, _ := base.(map[string]any)
			// Absence is deletion, not an empty object: do not resurrect records.
			if base != nil && b == nil {
				*conflicts = append(*conflicts, path)
				return remote
			}
			out := map[string]any{}
			keys := map[string]bool{}
			for k := range b {
				keys[k] = true
			}
			for k := range l {
				keys[k] = true
			}
			for k := range r {
				keys[k] = true
			}
			for k := range keys {
				v := mergeWorkspaceValue(b[k], l[k], r[k], path+"/"+k, conflicts)
				if v != nil {
					out[k] = v
				}
			}
			return out
		}
	}
	l, lok := local.([]any)
	r, rok := remote.([]any)
	b, bok := base.([]any)
	if lok && rok && (bok || base == nil) {
		lm, le := workspaceRecords(l)
		rm, re := workspaceRecords(r)
		bm, be := workspaceRecords(b)
		if le == nil && re == nil && be == nil {
			keys := map[string]bool{}
			for k := range bm {
				keys[k] = true
			}
			for k := range lm {
				keys[k] = true
			}
			for k := range rm {
				keys[k] = true
			}
			order := make([]string, 0, len(keys))
			for k := range keys {
				order = append(order, k)
			}
			sort.Strings(order)
			out := []any{}
			for _, k := range order {
				v := mergeWorkspaceValue(bm[k], lm[k], rm[k], path+"/"+k, conflicts)
				if v != nil {
					out = append(out, v)
				}
			}
			return out
		}
	}
	// Modification timestamps are metadata, not competing user content.
	if pathHasMetadataTimestamp(path) {
		ls, lok := local.(string)
		rs, rok := remote.(string)
		ld, le := time.Parse(time.RFC3339Nano, ls)
		rd, re := time.Parse(time.RFC3339Nano, rs)
		if lok && rok && le == nil && re == nil {
			if ld.After(rd) {
				return local
			}
			return remote
		}
	}
	*conflicts = append(*conflicts, path)
	return remote
}

func pathHasMetadataTimestamp(path string) bool {
	for _, suffix := range []string{"/editedAt", "/updatedAt"} {
		if len(path) >= len(suffix) && path[len(path)-len(suffix):] == suffix {
			return true
		}
	}
	return false
}
func workspaceRecords(items []any) (map[string]any, error) {
	out := map[string]any{}
	for _, value := range items {
		item, ok := value.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("workspace list contains a non-record")
		}
		id, _ := item["id"].(string)
		if id == "" || out[id] != nil {
			return nil, fmt.Errorf("workspace list requires unique nonempty IDs")
		}
		out[id] = value
	}
	return out, nil
}

// MergeUserData returns an authoritative envelope only after its atomic write.
// No base is safe for first sync: unrelated records merge, competing records
// produce a reviewable conflict. Existing legacy clients cannot silently replace
// a merge-protected collection through the old endpoint afterward.
func MergeUserData(key string, body []byte) ([]byte, int) {
	userDataMu.Lock()
	defer userDataMu.Unlock()
	var request struct {
		Base json.RawMessage `json:"base"`
		Data json.RawMessage `json:"data"`
	}
	if json.Unmarshal(body, &request) != nil || len(request.Base) == 0 || len(request.Data) == 0 {
		return []byte(`{"error":"base and data are required"}`), http.StatusBadRequest
	}
	var base, incoming []any
	if json.Unmarshal(request.Base, &base) != nil || json.Unmarshal(request.Data, &incoming) != nil || incoming == nil {
		return []byte(`{"error":"base and data must be record arrays"}`), http.StatusBadRequest
	}
	if _, err := workspaceRecords(base); err != nil {
		return []byte(`{"error":"invalid base records"}`), http.StatusBadRequest
	}
	if _, err := workspaceRecords(incoming); err != nil {
		return []byte(`{"error":"invalid incoming records"}`), http.StatusBadRequest
	}
	existing := readUserDataLocked(key)
	var remote []any = []any{}
	if len(existing) > 0 {
		env, ok := decodeUserDataEnvelope(existing)
		if !ok || json.Unmarshal(env.Data, &remote) != nil {
			return []byte(`{"error":"stored data is not a workspace collection"}`), http.StatusConflict
		}
	}
	conflicts := []string{}
	merged := mergeWorkspaceValue(base, incoming, remote, "", &conflicts)
	if len(conflicts) > 0 {
		sort.Strings(conflicts)
		response, _ := json.Marshal(map[string]any{"error": "conflict", "conflicts": conflicts, "current": remote})
		return response, http.StatusConflict
	}
	if reflect.DeepEqual(merged, remote) && UserDataMergeProtected(existing) {
		return existing, http.StatusOK
	}
	stamp := time.Now().UnixMilli()
	if old := userDataUpdatedAt(existing); stamp <= old {
		stamp = old + 1
	}
	response, err := json.Marshal(map[string]any{"updatedAt": stamp, "data": merged, "mergeVersion": 1})
	if err != nil {
		return []byte(`{"error":"encode failed"}`), http.StatusInternalServerError
	}
	if len(existing) > 0 {
		_ = backupUserDataBlobAt(key, existing, time.Now())
	}
	if err = writeFileAtomic(userDataPath(key), response, 0o600); err != nil {
		return []byte(`{"error":"persist failed"}`), http.StatusInternalServerError
	}
	return response, http.StatusOK
}

func UserDataMergeProtected(body []byte) bool {
	var value struct {
		Version int `json:"mergeVersion"`
	}
	_ = json.Unmarshal(body, &value)
	return value.Version >= 1
}
