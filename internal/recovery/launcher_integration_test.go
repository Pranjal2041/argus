//go:build !windows

package recovery

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestBrokerOnlyLauncherColdStartConcurrentStartAndServerLoss(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	launcher, err := filepath.Abs("../../ut")
	if err != nil {
		t.Fatal(err)
	}
	for index, transport := range []string{"native", "embedded"} {
		t.Run(transport, func(t *testing.T) {
			root := t.TempDir()
			socket := fmt.Sprintf("ut-service-test-%d-%d", os.Getpid(), index)
			cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
			cleanup()
			t.Cleanup(cleanup)
			starts := filepath.Join(root, "starts")
			broker := filepath.Join(root, "ut-broker")
			// A long-running broker fixture makes ownership observable without
			// opening a network endpoint or touching real credentials/state.
			body := "#!/bin/sh\n[ \"${1:-}\" != --probe-local ] || exit 1\n" +
				"[ -z \"${NO_COLOR+x}${FORCE_COLOR+x}${CLICOLOR+x}${CLICOLOR_FORCE+x}\" ] || exit 9\n" +
				"printf '%s\\n' \"$$\" >> " + shellJoin([]string{starts}) + "\nexec sleep 120\n"
			if err := os.WriteFile(broker, []byte(body), 0o700); err != nil {
				t.Fatal(err)
			}
			tailscale := filepath.Join(root, "tailscale")
			ip := "100.64.0.8"
			if transport == "embedded" {
				ip = ""
				if err := os.WriteFile(filepath.Join(root, "authkey"), []byte("test-only-not-a-key"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(tailscale, []byte("#!/bin/sh\nprintf '%s\\n' '"+ip+"'\n"), 0o700); err != nil {
				t.Fatal(err)
			}
			env := environmentWithOverrides(os.Environ(), map[string]string{
				"UT_HOME": root, "UT_BROKER": broker, "UT_LOCAL_DIR": filepath.Join(root, "local"),
				"UT_TAILSCALE_BIN": tailscale, "UT_STATE_DIR": filepath.Join(root, "state"),
				"NO_COLOR": "1", "FORCE_COLOR": "0", "CLICOLOR": "0", "CLICOLOR_FORCE": "1",
			})
			run := func() error {
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, launcher, "-L", socket, "--broker-only")
				cmd.Env = env
				if out, err := cmd.CombinedOutput(); err != nil {
					return fmt.Errorf("%w: %s", err, out)
				}
				return nil
			}
			waitStarts := func(count int) []string {
				t.Helper()
				deadline := time.Now().Add(5 * time.Second)
				for time.Now().Before(deadline) {
					body, _ := os.ReadFile(starts)
					lines := strings.Fields(string(body))
					if len(lines) == count {
						return lines
					}
					if len(lines) > count {
						t.Fatalf("duplicate broker starts: %v", lines)
					}
					time.Sleep(20 * time.Millisecond)
				}
				t.Fatalf("broker did not reach %d starts", count)
				return nil
			}
			var wg sync.WaitGroup
			errors := make(chan error, 8)
			for i := 0; i < 8; i++ {
				wg.Add(1)
				go func() { defer wg.Done(); errors <- run() }()
			}
			wg.Wait()
			close(errors)
			for err := range errors {
				if err != nil {
					t.Fatal(err)
				}
			}
			first := waitStarts(1)[0]
			if err := run(); err != nil {
				t.Fatal(err)
			}
			if again := waitStarts(1)[0]; again != first {
				t.Fatal("reopening replaced a live broker")
			}
			out, err := exec.Command("tmux", "-L", socket, "list-sessions", "-F", "#{session_name}").Output()
			if err != nil || strings.TrimSpace(string(out)) != "_ut-"+socket {
				t.Fatalf("invented a panel: %q %v", out, err)
			}
			supervisor, err := os.ReadFile(filepath.Join(root, "local", "supervise-"+socket+".sh"))
			if err != nil || !strings.Contains(string(supervisor), "--session ''") {
				t.Fatal("broker-only launch selected a user session")
			}
			cleanup() // only the isolated server: simulate loss of all runtime state
			if err := run(); err != nil {
				t.Fatal(err)
			}
			if second := waitStarts(2)[1]; second == first {
				t.Fatal("server loss did not start a replacement broker")
			}
		})
	}
}
