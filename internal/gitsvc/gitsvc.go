// Package gitsvc serves READ-ONLY git views of a working directory for the Git
// panel: status summary, log, unified diffs, blame, and file-at-revision. It
// shells out to the `git` binary (present on every host, including Windows) with
// --no-optional-locks so it never takes index locks — a pure viewer, no mutations.
// The client renders the output (diff2html + highlight.js in a webview); this
// package only shapes git's output into JSON/plain text.
package gitsvc

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const cmdTimeout = 15 * time.Second

// A big range diff wedges the client renderer (diff2html builds DOM for every
// hunk SYNCHRONOUSLY on the webview main thread — 616 files froze it for 6s;
// bigger freezes indefinitely). Cap by FILE COUNT first (the real cost driver,
// like GitHub's "too many files"), then by bytes as a backstop — whichever hits
// first. diff2html handles ~50 files smoothly (<1s).
const maxDiffFiles = 50
const maxDiffBytes = 700 * 1024

func capDiff(b []byte) []byte {
	files, cut := 0, -1
	// find the byte offset of the (maxDiffFiles+1)-th "diff --git" (start of line)
	for i := 0; i+10 < len(b); i++ {
		if (i == 0 || b[i-1] == '\n') && string(b[i:i+11]) == "diff --git " {
			files++
			if files == maxDiffFiles+1 {
				cut = i
				break
			}
		}
	}
	byteCut := -1
	if len(b) > maxDiffBytes {
		byteCut = maxDiffBytes
		for byteCut > 0 && b[byteCut-1] != '\n' {
			byteCut--
		}
	}
	// take the earliest applicable cut
	end := len(b)
	truncated := ""
	if cut >= 0 {
		end = cut
		truncated = fmt.Sprintf("\n[diff truncated: showing the first %d of %d changed files — too large to render fully]\n", maxDiffFiles, countFiles(b))
	}
	if byteCut >= 0 && byteCut < end {
		end = byteCut
		truncated = fmt.Sprintf("\n[diff truncated at %d KB — too large to render fully]\n", maxDiffBytes/1024)
	}
	if truncated == "" {
		return b
	}
	out := make([]byte, 0, end+len(truncated))
	out = append(out, b[:end]...)
	out = append(out, truncated...)
	return out
}

func countFiles(b []byte) int {
	n := 0
	for i := 0; i < len(b); i++ {
		if (i == 0 || b[i-1] == '\n') && i+11 <= len(b) && string(b[i:i+11]) == "diff --git " {
			n++
		}
	}
	return n
}

// run executes git -C dir with the given args, returning stdout. Stderr rides the
// error so the client sees git's actual complaint ("not a git repository", …).
func run(dir string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), cmdTimeout)
	defer cancel()
	full := append([]string{"-C", dir, "--no-optional-locks"}, args...)
	cmd := exec.CommandContext(ctx, "git", full...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("%s", msg)
	}
	return out.Bytes(), nil
}

// FileChange is one changed path in the working tree / index.
type FileChange struct {
	Path      string `json:"path"`
	OrigPath  string `json:"origPath,omitempty"` // rename source, when renamed
	Staged    string `json:"staged"`             // index status letter ("M","A","D","R","." = none)
	Unstaged  string `json:"unstaged"`           // worktree status letter
	Untracked bool   `json:"untracked"`
}

// Summary is the Changes view's sidebar: branch state + changed files.
type Summary struct {
	Branch   string       `json:"branch"`
	Upstream string       `json:"upstream,omitempty"`
	Ahead    int          `json:"ahead"`
	Behind   int          `json:"behind"`
	Files    []FileChange `json:"files"`
	Stashes  int          `json:"stashes"`
	Root     string       `json:"root,omitempty"` // repo top-level: porcelain v2 paths are relative to THIS, not `dir`
}

