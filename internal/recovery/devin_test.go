//go:build !windows

package recovery

import (
	"database/sql"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestAllAgentsUseForegroundRootSelection(t *testing.T) {
	for _, agent := range []string{AgentClaude, AgentCodex, AgentDevin} {
		t.Run(agent, func(t *testing.T) {
			processes := map[int]processInfo{
				10: {PID: 10, PPID: 1, PGID: 10, TPGID: 20, Command: "zsh"},
				20: {PID: 20, PPID: 10, PGID: 20, TPGID: 20, Command: agent},
				21: {PID: 21, PPID: 20, PGID: 20, TPGID: 20, Command: agent},
				30: {PID: 30, PPID: 10, PGID: 30, TPGID: 20, Command: agent},
			}
			got, p, ok := findAgent(10, processes)
			if !ok || got != agent || p.PID != 20 {
				t.Fatalf("root=%s %#v %v", got, p, ok)
			}
			p = processes[20]
			p.TPGID = 10
			processes[20] = p
			p = processes[21]
			p.TPGID = 10
			processes[21] = p
			if _, _, ok := findAgent(10, processes); ok {
				t.Fatal("background job counted as active agent")
			}
		})
	}
}

func TestDevinLogRequiresUnambiguousRootStoreEvents(t *testing.T) {
	prefix := "2026-10-14T05:07:49.926171Z  INFO run_acp_server:session_db_call:session_db_job: chisel_agent::session_db: "
	for _, tc := range []struct{ name, body, want string }{
		{"created", prefix + "Created new session: gentle-birch\n", "gentle-birch"},
		{"saved", prefix + "Saved 14 message nodes (starting from 4) for session gentle-birch\n", "gentle-birch"},
		{"consistent", prefix + "Created new session: gentle-birch\n" + prefix + "Saved 9 message nodes (starting from 18) for session gentle-birch\n", "gentle-birch"},
		{"ambiguous", prefix + "Created new session: gentle-birch\n" + prefix + "Created new session: bold-pine\n", ""},
		{"request-id", "session_id=gentle-birch\n", ""},
		{"quoted-event", "tool_output: " + prefix + "Created new session: gentle-birch\n", ""},
		{"subagent", "2026-10-14T05:07:49Z INFO run_acp_server:subagent:session_db_call:session_db_job: chisel_agent::session_db: Created new session: gentle-birch\n", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "owned.log")
			if err := os.WriteFile(path, []byte(tc.body), 0600); err != nil {
				t.Fatal(err)
			}
			got, err := devinSessionFromLog(path)
			if got != tc.want || ((tc.want == "") != (err != nil)) {
				t.Fatalf("identity=%q, %v", got, err)
			}
		})
	}
}

func TestDevinSessionRequiresOwnedStoreAndLog(t *testing.T) {
	xdg := t.TempDir()
	root := filepath.Join(xdg, "devin", "cli")
	log := filepath.Join(root, "logs", "process.log")
	if err := os.MkdirAll(filepath.Dir(log), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(log, []byte("2026-10-14T05:07:49Z INFO run_acp_server:session_db_call:session_db_job: chisel_agent::session_db: Created new session: gentle-birch\n"), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "sessions.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES ('gentle-birch')`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	state := processState{Environment: map[string]string{"HOME": "/home/not-default", "XDG_DATA_HOME": xdg}}
	got, err := inspectDevinFiles([]string{path, log}, state)
	if err != nil || got.ID != "gentle-birch" || got.Path != path || !got.RequireScreenMatch {
		t.Fatalf("identity=%#v, %v", got, err)
	}
	for _, files := range [][]string{{path}, {log}, {filepath.Join(t.TempDir(), "sessions.db"), log}} {
		if got, err := inspectDevinFiles(files, state); err == nil {
			t.Fatalf("unowned identity=%#v", got)
		}
	}
}

func TestDevinResumePreservesProfilePermissionsAndExplicitIdentity(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "devin")
	if err := os.WriteFile(exe, []byte("binary"), 0700); err != nil {
		t.Fatal(err)
	}
	entry := Entry{Agent: AgentDevin, Executable: exe, SessionID: "gentle-birch", Argv: []string{"devin", "--permission-mode", "bypass", "--model", "chosen-model", "--resume", "old-thread"}, XDGDataHome: "/profile/data", XDGConfigHome: "/profile/config"}
	got, err := resumeArgv(entry)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{environmentExecutable(), "XDG_DATA_HOME=/profile/data", "XDG_CONFIG_HOME=/profile/config", exe, "--permission-mode", "bypass", "--model", "chosen-model", "--resume", "gentle-birch"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resume=%#v", got)
	}
	for _, args := range [][]string{{"devin", "--future-option"}, {"devin", "initial prompt"}, {"devin", "--cloud"}} {
		entry.Argv = args
		if _, err := resumeArgv(entry); err == nil {
			t.Fatalf("unreviewed startup accepted: %#v", args)
		}
	}
}

func TestSessionValidationUsesTheSelectedProvider(t *testing.T) {
	for _, agent := range []string{AgentClaude, AgentCodex, AgentDevin} {
		for _, id := range []string{testSessionID, "gentle-birch", "../other", ""} {
			want := id == testSessionID || (agent == AgentDevin && id == "gentle-birch")
			if got := validSessionID(agent, id); got != want {
				t.Fatalf("%s %q: %v", agent, id, got)
			}
		}
	}
	entry := Entry{Name: "panel", Agent: AgentDevin}
	id := "gentle-birch"
	got, err := applyEntryEdit(entry, EntryEdit{Panel: "panel", SessionID: &id})
	if err != nil || got.SessionID != id || got.SessionEvidence != SessionEvidenceUserEdit {
		t.Fatalf("edit=%#v, %v", got, err)
	}
}
