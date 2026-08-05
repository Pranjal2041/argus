//go:build !windows

package recovery

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestFindAgentUsesOnlyThePaneForegroundJob(t *testing.T) {
	processes := map[int]processInfo{
		10: {PID: 10, PPID: 1, PGID: 10, TPGID: 10, Command: "zsh"},
		20: {PID: 20, PPID: 10, PGID: 20, TPGID: 10, Command: "codex"},
	}
	if agent, _, ok := findAgent(10, processes); ok || agent != "" {
		t.Fatalf("background Codex was classified as the interactive agent: %q", agent)
	}
	processes[20] = processInfo{PID: 20, PPID: 10, PGID: 20, TPGID: 20, Command: "codex"}
	if agent, process, ok := findAgent(10, processes); !ok || agent != AgentCodex || process.PID != 20 {
		t.Fatalf("foreground agent = %q %#v %v", agent, process, ok)
	}
}

func TestShellWorkspaceSurvivesTmuxServerReplacement(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-test-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)

	workingDirectory := t.TempDir()
	if out, err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "paper", "-c", workingDirectory).CombinedOutput(); err != nil {
		t.Fatalf("create original tmux server: %v: %s", err, out)
	}
	store := NewStore(socket)
	store.Dir = filepath.Join(t.TempDir(), "snapshots")
	store.Now = func() time.Time { return time.Date(2026, 8, 4, 12, 0, 0, 0, time.UTC) }
	snapshot, err := store.Capture()
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Entries) != 1 || snapshot.Entries[0].Agent != AgentShell {
		t.Fatalf("snapshot entries = %#v", snapshot.Entries)
	}

	cleanup() // simulate reboot / tmux-server loss; the manifest remains on disk
	// A freshly bootstrapped broker creates its hidden supervisor before the
	// user restores anything. Its empty snapshot must not replace the last real
	// workspace merely because it is newer.
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "_ut-test").Run(); err != nil {
		t.Fatal(err)
	}
	emptySnapshot, err := store.Capture()
	if err != nil {
		t.Fatal(err)
	}
	if emptySnapshot.ID == snapshot.ID || len(emptySnapshot.Entries) != 0 {
		t.Fatalf("new server snapshot = %#v", emptySnapshot)
	}
	if emptySnapshot.RecoverySourceID != snapshot.ID || emptySnapshot.RecoveryComplete {
		t.Fatalf("new server lineage = %#v, want pending source %s", emptySnapshot, snapshot.ID)
	}
	status := store.Status("")
	if !status.Available || status.ReadyCount != 1 || len(status.Panels) != 1 || status.Panels[0].State != PanelReady {
		t.Fatalf("recovery status = %#v", status)
	}
	if status.Snapshot == nil || status.Snapshot.ID != snapshot.ID {
		t.Fatalf("selected snapshot = %#v, want prior workspace %s", status.Snapshot, snapshot.ID)
	}
	response := store.Restore(snapshot.ID, []string{"paper"}, 1)
	if len(response.Results) != 1 || response.Results[0].State != RestoreRestored {
		t.Fatalf("restore response = %#v", response)
	}
	panes, err := listPanes(socket)
	if err != nil || len(panes) != 1 {
		t.Fatalf("restored panes = %#v, %v", panes, err)
	}
	if panes[0].Name != "paper" || panes[0].Directory != snapshot.Entries[0].Directory {
		t.Fatalf("restored pane = %#v", panes[0])
	}

	completed, err := store.Capture()
	if err != nil {
		t.Fatal(err)
	}
	if completed.RecoverySourceID != snapshot.ID || !completed.RecoveryComplete {
		t.Fatalf("completed lineage = %#v", completed)
	}
	if err := exec.Command("tmux", "-L", socket, "kill-session", "-t", "=paper").Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Capture(); err != nil {
		t.Fatal(err)
	}
	// Closing a panel after the reboot recovery was fully satisfied is an
	// intentional lifecycle event, not a second reboot. It must stay closed.
	afterClose := store.Status("")
	if afterClose.Available || afterClose.Snapshot != nil {
		t.Fatalf("completed recovery was offered again after intentional close: %#v", afterClose)
	}
}