// GetSummary parses `git status --porcelain=v2 --branch -z`.
func GetSummary(dir string) (*Summary, error) {
	out, err := run(dir, "status", "--porcelain=v2", "--branch", "-z")
	if err != nil {
		return nil, err
	}
	s := &Summary{Files: []FileChange{}}
	// The repo top-level: file paths below are relative to it, so a client can
	// map them to absolute tree paths even when `dir` is a subdirectory.
	if top, e := run(dir, "rev-parse", "--show-toplevel"); e == nil {
		s.Root = strings.TrimSpace(string(top))
	}
	// -z: NUL-terminated records; rename records carry a second NUL-separated path.
	recs := strings.Split(string(out), "\x00")
	for i := 0; i < len(recs); i++ {
		rec := recs[i]
		if rec == "" {
			continue
		}
		switch {
		case strings.HasPrefix(rec, "# branch.head "):
			s.Branch = strings.TrimPrefix(rec, "# branch.head ")
		case strings.HasPrefix(rec, "# branch.upstream "):
			s.Upstream = strings.TrimPrefix(rec, "# branch.upstream ")
		case strings.HasPrefix(rec, "# branch.ab "):
			// "# branch.ab +N -M"
			for _, f := range strings.Fields(strings.TrimPrefix(rec, "# branch.ab ")) {
				if v, err := strconv.Atoi(f[1:]); err == nil {
					if f[0] == '+' {
						s.Ahead = v
					} else {
						s.Behind = v
					}
				}
			}
		case strings.HasPrefix(rec, "1 "): // ordinary changed entry
			// 1 XY sub mH mI mW hH hI path
			parts := strings.SplitN(rec, " ", 9)
			if len(parts) == 9 {
				s.Files = append(s.Files, FileChange{
					Path: parts[8], Staged: statusLetter(parts[1][0]), Unstaged: statusLetter(parts[1][1]),
				})
			}
		case strings.HasPrefix(rec, "2 "): // rename/copy: path, then NUL, then origPath
			parts := strings.SplitN(rec, " ", 10)
			if len(parts) == 10 {
				fc := FileChange{Path: parts[9], Staged: statusLetter(parts[1][0]), Unstaged: statusLetter(parts[1][1])}
				if i+1 < len(recs) { // the rename source rides the NEXT NUL record
					fc.OrigPath = recs[i+1]
					i++
				}
				s.Files = append(s.Files, fc)
			}
		case strings.HasPrefix(rec, "? "): // untracked
			s.Files = append(s.Files, FileChange{Path: rec[2:], Staged: ".", Unstaged: ".", Untracked: true})
		}
	}
	if st, err := run(dir, "stash", "list", "--format=%gd"); err == nil {
		if t := strings.TrimSpace(string(st)); t != "" {
			s.Stashes = len(strings.Split(t, "\n"))
		}
	}
	return s, nil
}

func statusLetter(b byte) string {
	if b == '.' {
		return "."
	}
	return string(b)
}

// GetDiff returns a unified diff for a scope: worktree (unstaged), staged, head
// (worktree+index vs HEAD), a single commit, or a range (hash2 → hash, the
// two-commit compare). Optional path filter.
func GetDiff(dir, scope, hash, hash2, path string) ([]byte, error) {
	var args []string
	switch scope {
	case "", "worktree":
		args = []string{"diff", "--find-renames"}
	case "staged":
		args = []string{"diff", "--cached", "--find-renames"}
	case "head":
		args = []string{"diff", "HEAD", "--find-renames"}
	case "commit":
		if hash == "" {
			return nil, fmt.Errorf("commit scope needs hash")
		}
		// %n between commits never applies (single commit); --format= drops the
		// message so the output is pure diff for the renderer.
		args = []string{"show", hash, "--format=", "--find-renames"}
	case "range":
		if hash == "" || hash2 == "" {
			return nil, fmt.Errorf("range scope needs hash and hash2")
		}
		args = []string{"diff", hash2, hash, "--find-renames"} // changes from hash2 → hash
	default:
		return nil, fmt.Errorf("bad scope %q", scope)
	}
	if path != "" {
		args = append(args, "--", path)
	}
	out, err := run(dir, args...)
	return capDiff(out), err
}

// Commit is one log entry.
type Commit struct {
	Hash    string   `json:"hash"`
	Parents []string `json:"parents"`
	Author  string   `json:"author"`
	Email   string   `json:"email"`
	At      int64    `json:"at"`
	Subject string   `json:"subject"`
	Refs    []string `json:"refs,omitempty"`
}

