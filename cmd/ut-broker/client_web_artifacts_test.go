package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"universal-tmux/internal/webartifact"
)

func TestParseWebArtifactAddRequiresExplicitRecipe(t *testing.T) {
	parsed, err := parseWebArtifactSaveArgs([]string{
		"Dashboard",
		"--cwd", filepath.Join(string(filepath.Separator), "workspace", "project"),
		"--url", "http://localhost:5800/dashboard",
		"--command", "source .venv/bin/activate && exec python dashboard.py",
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.name != "Dashboard" || parsed.command == "" || parsed.cwd == "" {
		t.Fatalf("parsed = %+v", parsed)
	}
	if _, err := parseWebArtifactSaveArgs([]string{"Dashboard", "--cwd", "/tmp", "--url", "http://localhost:1"}, false); err == nil {
		t.Fatal("missing command was accepted")
	}
}

func TestApplyWebArtifactPortSupportsAutomaticAndNumericModes(t *testing.T) {
	automatic := webArtifactSaveArgs{
		cwd: "/tmp", endpointURL: "http://localhost:{port}/dashboard",
		command: "exec python dashboard.py --port {port}", port: "auto",
	}
	mode, err := applyWebArtifactPort(&automatic)
	if err != nil || mode != webartifact.PortModeAuto || !strings.Contains(automatic.command, webartifact.PortPlaceholder) {
		t.Fatalf("automatic port = %q, %+v, err=%v", mode, automatic, err)
	}

	fixed := webArtifactSaveArgs{
		cwd: "/tmp", endpointURL: "http://localhost:{port}/dashboard",
		command: "exec python dashboard.py --port {port}", port: "6042",
	}
	mode, err = applyWebArtifactPort(&fixed)
	if err != nil || mode != "" || fixed.endpointURL != "http://localhost:6042/dashboard" ||
		fixed.command != "exec python dashboard.py --port 6042" {
		t.Fatalf("numeric port = %q, %+v, err=%v", mode, fixed, err)
	}
}

func TestApplyWebArtifactAutoPortRejectsImplicitCommands(t *testing.T) {
	parsed := webArtifactSaveArgs{
		cwd: "/tmp", endpointURL: "http://localhost:{port}/dashboard",
		command: "exec python dashboard.py", port: "auto",
	}
	if _, err := applyWebArtifactPort(&parsed); err == nil || !strings.Contains(err.Error(), webartifact.PortPlaceholder) {
		t.Fatalf("missing placeholder error = %v", err)
	}
}

func TestCurrentTmuxSessionNameUsesExactPane(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("tmux is not used by the Windows client")
	}
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socketFile, err := os.CreateTemp("/tmp", "ut-web-artifact-test-*")
	if err != nil {
		t.Fatal(err)
	}
	socket := socketFile.Name()
	_ = socketFile.Close()
	_ = os.Remove(socket)
	t.Cleanup(func() { _ = os.Remove(socket) })
	name := "web-provenance-test"
	if out, err := exec.Command("tmux", "-S", socket, "new-session", "-d", "-s", name, "sleep 30").CombinedOutput(); err != nil {
		t.Fatalf("new-session: %v: %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-S", socket, "kill-server").Run() })
	pane, err := exec.Command("tmux", "-S", socket, "display-message", "-p", "-t", name, "#{pane_id}").Output()
	if err != nil {
		t.Fatal(err)
	}
	resolved, err := currentTmuxSessionName(socket+",123,0", strings.TrimSpace(string(pane)))
	if err != nil {
		t.Fatal(err)
	}
	if resolved != name {
		t.Fatalf("resolved %q, want %q", resolved, name)
	}
}

func TestWebArtifactSessionLineageSurvivesRename(t *testing.T) {
	sessions := []webArtifactSession{
		{Name: "renamed-panel", ID: "$18", LineageID: "conpty:stable-lineage"},
	}
	got, ok := matchWebArtifactSession(sessions, "", "conpty:stable-lineage")
	if !ok || got.Name != "renamed-panel" || got.ID != "$18" {
		t.Fatalf("matchWebArtifactSession() = %+v, %v", got, ok)
	}
}
