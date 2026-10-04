//go:build !windows

package tmux

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func TestUnavailableSocketRequiresExactConnectionError(t *testing.T) {
	for _, tc := range []struct{ message, want string }{
		{"error connecting to /tmp/space here/ut (No such file or directory)", "/tmp/space here/ut"},
		{"error connecting to /tmp/ut (Connection refused)", "/tmp/ut"},
		{"no server running on /tmp/ut\n", "/tmp/ut"},
		{"error connecting to /tmp/ut (Permission denied)", ""},
		{"no server running on relative-path", ""},
		{"other failure: no server running on /tmp/ut", ""},
		{"no server running on /tmp/ut\ninjected", ""},
	} {
		err := &exec.ExitError{Stderr: []byte(tc.message)}
		if got := unavailableSocket(err); got != tc.want {
			t.Errorf("%q: got %q, want %q", tc.message, got, tc.want)
		}
	}
}

func TestSocketOwnersRequireExactEndpointUserAndProcess(t *testing.T) {
	output := "p101\nctmux\nu501\nf6\nn/tmp/a/ut\nf7\nn/tmp/a/ut\n" +
		"p102\nctmux\nu501\nf6\nn/tmp/b/ut\n" +
		"p103\nctmux\nu502\nf6\nn/tmp/a/ut\n" +
		"p104\ncunrelated\nu501\nf6\nn/tmp/a/ut\n" +
		"p105\nctmux\nu501\nf6\nn->0x1234\n" +
		"p106\nctmux: server\nu501\nf6\nn/tmp/a/ut\n"
	if got := parseSocketOwners(output, "/tmp/a/ut", 501); !reflect.DeepEqual(got, []int{101, 106}) {
		t.Fatalf("owners = %v", got)
	}
}

func TestSocketRecoveryHonorsCancelledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := recoverSocket(ctx, "/tmp/not-a-server"); err == nil {
		t.Fatal("cancelled recovery must not report authoritative absence")
	}
}

func TestSocketRecoveryRefusesUncertainOrAmbiguousOwnership(t *testing.T) {
	for _, script := range []string{
		"echo 'process scan failed' >&2; exit 2\n",
		"echo 'partial process scan' >&2; exit 0\n",
		fmt.Sprintf("printf 'p101\\nctmux\\nu%d\\nn/tmp/uncertain-ut\\np102\\nctmux\\nu%d\\nn/tmp/uncertain-ut\\n'\n", os.Geteuid(), os.Geteuid()),
	} {
		t.Run(strconv.Itoa(len(script)), func(t *testing.T) {
			bin := t.TempDir()
			if err := os.WriteFile(filepath.Join(bin, "lsof"), []byte("#!/bin/sh\n"+script), 0o700); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", bin)
			if _, err := recoverSocket(context.Background(), "/tmp/uncertain-ut"); err == nil {
				t.Fatal("uncertain ownership must be an error, not empty or recovered")
			}
		})
	}
}

func TestSocketDirectoryRefusesSymlinksAndSharedPermissions(t *testing.T) {
	base := t.TempDir()
	shared := filepath.Join(base, "shared")
	if err := os.Mkdir(shared, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "link")
	if err := os.Symlink(shared, link); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{shared, link} {
		if err := ensureSocketDirectory(filepath.Join(dir, "server")); err == nil {
			t.Fatalf("accepted unsafe directory %s", dir)
		}
	}
}

// These are real independent servers, with no user config and no connection to
// the user's normal socket. Cleanup knows the exact fixture PID even if a test
// fails while its socket is missing.
func recoveryServerFixture(t *testing.T, socket string) (string, int, func(...string) string) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	if _, err := exec.LookPath("lsof"); err != nil {
		t.Skip("lsof not installed")
	}
	run := func(args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "tmux", append([]string{"-L", socket}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("tmux %v: %s: %v", args, out, err)
		}
		return strings.TrimSpace(string(out))
	}
	run("-f", "/dev/null", "new-session", "-d", "-s", "kept", "printf 'original-pane-survives\\n'; exec /bin/sh")
	run("set-option", "-g", "default-shell", "/bin/sh")
	pid, err := strconv.Atoi(run("display-message", "-p", "#{pid}"))
	if err != nil {
		t.Fatal(err)
	}
	path := run("display-message", "-p", "#{socket_path}")
	t.Cleanup(func() {
		// The fixture is never restarted; this PID is the server this test made.
		_ = os.Mkdir(filepath.Dir(path), 0o700)
		_ = syscall.Kill(pid, syscall.SIGUSR1)
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		// Signal exit directly: no missing-socket cleanup can spawn a server.
		_ = syscall.Kill(pid, syscall.SIGTERM)
		_ = exec.CommandContext(ctx, "tmux", "-L", socket, "kill-server").Run()
	})
	return path, pid, run
}

