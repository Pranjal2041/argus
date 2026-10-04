package toolcommand

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestStalledCandidateCannotBlockLaterExecutableOrRepeatedCalls(t *testing.T) {
	root := t.TempDir()
	first, second := filepath.Join(root, "unavailable"), filepath.Join(root, "available")
	t.Setenv("PATH", strings.Join([]string{first, second}, string(os.PathListSeparator)))
	r := newResolver()
	r.wait = 10 * time.Millisecond
	r.warn = func(string, ...any) {}
	blocked := make(chan struct{})
	defer close(blocked)
	var probes atomic.Int32
	r.check = func(path string) (string, error) {
		if filepath.Dir(path) == first {
			probes.Add(1)
			<-blocked
			return "", exec.ErrNotFound
		}
		return path, nil
	}
	// Exercise distinct tools, not just the incident's executable name.
	for _, tool := range []string{"session-tool", "process-inspector"} {
		for i := 0; i < 20; i++ {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			got, err := r.lookPath(ctx, tool)
			cancel()
			if err != nil || got != filepath.Join(second, tool) {
				t.Fatalf("lookup %q = %q, %v", tool, got, err)
			}
		}
	}
	if got := probes.Load(); got != 2 {
		t.Fatalf("blocked candidates were probed %d times, want 2", got)
	}
}

func TestHealthyPrecedenceAndSearchConfigurationChanges(t *testing.T) {
	root := t.TempDir()
	first, second := filepath.Join(root, "first"), filepath.Join(root, "second")
	r := newResolver()
	r.check = func(path string) (string, error) { return path, nil }
	for _, dirs := range [][]string{{first, second}, {second, first}} {
		t.Setenv("PATH", strings.Join(dirs, string(os.PathListSeparator)))
		got, err := r.lookPath(context.Background(), "tool")
		if err != nil || got != filepath.Join(dirs[0], "tool") {
			t.Fatalf("precedence: %q, %v", got, err)
		}
	}
}

func TestDeadlineIncludesExplicitExecutableLookupWithoutFallback(t *testing.T) {
	r := newResolver()
	r.warn = func(string, ...any) {}
	blocked := make(chan struct{})
	defer close(blocked)
	var probes atomic.Int32
	r.check = func(string) (string, error) {
		probes.Add(1)
		<-blocked
		return "", exec.ErrNotFound
	}
	path := filepath.Join(t.TempDir(), "exact-tool")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	cmd := r.commandContext(ctx, path)
	if err := cmd.Run(); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Run = %v, want deadline", err)
	}
	if probes.Load() != 1 {
		t.Fatal("an explicit executable must not fall back to a different path")
	}
}

func TestPendingFilesystemProbesRemainBounded(t *testing.T) {
	r := newResolver()
	r.wait = time.Millisecond
	r.warn = func(string, ...any) {}
	blocked := make(chan struct{})
	defer close(blocked)
	var probes atomic.Int32
	r.check = func(string) (string, error) {
		probes.Add(1)
		<-blocked
		return "", exec.ErrNotFound
	}
	for i := 0; i < maxProbes*3; i++ {
		_, _ = r.probe(context.Background(), filepath.Join(t.TempDir(), "tool"))
	}
	if got := probes.Load(); got != maxProbes {
		t.Fatalf("started %d blocked probes, limit is %d", got, maxProbes)
	}
}

func TestRelativePATHIsNeverAServiceToolSource(t *testing.T) {
	t.Setenv("PATH", "."+string(os.PathListSeparator)+"relative-bin")
	r := newResolver()
	r.check = func(path string) (string, error) {
		if !filepath.IsAbs(path) {
			t.Errorf("attempted relative PATH candidate %q", path)
		}
		return "", exec.ErrNotFound
	}
	if _, err := r.lookPath(context.Background(), "not-installed"); err == nil {
		t.Fatal("unexpected executable")
	}
}

func TestResolvedCommandPreservesArgumentsAndEnvironment(t *testing.T) {
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	r := newResolver()
	argument := "literal spaces; $value 'quotes' λ"
	cmd := r.commandContext(context.Background(), path, "-test.run=^TestCommandHelperProcess$", "--", argument)
	cmd.Env = append(os.Environ(), "TOOLCOMMAND_TEST_CHILD=1", "TOOLCOMMAND_TEST_VALUE=preserved")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("resolved command: %v\n%s", err, output)
	}
	if cmd.Path != path || cmd.Args[0] != path || !strings.Contains(string(output), "preserved|"+argument) {
		t.Fatalf("command metadata changed: %#v", cmd.Args)
	}
}

func TestCommandHelperProcess(t *testing.T) {
	if os.Getenv("TOOLCOMMAND_TEST_CHILD") == "1" {
		fmt.Print(os.Getenv("TOOLCOMMAND_TEST_VALUE") + "|" + os.Args[len(os.Args)-1])
	}
}

func TestExplicitExecutableIsRevalidatedAfterRemoval(t *testing.T) {
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	r := newResolver()
	available := true
	r.check = func(candidate string) (string, error) {
		if available {
			return candidate, nil
		}
		return "", exec.ErrNotFound
	}
	if _, err := r.lookPath(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	available = false
	if _, err := r.lookPath(context.Background(), path); err == nil {
		t.Fatal("removed explicit executable was still considered available")
	}
}
