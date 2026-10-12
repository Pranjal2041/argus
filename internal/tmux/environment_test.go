//go:build !windows

package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

const colorProbe = `printf 'NO_COLOR=<%s> FORCE_COLOR=<%s> CLICOLOR=<%s> CLICOLOR_FORCE=<%s>\n' "${NO_COLOR-unset}" "${FORCE_COLOR-unset}" "${CLICOLOR-unset}" "${CLICOLOR_FORCE-unset}"
if [ -z "${NO_COLOR+x}${FORCE_COLOR+x}${CLICOLOR+x}${CLICOLOR_FORCE+x}" ]; then printf '\033[32mcolor-ready\033[0m\n'; fi
exec /bin/sleep 60`

func TestInteractiveCreationCleansStaleDefaultsWithoutRestartingExistingPanes(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	for _, kind := range []string{"visible", "agent-shell", "spawn", "cold-spawn", "explicit-command"} {
		t.Run(kind, func(t *testing.T) {
			for _, key := range []string{"NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"} {
				t.Setenv(key, "0")
			}
			socket := fmt.Sprintf("ut-color-test-%d-%s", os.Getpid(), kind)
			run := func(args ...string) string {
				t.Helper()
				out, err := exec.Command("tmux", append([]string{"-L", socket}, args...)...).CombinedOutput()
				if err != nil {
					t.Fatalf("tmux %q: %v: %s", args, err, out)
				}
				return strings.TrimSpace(string(out))
			}
			t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
			before := ""
			if kind != "cold-spawn" {
				run("-f", "/dev/null", "new-session", "-d", "-s", "retained", "sh", "-c", colorProbe)
				run("set-option", "-g", "default-shell", "/bin/sh")
				run("set-option", "-g", "default-command", colorProbe)
				before = run("display-message", "-p", "-t", "retained", "#{pid}:#{pane_pid}:#{session_id}")
			}
			provider := NewProvider(socket)
			var err error
			switch kind {
			case "visible":
				err = provider.Create("new", "")
			case "agent-shell":
				err = provider.CreateAgentShell("new", "")
			case "explicit-command":
				err = provider.Spawn("new", "", "export NO_COLOR=user-choice\n"+colorProbe, 0)
			default:
				err = provider.Spawn("new", "", colorProbe, 0)
			}
			if err != nil {
				t.Fatal(err)
			}
			want := "NO_COLOR=<unset> FORCE_COLOR=<unset> CLICOLOR=<unset> CLICOLOR_FORCE=<unset>"
			if kind == "explicit-command" {
				want = "NO_COLOR=<user-choice>"
			}
			deadline := time.Now().Add(5 * time.Second)
			var output string
			for time.Now().Before(deadline) {
				output = run("capture-pane", "-p", "-e", "-J", "-t", "new")
				if strings.Contains(output, want) && (kind == "explicit-command" || strings.Contains(output, "\x1b[32mcolor-ready")) {
					break
				}
				time.Sleep(20 * time.Millisecond)
			}
			if !strings.Contains(output, want) {
				t.Fatalf("child output = %q", output)
			}
			if kind != "explicit-command" && !strings.Contains(output, "\x1b[32mcolor-ready") {
				t.Fatalf("child did not emit/preserve green output: %q", output)
			}
			if before != "" {
				if after := run("display-message", "-p", "-t", "retained", "#{pid}:#{pane_pid}:#{session_id}"); after != before {
					t.Fatalf("replaced live backend/pane: %s -> %s", before, after)
				}
				if output := run("capture-pane", "-p", "-t", "retained"); !strings.Contains(output, "NO_COLOR=<0>") {
					t.Fatalf("changed existing pane: %q", output)
				}
			}
			// Merely reusing/promoting a live session must not change defaults.
			run("set-environment", "-g", "NO_COLOR", "retained-default")
			if err := provider.CreateAgentShell("new", ""); err != nil {
				t.Fatal(err)
			}
			if err := provider.Create("new", ""); err != nil {
				t.Fatal(err)
			}
			if got := run("show-environment", "-g", "NO_COLOR"); got != "NO_COLOR=retained-default" {
				t.Fatalf("attach-only changed environment: %s", got)
			}
		})
	}
}