// GetLog returns up to n commits (skip for paging), with decorations. From HEAD by
// default; all=true walks EVERY ref (GitKraken-style whole-repo graph) in topo order
// so the client's lane layout stays clean.
func GetLog(dir string, n, skip int, all bool) ([]Commit, error) {
	if n <= 0 || n > 1000 {
		n = 100
	}
	args := []string{"log",
		"--pretty=format:%H\x1f%P\x1f%an\x1f%ae\x1f%at\x1f%s\x1f%D\x1e",
		"-n", strconv.Itoa(n), "--skip", strconv.Itoa(skip)}
	if all {
		args = append(args, "--all", "--topo-order")
	}
	out, err := run(dir, args...)
	if err != nil {
		return nil, err
	}
	var commits []Commit
	for _, rec := range strings.Split(string(out), "\x1e") {
		rec = strings.TrimLeft(rec, "\n")
		if rec == "" {
			continue
		}
		f := strings.Split(rec, "\x1f")
		if len(f) < 7 {
			continue
		}
		at, _ := strconv.ParseInt(f[4], 10, 64)
		c := Commit{Hash: f[0], Author: f[2], Email: f[3], At: at, Subject: f[5]}
		if f[1] != "" {
			c.Parents = strings.Fields(f[1])
		}
		if f[6] != "" {
			for _, r := range strings.Split(f[6], ", ") {
				r = strings.TrimPrefix(r, "HEAD -> ")
				if r != "" && r != "HEAD" {
					c.Refs = append(c.Refs, r)
				}
			}
		}
		commits = append(commits, c)
	}
	return commits, nil
}

// BlameLine is one line's attribution + content.
type BlameLine struct {
	N       int    `json:"n"`
	Hash    string `json:"hash"`
	Short   string `json:"short"`
	Author  string `json:"author"`
	At      int64  `json:"at"`
	Summary string `json:"summary"`
	Text    string `json:"text"`
}

// GetBlame parses `git blame --porcelain` for path (at ref, or the working tree
// when ref is empty).
func GetBlame(dir, path, ref string) ([]BlameLine, error) {
	args := []string{"blame", "--porcelain"}
	if ref != "" {
		args = append(args, ref)
	}
	args = append(args, "--", path)
	out, err := run(dir, args...)
	if err != nil {
		return nil, err
	}
	// Porcelain: header "hash origLine finalLine [group]" then key/value lines the
	// FIRST time a commit appears (author, author-time, summary, …), then "\t<text>"
	// per line. Later lines from the same commit repeat only the header + text.
	type meta struct {
		author, summary string
		at              int64
	}
	metas := map[string]*meta{}
	var lines []BlameLine
	var cur string  // current commit hash
	var curN int    // current final line number
	for _, ln := range strings.Split(string(out), "\n") {
		if ln == "" {
			continue
		}
		if ln[0] == '\t' { // the content line
			m := metas[cur]
			if m == nil {
				m = &meta{}
			}
			lines = append(lines, BlameLine{
				N: curN, Hash: cur, Short: short(cur),
				Author: m.author, At: m.at, Summary: m.summary,
				Text: ln[1:],
			})
			continue
		}
		f := strings.Fields(ln)
		if len(f) >= 3 && len(f[0]) == 40 && isHex(f[0]) {
			cur = f[0]
			if v, err := strconv.Atoi(f[2]); err == nil {
				curN = v
			}
			if metas[cur] == nil {
				metas[cur] = &meta{}
			}
			continue
		}
		m := metas[cur]
		if m == nil {
			continue
		}
		switch {
		case strings.HasPrefix(ln, "author "):
			m.author = strings.TrimPrefix(ln, "author ")
		case strings.HasPrefix(ln, "author-time "):
			m.at, _ = strconv.ParseInt(strings.TrimPrefix(ln, "author-time "), 10, 64)
		case strings.HasPrefix(ln, "summary "):
			m.summary = strings.TrimPrefix(ln, "summary ")
		}
	}
	return lines, nil
}

// GetShow returns a file's content at a revision.
func GetShow(dir, ref, path string) ([]byte, error) {
	if ref == "" {
		ref = "HEAD"
	}
	return run(dir, "show", ref+":"+path)
}

func short(h string) string {
	if len(h) >= 8 {
		return h[:8]
	}
	return h
}

func isHex(s string) bool {
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
