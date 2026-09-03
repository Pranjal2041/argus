//go:build !windows

package recovery

import (
	"os"
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

func TestCodexExplicitResumeArgvIsProcessOwnedSessionEvidence(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Agent: AgentCodex, Directory: t.TempDir(), Executable: "/stale/captured/executable",
		Argv:         []string{exe, "--yolo", "resume", testSessionID},
		CaptureError: "Codex process has no open rollout files",
	}
	panel := preflight(entry, map[string]Entry{})
	if panel.State != PanelReady || panel.SessionID != testSessionID || panel.SessionEvidence != "resume-argv" {
		t.Fatalf("explicit resume preflight = %#v", panel)
	}
	want := []string{exe, "--yolo", "resume", testSessionID}
	if !reflect.DeepEqual(panel.ResumeArgv, want) {
		t.Fatalf("resume argv = %#v, want %#v", panel.ResumeArgv, want)
	}
}

func TestCodexResumeArgvEvidenceFailsClosedWhenAmbiguous(t *testing.T) {
	other := "019f9bfd-86da-7133-8213-39aa87070000"
	if id, ok := codexResumeSessionFromArgv([]string{
		"codex", "resume", testSessionID, "resume", other,
	}); ok || id != "" {
		t.Fatalf("ambiguous resume selectors produced %q, %v", id, ok)
	}
}

func TestUnsupportedCaptureOffersExactReviewedLaunch(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "codex")
	if err := writeAtomic(exe, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{
		Name: "manual", Directory: t.TempDir(), Agent: AgentCodex,
		Argv:         []string{exe, "--future-option", "value with spaces"},
		CaptureError: "unknown future launch format",
	}
	panel := preflight(entry, map[string]Entry{})
	if panel.State != PanelUnsupported || !panel.CapturedLaunchReviewable {
		t.Fatalf("unsupported preflight = %#v", panel)
	}
	prepared := prepareCapturedLaunch(panel)
	if prepared.State != PanelReady || !reflect.DeepEqual(prepared.ResumeArgv, entry.Argv) {
		t.Fatalf("prepared captured launch = %#v", prepared)
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

func TestExplicitEntryEditCanRepairFolderAndConversationWithoutMutatingCapture(t *testing.T) {
	original := Entry{
		Name: "research", Directory: "/missing/captured/path", Agent: AgentCodex,
		Executable: os.Args[0], Argv: []string{os.Args[0], "--yolo", "resume", "11111111-1111-1111-1111-111111111111"},
		SessionID: "11111111-1111-1111-1111-111111111111", CaptureError: "old capture failure",
	}
	directory := t.TempDir()
	sessionID := "22222222-2222-2222-2222-222222222222"
	agent := AgentCodex
	executable := os.Args[0]
	arguments := []string{"--yolo"}
	edited, err := applyEntryEdit(original, EntryEdit{
		Panel: "research", Directory: &directory, Agent: &agent, SessionID: &sessionID,
		Executable: &executable, Arguments: &arguments,
	})
	if err != nil {
		t.Fatal(err)
	}
	if edited.Directory != directory || edited.SessionID != sessionID ||
		edited.SessionEvidence != SessionEvidenceUserEdit || edited.CaptureError != "" {
		t.Fatalf("edited entry = %#v", edited)
	}
	if panel := preflight(edited, map[string]Entry{}); panel.State != PanelReady {
		t.Fatalf("edited preflight = %#v", panel)
	}
	if original.Directory != "/missing/captured/path" || original.SessionID == sessionID {
		t.Fatalf("source capture was mutated: %#v", original)
	}
}

func TestExplicitEntryEditRejectsRelativeFolderAndUnknownAgent(t *testing.T) {
	entry := Entry{Name: "research", Directory: t.TempDir(), Agent: AgentShell}
	relative := "project"
	if _, err := applyEntryEdit(entry, EntryEdit{Panel: entry.Name, Directory: &relative}); err == nil {
		t.Fatal("relative recovery directory was accepted")
	}
	unknown := "website-specific-agent"
	if _, err := applyEntryEdit(entry, EntryEdit{Panel: entry.Name, Agent: &unknown}); err == nil {
		t.Fatal("unknown recovery agent was accepted")
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