func recoveryTempDir(t *testing.T) {
	t.Helper()
	// Keep UNIX-domain paths below sockaddr_un's length limit on macOS.
	dir, err := os.MkdirTemp("/tmp", "ut-recovery-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	t.Setenv("TMUX_TMPDIR", dir)
}

func TestSocketLossRecoversOriginalSessionsAcrossProviderRestart(t *testing.T) {
	for _, removeParent := range []bool{false, true} {
		t.Run(fmt.Sprintf("remove-parent-%v", removeParent), func(t *testing.T) {
			recoveryTempDir(t)
			path, _, run := recoveryServerFixture(t, "recovery")
			before := testInventory(t, NewProvider("recovery"))[0]
			pane := run("display-message", "-p", "#{pid}:#{pane_pid}:#{pane_id}")
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if removeParent {
				if err := os.Remove(filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
			}
			// A new Provider has no cached PID or prior inventory: cold recovery.
			var wg sync.WaitGroup
			for range 6 {
				wg.Go(func() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					list, err := NewProvider("recovery").ListInventory(ctx)
					if err != nil || len(list) != 1 || list[0].LineageID != before.LineageID || list[0].ID != before.ID {
						t.Errorf("lost original session: list=%+v err=%v", list, err)
					}
				})
			}
			wg.Wait()
			if after := run("display-message", "-p", "#{pid}:#{pane_pid}:#{pane_id}"); after != pane {
				t.Fatalf("server/pane process changed: %s -> %s", pane, after)
			}
			if history := run("capture-pane", "-p", "-S", "-"); !strings.Contains(history, "original-pane-survives") {
				t.Fatalf("original terminal history lost: %q", history)
			}
		})
	}
}

func TestCreationRecoversExistingServerAndCannotReplaceIt(t *testing.T) {
	recoveryTempDir(t)
	path, _, _ := recoveryServerFixture(t, "recovery")
	_, _, other := recoveryServerFixture(t, "unrelated")
	otherBefore := other("display-message", "-p", "#{pid}:#{pane_pid}:#{session_created}")
	before := testInventory(t, NewProvider("recovery"))[0]
	for name, create := range map[string]func() error{
		"visible": func() error { return CreateSession("recovery", "visible", "") },
		"shell":   func() error { return CreateAgentShell("recovery", "shell", "") },
		"spawn":   func() error { return SpawnSession("recovery", "spawn", "", "sleep 60", 0) },
	} {
		t.Run(name, func(t *testing.T) {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if err := create(); err != nil {
				t.Fatal(err)
			}
			kept := testInventory(t, NewProvider("recovery"))[0]
			if kept.Name != "kept" || kept.LineageID != before.LineageID {
				t.Fatalf("creation replaced original server: %+v", kept)
			}
		})
	}
	args, _, err := sessionCreationArgs("recovery", "must-not-exist", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("tmux", tmuxArgs("recovery", args...)...).CombinedOutput(); err == nil {
		t.Fatalf("creation started a replacement after preflight: %s", out)
	}
	list := testInventory(t, NewProvider("recovery"))
	if len(list) != 4 || list[0].LineageID != before.LineageID {
		t.Fatalf("unexpected inventory after creation race: %+v", list)
	}
	if got := other("display-message", "-p", "#{pid}:#{pane_pid}:#{session_created}"); got != otherBefore {
		t.Fatalf("unrelated server changed: %s -> %s", otherBefore, got)
	}
}

func TestCreationRefusesFailedInventory(t *testing.T) {
	p := inventoryToolFixture(t, "case \"$*\" in *list-sessions*) echo 'unavailable' >&2; exit 2;; *) exit 0;; esac\n")
	for _, create := range []func() error{
		func() error { return p.Create("new", "") },
		func() error { return p.CreateAgentShell("new", "") },
		func() error { return p.Spawn("new", "", "true", 0) },
	} {
		if err := create(); err == nil {
			t.Fatal("creation proceeded after unavailable inventory")
		}
	}
}

func TestEmptyLiveServerRemainsAuthoritativeAndCannotBeReplaced(t *testing.T) {
	recoveryTempDir(t)
	_, pid, run := recoveryServerFixture(t, "empty")
	run("set-option", "-g", "exit-empty", "off")
	run("kill-session", "-t", "kept")
	if list := testInventory(t, NewProvider("empty")); len(list) != 0 {
		t.Fatalf("empty live server inventory = %+v", list)
	}
	args, _, err := sessionCreationArgs("empty", "new", "")
	if err != nil || len(args) == 0 || args[0] != "-N" {
		t.Fatalf("empty live server may be replaced: %v, %v", args, err)
	}
	if err := CreateAgentShell("empty", "new", ""); err != nil {
		t.Fatal(err)
	}
	if got := run("display-message", "-p", "#{pid}"); got != strconv.Itoa(pid) {
		t.Fatalf("empty server replaced: %s, want %d", got, pid)
	}
}
