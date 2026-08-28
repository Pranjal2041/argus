package recovery

import (
	"path/filepath"
	"reflect"
	"testing"
)

const testSessionID = "019f9bfd-86da-7133-8213-39aa87079768"

func TestCodexResumePreservesSafetyModeAndReplacesSelector(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Agent: AgentCodex, Executable: exe, SessionID: testSessionID,
		Argv: []string{"codex", "--yolo", "-m", "gpt-5", "resume", "old-id", "old prompt"},
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{exe, "--yolo", "-m", "gpt-5", "resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestCodexResumeDropsVerifiedDuplicateLauncherMarker(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Agent: AgentCodex, Executable: exe, SessionID: testSessionID,
		Argv: []string{exe, "--yolo", "codex", "resume", testSessionID},
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{exe, "--yolo", "resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestCodexResumeDoesNotDropUnverifiedLauncherMarker(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Agent: AgentCodex, Executable: exe, SessionID: testSessionID,
		Argv: []string{exe, "--yolo", "codex", "resume", "019f9bfd-86da-7133-8213-39aa87070000"},
	}
	if _, err := resumeArgv(entry); err == nil {
		t.Fatal("resumeArgv should reject a launcher marker whose resume ID was not independently verified")
	}
}

func TestCodexResumePreservesCustomHomeForEveryPanel(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(t.TempDir(), ".codex2")
	entry := Entry{
		Agent: AgentCodex, Executable: exe, SessionID: testSessionID,
		Argv: []string{"codex", "--yolo"}, CodexHome: home,
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{environmentExecutable(), "CODEX_HOME=" + home, exe, "--yolo", "resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestCodexResumeInfersCustomHomeFromOlderSnapshot(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(t.TempDir(), ".codex-profile")
	entry := Entry{
		Agent: AgentCodex, Executable: exe, SessionID: testSessionID,
		Argv:        []string{"codex"},
		SessionPath: filepath.Join(home, "sessions", "2026", "08", "23", "rollout.jsonl"),
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{environmentExecutable(), "CODEX_HOME=" + home, exe, "resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestClaudeResumePreservesPermissionMode(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "claude")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Agent: AgentClaude, Executable: exe, SessionID: testSessionID,
		Argv: []string{"claude", "--dangerously-skip-permissions", "--resume", "old-id"},
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{exe, "--dangerously-skip-permissions", "--resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestClaudeResumePreservesCustomConfigDirectory(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "claude")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(t.TempDir(), ".claude-work")
	entry := Entry{
		Agent: AgentClaude, Executable: exe, SessionID: testSessionID,
		Argv: []string{"claude", "--dangerously-skip-permissions"}, ClaudeConfig: config,
	}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{environmentExecutable(), "CLAUDE_CONFIG_DIR=" + config, exe,
		"--dangerously-skip-permissions", "--resume", testSessionID}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume argv = %#v, want %#v", got, want)
	}
}

func TestResumeRefusesUnknownOptionAndInitialPrompt(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, argv := range [][]string{
		{"codex", "--future-option"},
		{"codex", "please mutate this repository"},
	} {
		_, err := resumeArgv(Entry{Agent: AgentCodex, Executable: exe, SessionID: testSessionID, Argv: argv})
		if err == nil {
			t.Fatalf("resumeArgv(%#v) should fail closed", argv)
		}
	}
}

func TestShellJoinIsUnambiguous(t *testing.T) {
	got := shellJoin([]string{"claude", "--add-dir", "/tmp/a folder", "it's"})
	want := `claude --add-dir '/tmp/a folder' 'it'"'"'s'`
	if got != want {
		t.Fatalf("shellJoin = %q, want %q", got, want)
	}
}
