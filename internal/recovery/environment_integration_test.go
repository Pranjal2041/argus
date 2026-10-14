//go:build !windows

package recovery

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const recoveryColorProbe = `printf 'NO_COLOR=<%s> FORCE_COLOR=<%s> CLICOLOR=<%s> CLICOLOR_FORCE=<%s>\n' "${NO_COLOR-unset}" "${FORCE_COLOR-unset}" "${CLICOLOR-unset}" "${CLICOLOR_FORCE-unset}"
if [ -z "${NO_COLOR+x}${FORCE_COLOR+x}${CLICOLOR+x}${CLICOLOR_FORCE+x}" ]; then printf '\033[32mcolor-ready\033[0m\n'; fi
exec /bin/sleep 60`

func colorRecoveryFixture(t *testing.T, suffix string, warm bool) (string, func(...string) string) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	for _, key := range []string{"NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"} {
		t.Setenv(key, "0")
	}
	socket := fmt.Sprintf("ut-recovery-color-%d-%s", os.Getpid(), suffix)
	run := func(args ...string) string {
		t.Helper()
		out, err := exec.Command("tmux", append([]string{"-L", socket}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("tmux %q: %v: %s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	if warm {
		run("-f", "/dev/null", "new-session", "-d", "-s", "_ut-"+socket, "sh", "-c", recoveryColorProbe)
		run("set-option", "-g", "default-shell", "/bin/sh")
		run("set-option", "-g", "default-command", recoveryColorProbe)
	}
	return socket, run
}

func requireColorRecoveryPane(t *testing.T, run func(...string) string, name string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var output string
	for time.Now().Before(deadline) {
		output = run("capture-pane", "-p", "-e", "-J", "-t", name)
		if strings.Contains(output, "NO_COLOR=<unset> FORCE_COLOR=<unset> CLICOLOR=<unset> CLICOLOR_FORCE=<unset>") &&
			strings.Contains(output, "\x1b[32mcolor-ready") {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("terminal inherited launcher's display policy: %q", output)
}

func TestRestoreInteractiveEnvironmentForShellsAndAgentCommands(t *testing.T) {
	for _, kind := range []string{"shell", "agent", "cold-agent"} {
		t.Run(kind, func(t *testing.T) {
			socket, run := colorRecoveryFixture(t, kind, kind != "cold-agent")
			panel := PanelStatus{Entry: Entry{Name: "restored", Directory: t.TempDir(), Agent: AgentShell}}
			if kind != "shell" {
				// Exercise the shared resumed-command boundary without launching a
				// real agent, contacting a provider, or modifying a conversation.
				panel.Agent = AgentCodex
				panel.ResumeArgv = []string{"/bin/sh", "-c", recoveryColorProbe}
			}
			if err := createRestoredSession(socket, panel); err != nil {
				t.Fatal(err)
			}
			requireColorRecoveryPane(t, run, "restored")
		})
	}
}

func TestStandaloneLauncherUsesInteractivePolicyOnlyForNewTerminals(t *testing.T) {
	socket, run := colorRecoveryFixture(t, "launcher", true)
	launcher, err := filepath.Abs("../../ut")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	project := filepath.Join(root, "project")
	if err := os.Mkdir(project, 0o700); err != nil {
		t.Fatal(err)
	}
	launch := func(args ...string) {
		t.Helper()
		cmd := exec.Command(launcher, append([]string{"-L", socket}, args...)...)
		cmd.Dir = project
		cmd.Env = environmentWithOverrides(os.Environ(), map[string]string{"UT_NO_ATTACH": "1", "UT_LOCAL_DIR": root})
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("launcher: %v: %s", err, out)
		}
	}
	for _, tc := range []struct {
		name string
		args []string
	}{
		{"visible", []string{"--visible", "visible"}},
		{"hidden", []string{"hidden"}},
		{"project", []string{"--visible"}},
		{"project-2", nil},
	} {
		for _, key := range []string{"NO_COLOR", "FORCE_COLOR", "CLICOLOR", "CLICOLOR_FORCE"} {
			run("set-environment", "-g", key, "0")
		}
		launch(tc.args...)
		requireColorRecoveryPane(t, run, tc.name)
	}
	before := run("display-message", "-p", "-t", "visible", "#{pid}:#{pane_pid}:#{session_id}")
	run("set-environment", "-g", "NO_COLOR", "unchanged")
	launch("visible")
	if got := run("show-environment", "-g", "NO_COLOR"); got != "NO_COLOR=unchanged" {
		t.Fatalf("attach changed defaults: %s", got)
	}
	if got := run("display-message", "-p", "-t", "visible", "#{pid}:#{pane_pid}:#{session_id}"); got != before {
		t.Fatal("attach replaced live pane")
	}
}
