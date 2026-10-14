package devinsession

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func fixtureDatabase(t *testing.T, wal bool) (*sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sessions.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { db.Close() })
	if wal {
		if _, err := db.Exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0"); err != nil {
			t.Fatal(err)
		}
	}
	_, err = db.Exec(`CREATE TABLE sessions (id TEXT PRIMARY KEY, working_directory TEXT, last_activity_at INTEGER, main_chain_id INTEGER, hidden INTEGER DEFAULT 0);
	CREATE TABLE message_nodes (session_id TEXT, node_id INTEGER, parent_node_id INTEGER, chat_message TEXT, PRIMARY KEY(session_id, node_id));
	INSERT INTO sessions VALUES ('primary-thread', '/project', 123456, 6, 0), ('neighbor-thread', '/project', 999999, 6, 0)`)
	if err != nil {
		t.Fatal(err)
	}
	return db, path
}

func addNode(t *testing.T, db *sql.DB, session string, id int, parent any, message map[string]any) {
	t.Helper()
	body, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO message_nodes VALUES (?, ?, ?, ?)`, session, id, parent, string(body)); err != nil {
		t.Fatal(err)
	}
}

func TestReadActiveChainAndOnlyPublicMessages(t *testing.T) {
	db, path := fixtureDatabase(t, false)
	addNode(t, db, "primary-thread", 1, nil, map[string]any{"role": "system", "content": "private instructions"})
	addNode(t, db, "primary-thread", 2, 1, map[string]any{"role": "user", "content": "the question"})
	addNode(t, db, "primary-thread", 3, 2, map[string]any{"role": "assistant", "content": "private analysis", "phase": "analysis"})
	addNode(t, db, "primary-thread", 4, 3, map[string]any{"role": "tool", "content": "private tool output"})
	addNode(t, db, "primary-thread", 5, 4, map[string]any{"role": "assistant", "content": "abandoned retry"})
	addNode(t, db, "primary-thread", 6, 4, map[string]any{"role": "assistant", "content": "# Public answer\n\n| A | B |", "thinking": "private thinking", "tool_calls": []any{}})
	addNode(t, db, "neighbor-thread", 6, nil, map[string]any{"role": "assistant", "content": "other conversation"})
	db.Close()
	got, err := Read(path, "primary-thread")
	if err != nil {
		t.Fatal(err)
	}
	want := []Message{{Role: "user", Text: "the question"}, {Role: "assistant", Text: "# Public answer\n\n| A | B |", Phase: "final_answer"}}
	if !reflect.DeepEqual(got.Messages, want) || got.Directory != "/project" {
		t.Fatalf("read = %#v", got)
	}
	if _, err := Read(path, "missing-thread"); err == nil {
		t.Fatal("missing conversation accepted")
	}
}

func TestReadLiveWALAndInactiveDatabaseWithoutWritingSidecars(t *testing.T) {
	for _, live := range []bool{false, true} {
		t.Run(map[bool]string{false: "inactive", true: "live-wal"}[live], func(t *testing.T) {
			db, path := fixtureDatabase(t, true)
			addNode(t, db, "primary-thread", 6, nil, map[string]any{"role": "assistant", "content": "committed in WAL"})
			if !live {
				db.Close()
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			walBefore, _ := os.ReadFile(path + "-wal")
			got, err := Read(path, "primary-thread")
			if err != nil || len(got.Messages) != 1 || got.Messages[0].Text != "committed in WAL" {
				t.Fatalf("read = %#v, %v", got, err)
			}
			after, _ := os.ReadFile(path)
			walAfter, _ := os.ReadFile(path + "-wal")
			if string(before) != string(after) || string(walBefore) != string(walAfter) {
				t.Fatal("reader mutated database/WAL")
			}
			if !live {
				for _, suffix := range []string{"-wal", "-shm", "-journal"} {
					if _, err := os.Stat(path + suffix); !os.IsNotExist(err) {
						t.Fatalf("reader created %s", suffix)
					}
				}
			}
		})
	}
}

func TestReadFailsClosedForCycleMissingHeadAndOversizedNewest(t *testing.T) {
	for _, kind := range []string{"cycle", "missing", "oversize", "structured-content"} {
		t.Run(kind, func(t *testing.T) {
			db, path := fixtureDatabase(t, false)
			if kind != "missing" {
				var parent any
				var content any = "public text"
				if kind == "cycle" {
					parent = 6
				}
				if kind == "oversize" {
					content = strings.Repeat("x", MaxPublicBytes+1)
				}
				if kind == "structured-content" {
					content = []any{map[string]any{"type": "thinking", "text": "private"}}
				}
				addNode(t, db, "primary-thread", 6, parent, map[string]any{"role": "assistant", "content": content})
			}
			db.Close()
			if got, err := Read(path, "primary-thread"); err == nil {
				t.Fatalf("accepted %s: %#v", kind, got)
			}
		})
	}
}

func TestExportDoesNotIncludePrivateRecords(t *testing.T) {
	path := filepath.Join(t.TempDir(), "export.json")
	body := `{"schema_version":"ATIF-v1.7","session_id":"export-thread","steps":[
	{"source":"system","message":"private system"},
	{"source":"user","message":"question"},
	{"source":"agent","message":"checking","reasoning_content":"private reasoning","tool_calls":[{"arguments":"private arguments"}]},
	{"source":"agent","message":"answer","reasoning_content":"private reasoning","observation":"private result"}]}`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := Read(path, "export-thread")
	if err != nil {
		t.Fatal(err)
	}
	want := []Message{{Role: "user", Text: "question"}, {Role: "assistant", Text: "checking"}, {Role: "assistant", Text: "answer", Phase: "final_answer"}}
	if !reflect.DeepEqual(got.Messages, want) {
		t.Fatalf("export = %#v", got)
	}
	if _, err := Read(path, "other-thread"); err == nil {
		t.Fatal("mismatched export identity accepted")
	}
}

func TestSessionIdentifiersAndProfileLocation(t *testing.T) {
	for _, id := range []string{"gentle-birch", "abc123", "019f9bfd-86da-7133-8213-39aa87079768"} {
		if !ValidSessionID(id) {
			t.Fatalf("rejected %q", id)
		}
	}
	for _, id := range []string{"", "../other", "--continue", "id with spaces", "id\nother", strings.Repeat("x", 129)} {
		if ValidSessionID(id) {
			t.Fatalf("accepted %q", id)
		}
	}
	if got := DataDirectory("/home/user", "/profiles/data"); got != "/profiles/data/devin/cli" {
		t.Fatal(got)
	}
}
