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

func createVisibleTestSession(t *testing.T, socket, name, directory string) {
	t.Helper()
	args := []string{"-L", socket, "new-session", "-d", "-s", name}
	if directory != "" {
		args = append(args, "-c", directory)
	}
	args = append(args, ";", "set-option", "-t", name, "@ut_visible", "1")
	if out, err := exec.Command("tmux", args...).CombinedOutput(); err != nil {
		t.Fatalf("create visible test session %q: %v: %s", name, err, out)
	}
}

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
	createVisibleTestSession(t, socket, "paper", workingDirectory)
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
	createVisibleTestSession(t, socket, "same-name", originalDirectory)
	store := NewStore(socket)
	store.Dir = filepath.Join(t.TempDir(), "snapshots")
	snapshot, err := store.Capture()
	if err != nil {
		t.Fatal(err)
	}
	cleanup()

	conflictingDirectory := t.TempDir()
	createVisibleTestSession(t, socket, "same-name", conflictingDirectory)
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
	createVisibleTestSession(t, socket, "locale-test", directory)
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

func TestReviewedCapturedLaunchRunsServerStoredArgvAndVerifiesAgent(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	compiler, err := exec.LookPath("cc")
	if err != nil {
		t.Skip("a C compiler is required for the foreground-agent fixture")
	}
	socket := fmt.Sprintf("ut-recovery-reviewed-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "_ut-test").Run(); err != nil {
		t.Fatal(err)
	}

	directory := t.TempDir()
	executable := filepath.Join(directory, "codex")
	source := filepath.Join(directory, "agent.c")
	if err := os.WriteFile(source, []byte("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(compiler, source, "-o", executable).CombinedOutput(); err != nil {
		t.Fatalf("compile foreground-agent fixture: %v: %s", err, out)
	}
	store := NewStore(socket)
	store.Dir = filepath.Join(t.TempDir(), "snapshots")
	store.Now = func() time.Time { return time.Date(2026, 9, 1, 18, 0, 0, 0, time.UTC) }
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: "reviewed-captured-launch", Host: "test-host", Socket: socket,
		ServerID: "old-server", CapturedAt: store.Now(),
		Entries: []Entry{{
			Name: "manual-agent", Directory: directory, Agent: AgentCodex,
			Argv:         []string{executable, "--future-option", "value with spaces"},
			CaptureError: "unknown future launch format",
		}},
	}
	if err := store.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	status := store.Status(snapshot.ID)
	if len(status.Panels) != 1 || status.Panels[0].State != PanelUnsupported || !status.Panels[0].CapturedLaunchReviewable {
		t.Fatalf("reviewed status = %#v", status)
	}
	response := store.RestoreCapturedLaunch(snapshot.ID, []string{"manual-agent"}, 1)
	if len(response.Results) != 1 || response.Results[0].State != RestoreRestored {
		t.Fatalf("reviewed restore = %#v", response)
	}
	live, ok := currentEntry(socket, "manual-agent")
	if !ok || live.Agent != AgentCodex || !equivalentDirectory(live.Directory, directory) {
		t.Fatalf("reviewed live entry = %#v, %v", live, ok)
	}
}

func babelTestStore(root, host, socket string, now time.Time) *Store {
	return &Store{
		Socket: socket,
		Dir:    filepath.Join(root, safeComponent(host), safeComponent(socket)),
		Root:   root, Host: host, Cluster: "babel",
		Now: func() time.Time { return now },
	}
}

