package labsvc

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// The hub shows a run's SUBSTANCE — the parameters file, the code diff, the
// log, the environment freeze — not just its status line. These helpers expose
// the files the wrapper itself wrote, and nothing else: the name is validated
// against the small set of places run files can live, so the route cannot be
// used to read arbitrary paths.

// RunFileInfo is one stored file of a run.
type RunFileInfo struct {
	Name string `json:"name"` // relative, slash-separated: "files/conf.yaml", "log.txt"
	Size int64  `json:"size"`
}

// RunFiles lists what the wrapper stored for a run: the log, the snapshot
// pieces, and everything under files/.
func (s *Store) RunFiles(set, run string) []RunFileInfo {
	rd := s.RunDir(set, run)
	var out []RunFileInfo
	add := func(rel string) {
		if fi, err := os.Stat(filepath.Join(rd, filepath.FromSlash(rel))); err == nil && !fi.IsDir() {
			out = append(out, RunFileInfo{Name: rel, Size: fi.Size()})
		}
	}
	add("log.txt")
	add("snapshot/diff.patch")
	add("snapshot/untracked.tar.gz")
	if ents, err := os.ReadDir(filepath.Join(rd, "files")); err == nil {
		for _, e := range ents {
			if !e.IsDir() {
				add("files/" + e.Name())
			}
		}
	}
	return out
}

// RunFile resolves a stored run file by its relative name, allowing only the
// locations the wrapper writes.
func (s *Store) RunFile(set, run, name string) (string, error) {
	clean := path.Clean(name)
	allowed := clean == "log.txt" ||
		clean == "snapshot/diff.patch" ||
		clean == "snapshot/untracked.tar.gz" ||
		(strings.HasPrefix(clean, "files/") && !strings.Contains(clean, "..") && path.Dir(clean) == "files")
	if !allowed {
		return "", fmt.Errorf("no such run file %q", name)
	}
	p := filepath.Join(s.RunDir(set, run), filepath.FromSlash(clean))
	if _, err := os.Stat(p); err != nil {
		return "", err
	}
	return p, nil
}
