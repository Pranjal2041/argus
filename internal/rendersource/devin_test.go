package rendersource

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func devinFixture(t *testing.T, home, cwd, id, answer string, unanswered bool) TranscriptRef {
	t.Helper()
	path := filepath.Join(home, ".local", "share", "devin", "cli", "sessions.db")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, working_directory TEXT, last_activity_at INTEGER, main_chain_id INTEGER, hidden INTEGER DEFAULT 0);
	CREATE TABLE IF NOT EXISTS message_nodes (session_id TEXT, node_id INTEGER, parent_node_id INTEGER, chat_message TEXT, PRIMARY KEY(session_id,node_id));`)
	if err != nil {
		t.Fatal(err)
	}
	head := 2
	if unanswered {
		head = 3
	}
	if _, err := db.Exec(`INSERT INTO sessions VALUES (?, ?, ?, ?, 0)`, id, cwd, time.Now().Unix(), head); err != nil {
		t.Fatal(err)
	}
	messages := []map[string]any{{"role": "user", "content": "Explain the architecture"}, {"role": "assistant", "content": answer, "thinking": "PRIVATE REASONING"}, {"role": "user", "content": "A new unanswered question"}}
	for i, message := range messages[:head] {
		body, _ := json.Marshal(message)
		var parent any
		if i > 0 {
			parent = i
		}
		if _, err := db.Exec(`INSERT INTO message_nodes VALUES (?, ?, ?, ?)`, id, i+1, parent, string(body)); err != nil {
			t.Fatal(err)
		}
	}
	return TranscriptRef{Provider: "devin", Path: path, SessionID: id}
}

const devinAnswer = "# System architecture\n\nThe worker executes tasks while the coordinator collects measurements and publishes the final report for each completed experiment.\n\n| Component | Responsibility |\n|---|---|\n| Worker | Execute tasks |\n| Coordinator | Collect measurements |"

func TestDevinExactDatabaseIdentityAndHistory(t *testing.T) {
	home := t.TempDir()
	ref := devinFixture(t, home, "/project", "first-thread", devinAnswer, false)
	devinFixture(t, home, "/project", "neighbor-thread", "A neighbor's answer must not appear.", false)
	result, err := ResolveWithTranscript(home, "/project", devinAnswer, ref)
	if err != nil || result.Source != devinAnswer || result.Origin != "devin-transcript" {
		t.Fatalf("result = %#v, %v", result, err)
	}
	history, err := History(ref)
	if err != nil || len(history) != 2 || history[1].Text != devinAnswer {
		t.Fatalf("history = %#v, %v", history, err)
	}
	ref.SessionID = "missing-thread"
	if _, err := ResolveWithTranscript(home, "/project", devinAnswer, ref); err == nil {
		t.Fatal("missing identity fell back to another conversation")
	}
	ref.Path += ".missing"
	if _, err := ResolveWithTranscript(home, "/project", devinAnswer, ref); err == nil {
		t.Fatal("missing exact store fell back to discovery")
	}
}

func TestDevinUnansweredTurnAndDiscoveryScope(t *testing.T) {
	home := t.TempDir()
	ref := devinFixture(t, home, "/project", "waiting-thread", devinAnswer, true)
	if _, err := ResolveWithTranscript(home, "/project", devinAnswer, ref); err == nil {
		t.Fatal("rendered previous turn")
	}
	if _, err := Resolve(home, "/project", devinAnswer); err == nil {
		t.Fatal("discovery rendered previous turn")
	}
	otherHome := t.TempDir()
	devinFixture(t, otherHome, "/other-project", "ready-thread", devinAnswer, false)
	if _, err := Resolve(otherHome, "/project", devinAnswer); err == nil {
		t.Fatal("discovery crossed working directories")
	}
	if result, err := Resolve(otherHome, "/other-project", devinAnswer); err != nil || result.Source != devinAnswer {
		t.Fatalf("discovery = %#v, %v", result, err)
	}
}

func TestDevinATIFPrefersFinalAnswerOverToolCommentary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "export.json")
	body, _ := json.Marshal(map[string]any{"schema_version": "ATIF-v1.7", "session_id": "export-thread", "steps": []any{
		map[string]any{"source": "user", "message": "question"},
		map[string]any{"source": "agent", "message": "I am checking files now.", "tool_calls": []any{map[string]any{"arguments": "private"}}},
		map[string]any{"source": "agent", "message": devinAnswer, "reasoning_content": "PRIVATE REASONING"},
	}})
	if err := os.WriteFile(path, body, 0600); err != nil {
		t.Fatal(err)
	}
	ref := TranscriptRef{Provider: "devin", Path: path, SessionID: "export-thread", RequireScreenMatch: true}
	result, err := ResolveWithTranscript("", "", devinAnswer, ref)
	if err != nil || result.Source != devinAnswer || strings.Contains(result.Source, "checking files") {
		t.Fatalf("export result = %#v, %v", result, err)
	}
	if _, err := HistoryWithScreen(ref, "unrelated screen"); err == nil {
		t.Fatal("uncorroborated history accepted")
	}
	if entries, err := HistoryWithScreen(ref, devinAnswer); err != nil || len(entries) != 3 {
		t.Fatalf("entries=%#v, %v", entries, err)
	}
}

func TestAdapterDiscoveryFallbackIsLazy(t *testing.T) {
	original := transcriptAdapters
	t.Cleanup(func() { transcriptAdapters = original })
	fallbackCalls := 0
	transcriptAdapters = []transcriptAdapter{{provider: "fixture", discover: func(string, string) []candidateFile { return []candidateFile{{provider: "fixture"}} },
		messages:         func(candidateFile) []message { return []message{{provider: "fixture", text: devinAnswer}} },
		fallbackDiscover: func(string, string) []candidateFile { fallbackCalls++; return nil },
	}}
	if _, err := Resolve("", "", devinAnswer); err != nil {
		t.Fatal(err)
	}
	if fallbackCalls != 0 {
		t.Fatal("discovery broadened despite a proven scoped match")
	}
}
