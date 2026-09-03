//go:build !windows

package recovery

import (
	"os/exec"
	"testing"
)

func TestPlatformProcessDirectoryUsesKernelOwnedCWD(t *testing.T) {
	directory := t.TempDir()
	cmd := exec.Command("sh", "-c", "sleep 5")
	cmd.Dir = directory
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	got, err := platformProcessDirectory(cmd.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	if !equivalentDirectory(got, directory) {
		t.Fatalf("process cwd = %q, want %q", got, directory)
	}
	got = authoritativePaneDirectory("/sandbox-visible-but-not-host-real", got)
	if !equivalentDirectory(got, directory) {
		t.Fatalf("captured pane directory = %q, want kernel cwd %q", got, directory)
	}
	if got := authoritativePaneDirectory("/terminal/fallback", ""); got != "/terminal/fallback" {
		t.Fatalf("unavailable process inspection fallback = %q", got)
	}
}
