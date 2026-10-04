//go:build !windows

package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Re-exec the real entry point with isolated storage and a private tmux socket.
// This catches synchronous backups accidentally reintroduced anywhere in main.
func TestBrokerBackupStartupProcess(t *testing.T) {
	if os.Getenv("UT_TEST_BACKUP_STARTUP_CHILD") != "1" {
		return
	}
	flag.CommandLine = flag.NewFlagSet("ut-broker", flag.ExitOnError)
	os.Args = []string{os.Args[0],
		"--listen", os.Getenv("UT_TEST_BACKUP_LISTEN"),
		"--extra-listen", os.Getenv("UT_TEST_BACKUP_EXTRA_LISTEN"),
		"--tmux-socket", fmt.Sprintf("backup-startup-test-%d", os.Getpid()),
		"--session", "",
	}
	main()
	os.Exit(0)
}

func TestBrokerServesWhileInitialBackupBlocked(t *testing.T) {
	for _, tc := range []struct {
		relative      string
		cancelBlocked bool
	}{
		{relative: "broker/history-stalled.json"},
		{relative: "lab/sets/stalled/set.json"},
		{relative: "lab/sets/stalled/set.json", cancelBlocked: true},
	} {
		t.Run(fmt.Sprintf("%s/cancel-blocked=%t", tc.relative, tc.cancelBlocked), func(t *testing.T) {
			relative := tc.relative
			home := t.TempDir()
			backupRoot := filepath.Join(home, "backups")
			labRoot := filepath.Join(home, "lab")
			source := filepath.Join(home, ".universal-tmux", strings.TrimPrefix(relative, "broker/"))
			if strings.HasPrefix(relative, "lab/") {
				source = filepath.Join(home, relative)
			}
			if err := os.MkdirAll(filepath.Dir(source), 0o700); err != nil {
				t.Fatal(err)
			}
			// A FIFO gives a deterministic slow read without a large test dataset.
			if err := syscall.Mkfifo(source, 0o600); err != nil {
				t.Fatal(err)
			}
			primary := reserveBackupTestAddress(t)
			secondary := reserveBackupTestAddress(t)
			t.Setenv("HOME", home)
			t.Setenv("USERPROFILE", home)
			t.Setenv("UT_BACKUP_ROOT", backupRoot)
			t.Setenv("UT_LAB_ROOT", labRoot)
			t.Setenv("UT_BACKUP_INCLUDE_HUB_STATE", "1")
			t.Setenv("UT_LAB_MIRROR", "0")
			t.Setenv("UT_RECOVERY_ENABLE", "0")
			t.Setenv("UT_TEST_BACKUP_STARTUP_CHILD", "1")
			t.Setenv("UT_TEST_BACKUP_LISTEN", primary.Addr().String())
			t.Setenv("UT_TEST_BACKUP_EXTRA_LISTEN", secondary.Addr().String())
			logPath := filepath.Join(home, "broker.log")
			logFile, err := os.Create(logPath)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = logFile.Close() })
			cmd := exec.Command(os.Args[0], "-test.run=^TestBrokerBackupStartupProcess$")
			cmd.Stdout, cmd.Stderr = logFile, logFile
			_ = primary.Close()
			_ = secondary.Close()
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			stopped := false
			stopBroker := func() {
				t.Helper()
				if stopped {
					return
				}
				stopped = true
				_ = cmd.Process.Signal(os.Interrupt)
				select {
				case err := <-done:
					if err != nil {
						t.Errorf("broker exit: %v", err)
					}
				case <-time.After(5 * time.Second):
					_ = cmd.Process.Kill()
					<-done
					t.Error("broker shutdown waited for background backup")
				}
			}
			t.Cleanup(func() {
				stopBroker()
				if t.Failed() {
					body, _ := os.ReadFile(logPath)
					t.Logf("child broker log:\n%s", body)
				}
			})

			var writer *os.File
			waitForBackupTest(t, "initial backup to begin reading", func() bool {
				fd, err := syscall.Open(source, syscall.O_WRONLY|syscall.O_NONBLOCK, 0)
				if errors.Is(err, syscall.ENXIO) {
					return false
				}
				if err != nil {
					t.Fatal(err)
				}
				writer = os.NewFile(uintptr(fd), source)
				return true
			})
			t.Cleanup(func() { _ = writer.Close() })
			client := &http.Client{Timeout: 250 * time.Millisecond}
			defer client.CloseIdleConnections()
			for _, address := range []string{primary.Addr().String(), secondary.Addr().String()} {
				for _, path := range []string{"/whoami", "/sessions"} {
					waitForBackupTest(t, address+path+" while backup is blocked", func() bool {
						response, err := client.Get("http://" + address + path)
						if err != nil {
							return false
						}
						defer response.Body.Close()
						body, err := io.ReadAll(response.Body)
						marker := `"sessions"`
						if path == "/whoami" {
							marker = `"service":"universal-tmux-broker"`
						}
						return err == nil && response.StatusCode == http.StatusOK && strings.Contains(string(body), marker)
					})
				}
			}
			if tc.cancelBlocked {
				// Keep the source blocked until after the broker exits. Shutdown
				// must not inherit the same unbounded filesystem wait as startup.
				stopBroker()
				return
			}
			// Releasing the slow store must still produce the startup recovery point;
			// moving it off the critical path must not silently skip or defer it an hour.
			if _, err := writer.WriteString(`{"preserved":true}`); err != nil {
				t.Fatal(err)
			}
			_ = writer.Close()
			waitForBackupTest(t, "initial recovery point after backup unblocks", func() bool {
				matches, _ := filepath.Glob(filepath.Join(backupRoot, "*", relative))
				for _, path := range matches {
					body, err := os.ReadFile(path)
					if err == nil && string(body) == `{"preserved":true}` {
						return true
					}
				}
				return false
			})
		})
	}
}

func reserveBackupTestAddress(t *testing.T) net.Listener {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	return listener
}

func waitForBackupTest(t *testing.T, what string, ready func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ready() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