func TestRestoreNeverOverwritesNameConflict(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-conflict-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)

	originalDirectory := t.TempDir()
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "same-name", "-c", originalDirectory).Run(); err != nil {
		t.Fatal(err)
	}
	store := NewStore(socket)
	store.Dir = filepath.Join(t.TempDir(), "snapshots")
	snapshot, err := store.Capture()
	if err != nil {
		t.Fatal(err)
	}
	cleanup()

	conflictingDirectory := t.TempDir()
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "same-name", "-c", conflictingDirectory).Run(); err != nil {
		t.Fatal(err)
	}
	status := store.Status(snapshot.ID)
	if len(status.Panels) != 1 || status.Panels[0].State != PanelConflict {
		t.Fatalf("shell conflict status = %#v", status)
	}
	before, _ := listPanes(socket)
	response := store.Restore(snapshot.ID, []string{"same-name"}, 1)
	after, _ := listPanes(socket)
	if len(response.Results) != 1 || response.Results[0].State != RestoreFailed {
		t.Fatalf("response = %#v", response)
	}
	if len(before) != 1 || len(after) != 1 || after[0].Directory != before[0].Directory {
		t.Fatalf("restore changed existing session: before=%#v after=%#v", before, after)
	}
}

func TestTmuxInspectionWorksWithoutParentLocale(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-locale-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)

	directory := filepath.Join(t.TempDir(), "folder with spaces")
	if err := os.Mkdir(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "locale-test", "-c", directory).CombinedOutput(); err != nil {
		t.Fatalf("create tmux server: %v: %s", err, out)
	}
	t.Setenv("LANG", "")
	t.Setenv("LC_CTYPE", "")
	t.Setenv("LC_ALL", "C")
	if _, _, _, _, err := tmuxServerIdentity(socket); err != nil {
		t.Fatalf("server identity without inherited locale: %v", err)
	}
	panes, err := listPanes(socket)
	if err != nil || len(panes) != 1 {
		t.Fatalf("panes without inherited locale = %#v, %v", panes, err)
	}
	wantDirectory, _ := filepath.EvalSymlinks(directory)
	gotDirectory, _ := filepath.EvalSymlinks(panes[0].Directory)
	if gotDirectory != wantDirectory {
		t.Fatalf("directory = %q, want %q", panes[0].Directory, directory)
	}
}

func TestAgentRestorePassesArgvWithoutShellReparsing(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-argv-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)

	directory := t.TempDir()
	output := filepath.Join(directory, "observed argv")
	executable := filepath.Join(directory, "fake codex")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellJoin([]string{output}) + "\n"
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	want := []string{"--yolo", "resume", testSessionID, "value with spaces", "it's literal"}
	panel := PanelStatus{
		Entry:      Entry{Name: "argv-panel", Directory: directory, Agent: AgentCodex},
		ResumeArgv: append([]string{executable}, want...),
	}
	if err := createRestoredSession(socket, panel); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		body, err := os.ReadFile(output)
		if err == nil {
			lines := splitNonemptyLines(string(body))
			if !reflect.DeepEqual(lines, want) {
				t.Fatalf("restored argv = %#v, want %#v", lines, want)
			}
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("restored command did not run")
}

func TestBootstrapCanUseAFailedRestoreShell(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-bootstrap-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "diagnostic-shell").Run(); err != nil {
		t.Fatal(err)
	}

	directory := t.TempDir()
	output := filepath.Join(directory, "launcher argv")
	launcher := filepath.Join(directory, "ut")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellJoin([]string{output}) + "\n"
	if err := os.WriteFile(launcher, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("UT_CLI", launcher)
	if err := NewStore(socket).Bootstrap(""); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"-L", socket, "diagnostic-shell"}
	if got := splitNonemptyLines(string(body)); !reflect.DeepEqual(got, want) {
		t.Fatalf("bootstrap argv = %#v, want %#v", got, want)
	}
}

func splitNonemptyLines(value string) []string {
	var lines []string
	for _, line := range strings.Split(value, "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}
