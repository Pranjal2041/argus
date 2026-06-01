// Package fsvc is the broker's file service for the Files browser: it lists
// directories and serves file contents. It runs as the broker's user and reads
// whatever that user can; the tailnet is the trust boundary, same as the rest of
// the broker. Paths are platform-native absolute paths, and every listed entry
// carries its own absolute Path so clients never have to join paths themselves
// (that's how this stays correct across Windows `\` and Unix `/`).
package fsvc

import (
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// Entry is one directory member.
type Entry struct {
	Name    string `json:"name"`
	Path    string `json:"path"`           // absolute, platform-native
	IsDir   bool   `json:"isDir"`
	Size    int64  `json:"size"`
	MTime   int64  `json:"mtime"`          // unix seconds
	Mode    string `json:"mode"`           // e.g. "drwxr-xr-x"
	Symlink bool   `json:"symlink,omitempty"`
	Target  string `json:"target,omitempty"`
}

// ListResult is the response for /fs/list.
type ListResult struct {
	Path    string  `json:"path"`
	Entries []Entry `json:"entries"`
}

// HomeResult is the response for /fs/home: the client's starting points.
type HomeResult struct {
	Home  string   `json:"home"`
	Roots []string `json:"roots"` // "/" on Unix, drive letters on Windows
	Sep   string   `json:"sep"`   // path separator
}

// StatResult is the response for /fs/stat: a path resolved + classified on THIS
// host, so a terminal-clicked path can be routed into Files without the client
// guessing remote filesystem semantics (relative vs absolute, ~, $VAR, the OS
// separator).
type StatResult struct {
	Path   string `json:"path"`   // absolute, cleaned, platform-native
	Name   string `json:"name"`   // base name
	IsDir  bool   `json:"isDir"`
	Exists bool   `json:"exists"`
	Size   int64  `json:"size"`
}

// Stat resolves `path` (which may be relative, or start with ~ or $VAR) against
// `base` (the clicking session's working directory), cleans it to an absolute
// platform-native path, and reports whether it exists and is a directory. All
// resolution happens on the host that owns the path, so Windows `\` vs Unix `/`,
// symlinks, and the user's real $HOME/$VAR are handled correctly.
func Stat(path, base string) StatResult {
	p := strings.TrimSpace(path)
	// ~ and ~/… → the broker user's home.
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			p = home
		}
	} else if strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, p[2:])
		}
	}
	// $VAR / ${VAR} (the implicit-link detector matches these).
	if strings.Contains(p, "$") {
		p = os.ExpandEnv(p)
	}

	// Build resolution candidates, in priority order, then return the first that
	// exists (or the first as a best-effort path if none do).
	var cands []string
	rooted := strings.HasPrefix(p, "/") || strings.HasPrefix(p, `\`)
	base = strings.TrimSpace(base)
	switch {
	case filepath.IsAbs(p):
		cands = []string{p}
	case runtime.GOOS == "windows" && rooted:
		// On Windows the terminal's link detector matches `X:/path` starting at the
		// `/`, dropping the drive letter — so we receive a driveless-rooted path.
		// It's rooted on SOME drive: probe each drive root, then fall back to the cwd.
		for _, root := range systemRoots() {
			cands = append(cands, filepath.Join(root, p))
		}
		if base != "" {
			cands = append(cands, filepath.Join(base, p))
		}
	default: // relative → resolve against the session cwd
		if base != "" {
			cands = append(cands, filepath.Join(base, p))
		}
		cands = append(cands, p)
	}

	for _, c := range cands {
		c = filepath.Clean(c)
		if fi, err := os.Stat(c); err == nil {
			return StatResult{Path: c, Name: filepath.Base(c), IsDir: fi.IsDir(), Exists: true, Size: fi.Size()}
		}
	}
	best := filepath.Clean(cands[0])
	return StatResult{Path: best, Name: filepath.Base(best)}
}

// Home returns the user's home dir, the platform's filesystem roots, and the
// path separator.
func Home() HomeResult {
	home, _ := os.UserHomeDir()
	return HomeResult{Home: home, Roots: systemRoots(), Sep: string(os.PathSeparator)}
}

// List returns a directory's entries (directories first, then case-insensitive
// by name). An empty path returns the roots as directory entries.
func List(path string) (ListResult, error) {
	if strings.TrimSpace(path) == "" {
		roots := systemRoots()
		entries := make([]Entry, 0, len(roots))
		for _, r := range roots {
			e := Entry{Name: r, Path: r, IsDir: true}
			if fi, err := os.Stat(r); err == nil {
				e.MTime = fi.ModTime().Unix()
				e.Mode = fi.Mode().String()
			}
			entries = append(entries, e)
		}
		return ListResult{Path: "", Entries: entries}, nil
	}

	dirents, err := os.ReadDir(path)
	if err != nil {
		return ListResult{}, err
	}
	entries := make([]Entry, 0, len(dirents))
	for _, d := range dirents {
		full := filepath.Join(path, d.Name())
		e := Entry{Name: d.Name(), Path: full, IsDir: d.IsDir()}
		if d.Type()&os.ModeSymlink != 0 {
			e.Symlink = true
			if t, err := os.Readlink(full); err == nil {
				e.Target = t
			}
			if fi, err := os.Stat(full); err == nil { // resolve through the link
				e.IsDir = fi.IsDir()
			}
		}
		if info, err := d.Info(); err == nil {
			e.Size = info.Size()
			e.MTime = info.ModTime().Unix()
			e.Mode = info.Mode().String()
		}
		entries = append(entries, e)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir // directories first
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return ListResult{Path: path, Entries: entries}, nil
}

// ServeFile streams a file with Range support (large files + media streaming)
// and content-type sniffing, via http.ServeContent.
func ServeFile(w http.ResponseWriter, r *http.Request, path string) {
	if strings.TrimSpace(path) == "" {
		http.Error(w, "missing path", http.StatusBadRequest)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if fi.IsDir() {
		http.Error(w, "is a directory", http.StatusBadRequest)
		return
	}
	http.ServeContent(w, r, fi.Name(), fi.ModTime(), f) // Range + Content-Type
}

// Mkdir creates a single new directory (errors if it already exists).
func Mkdir(path string) error { return os.Mkdir(path, 0o755) }

// Remove deletes a file or a directory tree.
func Remove(path string) error { return os.RemoveAll(path) }

// Rename moves/renames from -> to.
func Rename(from, to string) error { return os.Rename(from, to) }

// Write atomically writes data to path (temp file in the same dir + rename), so a
// reader never sees a half-written file. Used for new files and editor saves.
func Write(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".ut-write-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}
