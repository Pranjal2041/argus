package gitsvc

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// fixtureRepo builds a real repo: two commits by two authors, a staged change,
// an unstaged change, and an untracked file.
func fixtureRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=Alice", "GIT_AUTHOR_EMAIL=alice@x.dev",
			"GIT_COMMITTER_NAME=Alice", "GIT_COMMITTER_EMAIL=alice@x.dev",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	git("init", "-b", "main")
	write("a.txt", "line one\nline two\n")
	git("add", "a.txt")
	git("commit", "-m", "first commit")
	write("a.txt", "line one\nline two\nline three\n")
	write("b.go", "package b\n")
	git("add", ".")
	git("-c", "user.name=Bob", "-c", "user.email=bob@x.dev", "commit", "-m", "second commit", "--author", "Bob <bob@x.dev>")
	// staged change
	write("b.go", "package b\n\nvar X = 1\n")
	git("add", "b.go")
	// unstaged change
	write("a.txt", "line one\nline two\nline three\nline four\n")
	// untracked
	write("new.md", "# new\n")
	return dir
}

func TestSummary(t *testing.T) {
	dir := fixtureRepo(t)
	s, err := GetSummary(dir)
	if err != nil {
		t.Fatal(err)
	}
	if s.Branch != "main" {
		t.Errorf("branch = %q", s.Branch)
	}
	var staged, unstaged, untracked int
	for _, f := range s.Files {
		if f.Untracked {
			untracked++
		}
		if f.Staged != "." && !f.Untracked {
			staged++
		}
		if f.Unstaged != "." && !f.Untracked {
			unstaged++
		}
	}
	if staged != 1 || unstaged != 1 || untracked != 1 {
		t.Errorf("staged=%d unstaged=%d untracked=%d files=%+v", staged, unstaged, untracked, s.Files)
	}
}

func TestDiffScopes(t *testing.T) {
	dir := fixtureRepo(t)
	for _, scope := range []string{"worktree", "staged", "head"} {
		out, err := GetDiff(dir, scope, "", "")
		if err != nil {
			t.Fatalf("%s: %v", scope, err)
		}
		if !strings.HasPrefix(string(out), "diff --git") {
			t.Errorf("%s diff doesn't start with diff --git: %q", scope, string(out)[:min(40, len(out))])
		}
	}
	// per-path filter
	out, err := GetDiff(dir, "worktree", "", "a.txt")
	if err != nil || !strings.Contains(string(out), "a.txt") || strings.Contains(string(out), "b.go") {
		t.Errorf("path filter failed: %v %q", err, string(out))
	}
}

func TestLogAndCommitDiff(t *testing.T) {
	dir := fixtureRepo(t)
	log, err := GetLog(dir, 10, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(log) != 2 {
		t.Fatalf("want 2 commits, got %d", len(log))
	}
	if log[0].Subject != "second commit" || log[0].Author != "Bob" {
		t.Errorf("head commit = %+v", log[0])
	}
	if len(log[0].Parents) != 1 || log[0].Parents[0] != log[1].Hash {
		t.Errorf("parents wiring wrong: %+v vs %s", log[0].Parents, log[1].Hash)
	}
	if len(log[1].Parents) != 0 {
		t.Errorf("root commit has parents: %+v", log[1].Parents)
	}
	// refs on HEAD include the branch
	found := false
	for _, r := range log[0].Refs {
		if r == "main" {
			found = true
		}
	}
	if !found {
		t.Errorf("HEAD refs missing main: %+v", log[0].Refs)
	}
	// commit-scope diff
	out, err := GetDiff(dir, "commit", log[0].Hash, "")
	if err != nil || !strings.Contains(string(out), "line three") {
		t.Errorf("commit diff: %v %q", err, string(out))
	}
}

func TestBlame(t *testing.T) {
	dir := fixtureRepo(t)
	lines, err := GetBlame(dir, "a.txt", "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 3 {
		t.Fatalf("want 3 blamed lines, got %d", len(lines))
	}
	// lines 1-2 from Alice's first commit, line 3 from Bob's second
	if lines[0].Author != "Alice" || lines[1].Author != "Alice" {
		t.Errorf("lines 1-2 authors: %s, %s", lines[0].Author, lines[1].Author)
	}
	if lines[2].Author != "Bob" || lines[2].Summary != "second commit" {
		t.Errorf("line 3 = %+v", lines[2])
	}
	if lines[0].Text != "line one" || lines[2].Text != "line three" {
		t.Errorf("texts: %q, %q", lines[0].Text, lines[2].Text)
	}
	if lines[0].N != 1 || lines[2].N != 3 {
		t.Errorf("line numbers: %d, %d", lines[0].N, lines[2].N)
	}
}

func TestShow(t *testing.T) {
	dir := fixtureRepo(t)
	out, err := GetShow(dir, "HEAD", "a.txt")
	if err != nil || string(out) != "line one\nline two\nline three\n" {
		t.Errorf("show: %v %q", err, string(out))
	}
}

func TestNotARepo(t *testing.T) {
	if _, err := GetSummary(t.TempDir()); err == nil {
		t.Error("expected error outside a repo")
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
