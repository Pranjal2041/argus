package fsvc

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// tree builds base/{alpha/{one.txt,two/}, beta.txt} and returns base.
func tree(t *testing.T) string {
	t.Helper()
	base := t.TempDir()
	if err := os.MkdirAll(filepath.Join(base, "alpha", "two"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{filepath.Join("alpha", "one.txt"), "beta.txt"} {
		if err := os.WriteFile(filepath.Join(base, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return base
}

func TestStatAbsolute(t *testing.T) {
	base := tree(t)
	s := Stat(filepath.Join(base, "alpha"), "")
	if !s.Exists || !s.IsDir || s.Path != filepath.Join(base, "alpha") || s.Name != "alpha" {
		t.Fatalf("got %+v", s)
	}
	f := Stat(filepath.Join(base, "beta.txt"), "")
	if !f.Exists || f.IsDir || f.Size != 1 {
		t.Fatalf("got %+v", f)
	}
}

func TestStatRelativeAgainstBase(t *testing.T) {
	base := tree(t)
	for _, rel := range []string{"alpha", "alpha/two", "./alpha", "alpha/"} {
		s := Stat(rel, base)
		if !s.Exists || !s.IsDir {
			t.Fatalf("Stat(%q, base): got %+v", rel, s)
		}
	}
	if s := Stat("..", filepath.Join(base, "alpha")); !s.Exists || s.Path != base {
		t.Fatalf("Stat(.., alpha): got %+v", s)
	}
}

func TestStatBaseWinsOverProcessCwd(t *testing.T) {
	base := tree(t)
	other := t.TempDir()
	if err := os.Mkdir(filepath.Join(other, "alpha"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(other) // "alpha" also exists in the process cwd
	if s := Stat("alpha", base); s.Path != filepath.Join(base, "alpha") {
		t.Fatalf("base should win over cwd: got %+v", s)
	}
	// no base → the cwd fallback, still reported as an absolute path
	wd, err := os.Getwd() // not `other`: on macOS the tempdir is behind a symlink
	if err != nil {
		t.Fatal(err)
	}
	if s := Stat("alpha", ""); s.Path != filepath.Join(wd, "alpha") || !s.Exists {
		t.Fatalf("cwd fallback: got %+v", s)
	}
}

func TestStatTilde(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	if s := Stat("~", ""); !s.Exists || s.Path != home {
		t.Fatalf("Stat(~): got %+v", s)
	}
	// ~ beats any base
	if s := Stat("~", "/tmp"); s.Path != home {
		t.Fatalf("Stat(~, /tmp): got %+v", s)
	}
	if s := Stat("~/", ""); s.Path != home {
		t.Fatalf("Stat(~/): got %+v", s)
	}
	// ~bob is NOT this user's home
	if s := Stat("~bob-does-not-exist", ""); s.Exists {
		t.Fatalf("Stat(~bob): got %+v", s)
	}
}

func TestStatEnvVar(t *testing.T) {
	base := tree(t)
	t.Setenv("UT_FSVC_TEST_DIR", base)
	if s := Stat("$UT_FSVC_TEST_DIR/alpha", ""); !s.Exists || s.Path != filepath.Join(base, "alpha") {
		t.Fatalf("got %+v", s)
	}
	if s := Stat("${UT_FSVC_TEST_DIR}/beta.txt", ""); !s.Exists || s.IsDir {
		t.Fatalf("got %+v", s)
	}
}

func TestStatMissingIsBestEffort(t *testing.T) {
	base := tree(t)
	s := Stat("nope/missing", base)
	if s.Exists {
		t.Fatalf("got %+v", s)
	}
	if want := filepath.Join(base, "nope", "missing"); s.Path != want {
		t.Fatalf("best-effort path: got %q want %q", s.Path, want)
	}
}

func TestListAbsolute(t *testing.T) {
	base := tree(t)
	res, err := List(base, "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Path != base || len(res.Entries) != 2 {
		t.Fatalf("got %+v", res)
	}
	// dirs first
	if res.Entries[0].Name != "alpha" || !res.Entries[0].IsDir || res.Entries[1].Name != "beta.txt" {
		t.Fatalf("got %+v", res.Entries)
	}
	// every entry carries its absolute path
	if res.Entries[0].Path != filepath.Join(base, "alpha") {
		t.Fatalf("got %q", res.Entries[0].Path)
	}
}

func TestListRelativeAgainstBase(t *testing.T) {
	base := tree(t)
	res, err := List("alpha", base)
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(base, "alpha"); res.Path != want {
		t.Fatalf("resolved path: got %q want %q", res.Path, want)
	}
	if len(res.Entries) != 2 || res.Entries[1].Path != filepath.Join(base, "alpha", "one.txt") {
		t.Fatalf("got %+v", res.Entries)
	}
	up, err := List("..", filepath.Join(base, "alpha"))
	if err != nil || up.Path != base {
		t.Fatalf("List(..): %v %+v", err, up)
	}
}

func TestListTildeAndEnv(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("no home dir")
	}
	res, err := List("~", "")
	if err != nil {
		t.Fatal(err)
	}
	if res.Path != home {
		t.Fatalf("got %q want %q", res.Path, home)
	}
	base := tree(t)
	t.Setenv("UT_FSVC_TEST_DIR", base)
	if res, err := List("$UT_FSVC_TEST_DIR/alpha", ""); err != nil || res.Path != filepath.Join(base, "alpha") {
		t.Fatalf("%v %+v", err, res)
	}
}

func TestListEmptyPathIsRoots(t *testing.T) {
	res, err := List("", "ignored-base")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Entries) == 0 || res.Path != "" {
		t.Fatalf("got %+v", res)
	}
	if runtime.GOOS != "windows" && res.Entries[0].Path != "/" {
		t.Fatalf("got %+v", res.Entries)
	}
}

func TestListErrors(t *testing.T) {
	base := tree(t)
	if _, err := List("does-not-exist", base); err == nil {
		t.Fatal("want error for a missing dir")
	}
	if _, err := List("beta.txt", base); err == nil {
		t.Fatal("want error when listing a file")
	}
}
