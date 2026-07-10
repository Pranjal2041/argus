package labsvc

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// The hub machine keeps a permanent mirror of every lab store it can see
// (LAB-DESIGN.md, Storage and syncing): once mirrored, records survive the
// machine that produced them going away. The mirror holds each set's latest
// brief (a derived view, overwritten) and every event (the record, append-
// only and idempotent by event id). Nothing in the mirror is ever removed.

func (s *Store) mirrorSetDir(machine, set string) string {
	return filepath.Join(s.root, "mirror", machine, "sets", set)
}

// WriteMirrorBrief stores the latest brief JSON seen for machine/set.
func (s *Store) WriteMirrorBrief(machine, set string, brief []byte) error {
	dir := s.mirrorSetDir(machine, set)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(dir, ".tmp-brief")
	if err := os.WriteFile(tmp, brief, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, "brief.json"))
}

// WriteMirrorEvents adds events not yet mirrored for machine/set (run may be
// empty for set-level events). Returns how many were new.
func (s *Store) WriteMirrorEvents(machine, set, run string, evs []Event) (int, error) {
	dir := s.mirrorSetDir(machine, set)
	if run != "" {
		dir = filepath.Join(dir, "runs", run)
	}
	evDir := filepath.Join(dir, "events")
	if err := os.MkdirAll(evDir, 0o755); err != nil {
		return 0, err
	}
	added := 0
	for _, e := range evs {
		if e.ID == "" {
			continue
		}
		final := filepath.Join(evDir, e.ID+".json")
		if _, err := os.Stat(final); err == nil {
			continue // already mirrored
		}
		b, err := json.MarshalIndent(e, "", " ")
		if err != nil {
			continue
		}
		tmp := filepath.Join(evDir, ".tmp-"+e.ID)
		if err := os.WriteFile(tmp, b, 0o644); err != nil {
			return added, err
		}
		if err := os.Rename(tmp, final); err != nil {
			return added, err
		}
		added++
	}
	return added, nil
}

// MirroredBrief is one set as last seen from one machine.
type MirroredBrief struct {
	Machine string          `json:"machine"`
	Set     string          `json:"set"`
	Updated string          `json:"updated"` // when the mirror last wrote it
	Brief   json.RawMessage `json:"brief"`
}

// ReadMirror returns every mirrored set's latest brief, for the hub to show
// machines that are offline right now.
func (s *Store) ReadMirror() ([]MirroredBrief, error) {
	base := filepath.Join(s.root, "mirror")
	machines, err := os.ReadDir(base)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []MirroredBrief
	for _, m := range machines {
		if !m.IsDir() {
			continue
		}
		setsDir := filepath.Join(base, m.Name(), "sets")
		sets, err := os.ReadDir(setsDir)
		if err != nil {
			continue
		}
		for _, st := range sets {
			if !st.IsDir() {
				continue
			}
			bp := filepath.Join(setsDir, st.Name(), "brief.json")
			b, err := os.ReadFile(bp)
			if err != nil || !json.Valid(b) {
				continue
			}
			mb := MirroredBrief{Machine: m.Name(), Set: st.Name(), Brief: b}
			if fi, err := os.Stat(bp); err == nil {
				mb.Updated = fi.ModTime().UTC().Format(time.RFC3339)
			}
			out = append(out, mb)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Machine != out[j].Machine {
			return out[i].Machine < out[j].Machine
		}
		return out[i].Set < out[j].Set
	})
	return out, nil
}

// MirrorPeersOverride parses UT_LAB_MIRROR_PEERS ("name=http://host:port,…"),
// the test hook that stands in for mesh discovery.
func MirrorPeersOverride() map[string]string {
	v := os.Getenv("UT_LAB_MIRROR_PEERS")
	if v == "" {
		return nil
	}
	out := map[string]string{}
	for _, part := range strings.Split(v, ",") {
		if name, url, ok := strings.Cut(strings.TrimSpace(part), "="); ok && name != "" && url != "" {
			out[name] = url
		}
	}
	return out
}
