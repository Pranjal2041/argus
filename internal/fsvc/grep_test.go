package fsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func grepFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write := func(rel, content string) {
		p := filepath.Join(dir, rel)
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("a.py", "import os\ndef reward(x):\n    return x * 2  # TODO tune\n")
	write("sub/b.go", "package sub\n// reward helper\nfunc Reward() int { return 42 }\n")
	write("node_modules/dep/c.js", "var reward = 999;\n") // must be ignored
	write("bin.dat", "abc\x00reward\x00def")             // binary, must be skipped
	return dir
}

// The walk fallback is exercised directly so the test is independent of ripgrep.
func TestGrepWalk(t *testing.T) {
	dir := grepFixture(t)
	res := GrepResult{Root: dir, Matches: []GrepMatch{}}
	grepWalk(dir, "reward", false, &res)
	// expect a.py:2, a.py? (only line 2 has reward), sub/b.go two lines — NOT node_modules, NOT binary
	var paths []string
	for _, m := range res.Matches {
		paths = append(paths, filepath.Base(m.Path)+":"+itoa(m.Line))
		if strings.Contains(m.Path, "node_modules") {
			t.Errorf("matched inside node_modules: %s", m.Path)
		}
		if strings.Contains(m.Path, "bin.dat") {
			t.Errorf("matched inside binary file: %s", m.Path)
		}
	}
	if len(res.Matches) < 2 {
		t.Fatalf("want >=2 matches (a.py + b.go), got %d: %v", len(res.Matches), paths)
	}
	// case-insensitivity: "reward" should catch "Reward()" in b.go
	found := false
	for _, m := range res.Matches {
		if strings.Contains(m.Path, "b.go") {
			found = true
		}
	}
	if !found {
		t.Errorf("case-insensitive match missed Reward() in b.go: %v", paths)
	}
}

func TestGrepRegex(t *testing.T) {
	dir := grepFixture(t)
	res := GrepResult{Root: dir, Matches: []GrepMatch{}}
	grepWalk(dir, `def \w+\(`, true, &res)
	if len(res.Matches) != 1 || !strings.Contains(res.Matches[0].Path, "a.py") {
		t.Fatalf("regex want 1 match in a.py, got %d: %+v", len(res.Matches), res.Matches)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