func TestBabelCrossNodeRestoreUsesSharedSnapshotAndConsumesEachPanel(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-babel-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)
	// A target allocation has a live broker supervisor but no user panels yet.
	if err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", "_ut-test").Run(); err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 8, 28, 15, 0, 0, 0, time.UTC)
	root := t.TempDir()
	directory := t.TempDir()
	directory, _ = filepath.EvalSymlinks(directory)
	source := babelTestStore(root, "babel-p9-28", socket, now.Add(-2*time.Minute))
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: "departed-node", Host: source.Host, Socket: socket,
		ServerID: "old-server", CapturedAt: now.Add(-2 * time.Minute),
		Entries: []Entry{{Name: "research", Directory: directory, Agent: AgentShell, Windows: 1, Panes: 1}},
	}
	if err := source.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}

	target := babelTestStore(root, "babel-q9-16", socket, now)
	status := target.Status("")
	if !status.Available || status.Snapshot == nil || status.Snapshot.ID != snapshot.ID {
		t.Fatalf("cross-node recovery status = %#v", status)
	}
	if status.TargetHost != target.Host || len(status.Candidates) != 1 || status.Candidates[0].Host != source.Host {
		t.Fatalf("cross-node candidates = %#v", status)
	}
	response := target.Restore(snapshot.ID, []string{"research"}, 1)
	if len(response.Results) != 1 || response.Results[0].State != RestoreRestored {
		t.Fatalf("cross-node restore = %#v", response)
	}
	targetSnapshots, err := target.loadAll()
	if err != nil || len(targetSnapshots) != 1 || len(targetSnapshots[0].Entries) != 1 || targetSnapshots[0].Entries[0].Name != "research" {
		t.Fatalf("restored target was not durably captured before its receipt: snapshots=%#v err=%v", targetSnapshots, err)
	}
	if err := exec.Command("tmux", "-L", socket, "kill-session", "-t", "=research").Run(); err != nil {
		t.Fatal(err)
	}
	afterClose := target.Status("")
	if afterClose.Available || afterClose.Snapshot != nil || len(afterClose.Candidates) != 0 {
		t.Fatalf("consumed cross-node workspace was offered again: %#v", afterClose)
	}
}

func TestBabelLiveSourceIsOfferedForCrossNodeMigration(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 8, 28, 15, 0, 0, 0, time.UTC)
	source := babelTestStore(root, "babel-p9-28", "definitely-no-server", now.Add(-30*time.Second))
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: "live-node", Host: source.Host, Socket: source.Socket,
		ServerID: "live-server", CapturedAt: now.Add(-30 * time.Second),
		Entries: []Entry{{Name: "research", Directory: t.TempDir(), Agent: AgentShell}},
	}
	if err := source.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	target := babelTestStore(root, "babel-q9-16", source.Socket, now)
	status := target.Status("")
	if !status.Available || status.Snapshot == nil || status.Snapshot.ID != snapshot.ID || len(status.Candidates) != 1 {
		t.Fatalf("live Babel node was not offered as a migration source: %#v", status)
	}
	explicit := target.Status(snapshot.ID)
	if !explicit.Available || explicit.Snapshot == nil || explicit.Snapshot.ID != snapshot.ID || explicit.Error != "" {
		t.Fatalf("explicit live migration source was unavailable: %#v", explicit)
	}
}

func TestBabelExpiredSourceIsOutsideTheRecoveryWindow(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 8, 28, 15, 0, 0, 0, time.UTC)
	source := babelTestStore(root, "babel-p9-28", "no-server", now.Add(-8*24*time.Hour))
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: "expired-node", Host: source.Host, Socket: source.Socket,
		ServerID: "expired-server", CapturedAt: now.Add(-8 * 24 * time.Hour),
		Entries: []Entry{{Name: "research", Directory: t.TempDir(), Agent: AgentShell}},
	}
	if err := source.saveLocked(snapshot); err != nil {
		t.Fatal(err)
	}
	target := babelTestStore(root, "babel-q9-16", source.Socket, now)
	if status := target.Status(""); status.Available || status.Snapshot != nil || len(status.Candidates) != 0 {
		t.Fatalf("expired Babel snapshot was offered: %#v", status)
	}
	if status := target.Status(snapshot.ID); status.Snapshot != nil || !strings.Contains(status.Error, "retention") {
		t.Fatalf("expired Babel snapshot was explicitly restorable: %#v", status)
	}
}

func TestCaptureEnabledOnSupportedUnixByDefault(t *testing.T) {
	for _, test := range []struct {
		goos, host, override string
		want                 bool
	}{
		{"darwin", "macbook", "", true},
		{"linux", "babel-p9-28", "", true},
		{"linux", "ut-babel-q9-16.example.ts.net", "", true},
		{"linux", "orchard-login", "", true},
		{"linux", "orchard-login", "1", true},
		{"linux", "orchard-login", "0", false},
		{"windows", "pranjala-win", "", false},
	} {
		if got := CaptureEnabled(test.goos, test.host, test.override); got != test.want {
			t.Fatalf("CaptureEnabled(%q, %q, %q) = %v, want %v", test.goos, test.host, test.override, got, test.want)
		}
	}
}

func TestBootstrapCanUseAFailedRestoreShell(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux is not installed")
	}
	socket := fmt.Sprintf("ut-recovery-bootstrap-%d", os.Getpid())
	cleanup := func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() }
	cleanup()
	t.Cleanup(cleanup)
	createVisibleTestSession(t, socket, "diagnostic-shell", "")

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
