package labsvc

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestHideFindsEventInSetOrRun(t *testing.T) {
	s := testStore(t)
	k, _ := s.CreateKeyRequest("p", "/tmp", "")
	ap, _ := s.Decide(k.Key[:8], true, "", "")

	setEv, _ := s.Append(s.SetDir(ap.Set), Event{Author: "agent", Kind: "note", Text: "set-level claim"})
	run, _ := s.NewRun(ap.Set)
	runEv, _ := s.Append(s.RunDir(ap.Set, run), Event{Author: "agent", Kind: "result", Text: "wrong inference"})

	if err := s.Hide(ap.Set, runEv.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Hide(ap.Set, setEv.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.Hide(ap.Set, "01NOPE0000000000000000USED"); err == nil {
		t.Fatal("hiding a missing event should error")
	}
	// agent views drop both; hub views keep everything
	agentSet, _ := s.Events(s.SetDir(ap.Set), true)
	for _, e := range agentSet {
		if e.ID == setEv.ID {
			t.Fatal("hidden set event still visible to agents")
		}
	}
	agentRun, _ := s.Events(s.RunDir(ap.Set, run), true)
	if len(agentRun) != 0 {
		t.Fatalf("hidden run event still visible: %+v", agentRun)
	}
	hubRun, _ := s.Events(s.RunDir(ap.Set, run), false)
	if len(hubRun) != 2 { // the event + its hide marker
		t.Fatalf("hub view lost content: %d events", len(hubRun))
	}
}

func TestHumanNoteScopes(t *testing.T) {
	s := testStore(t)
	k, _ := s.CreateKeyRequest("proj", "/tmp", "")
	ap, _ := s.Decide(k.Key[:8], true, "", "")
	run, _ := s.NewRun(ap.Set)

	for _, c := range []struct{ scope, project, set, run string }{
		{"global", "", "", ""},
		{"project", "proj", "", ""},
		{"machine", "", "", ""},
		{"set", "", ap.Set, ""},
		{"run", "", ap.Set, run},
	} {
		if err := s.HumanNote(c.scope, c.project, c.set, c.run, "note at "+c.scope); err != nil {
			t.Fatalf("scope %s: %v", c.scope, err)
		}
	}
	// invalid inputs error
	if err := s.HumanNote("project", "", "", "", "x"); err == nil {
		t.Fatal("project scope without a name should error")
	}
	if err := s.HumanNote("run", "", ap.Set, "R999", "x"); err == nil {
		t.Fatal("missing run should error")
	}
	if err := s.HumanNote("weird", "", "", "", "x"); err == nil {
		t.Fatal("unknown scope should error")
	}
	// the three broad scopes land in the brief
	b, _ := s.Brief(ap.Set, true)
	if len(b.Notes) != 3 {
		t.Fatalf("want 3 broad-scope notes in the brief, got %d", len(b.Notes))
	}
	// set + run notes are events on their logs
	if evs, _ := s.Events(s.SetDir(ap.Set), true); len(evs) < 2 {
		t.Fatalf("set note missing: %d events", len(evs))
	}
	if evs, _ := s.Events(s.RunDir(ap.Set, run), true); len(evs) != 1 || evs[0].Kind != "hnote" {
		t.Fatalf("run note missing: %+v", evs)
	}
}

func TestMirrorWriteAndRead(t *testing.T) {
	s := testStore(t)
	brief := []byte(`{"set":{"id":"s-abc","project":"p","machine":"babel-x","cwd":"/w","created":"t"},"policy":"full-only","runs":[{"id":"R1","status":"done","exitCode":0}]}`)
	if err := s.WriteMirrorBrief("babel-x", "s-abc", brief); err != nil {
		t.Fatal(err)
	}
	evs := []Event{
		{ID: NewULID(), Author: "machine", Kind: "run-start"},
		{ID: NewULID(), Author: "agent", Kind: "result", Text: "loss 0.4"},
	}
	n, err := s.WriteMirrorEvents("babel-x", "s-abc", "R1", evs)
	if err != nil || n != 2 {
		t.Fatalf("first write: n=%d err=%v", n, err)
	}
	// idempotent: same events add nothing
	n, err = s.WriteMirrorEvents("babel-x", "s-abc", "R1", evs)
	if err != nil || n != 0 {
		t.Fatalf("second write should add 0, got %d (%v)", n, err)
	}
	// a newer brief overwrites; events accumulate
	brief2 := []byte(`{"set":{"id":"s-abc","project":"p","machine":"babel-x","cwd":"/w","created":"t"},"policy":"full-only","runs":[{"id":"R1","status":"done","exitCode":0},{"id":"R2","status":"running","exitCode":-1}]}`)
	if err := s.WriteMirrorBrief("babel-x", "s-abc", brief2); err != nil {
		t.Fatal(err)
	}
	ms, err := s.ReadMirror()
	if err != nil || len(ms) != 1 {
		t.Fatalf("read: %v %+v", err, ms)
	}
	if ms[0].Machine != "babel-x" || ms[0].Set != "s-abc" {
		t.Fatalf("got %+v", ms[0])
	}
	var back struct {
		Runs []struct{ ID string } `json:"runs"`
	}
	if json.Unmarshal(ms[0].Brief, &back) != nil || len(back.Runs) != 2 {
		t.Fatalf("brief did not update: %s", ms[0].Brief)
	}
	// the mirrored event files exist on disk
	evDir := filepath.Join(Root(), "mirror", "babel-x", "sets", "s-abc", "runs", "R1", "events")
	ents, _ := os.ReadDir(evDir)
	if len(ents) != 2 {
		t.Fatalf("want 2 mirrored event files, got %d", len(ents))
	}
}

func TestMirrorPeersOverride(t *testing.T) {
	t.Setenv("UT_LAB_MIRROR_PEERS", "a=http://127.0.0.1:9741, b=http://127.0.0.1:9742")
	m := MirrorPeersOverride()
	if len(m) != 2 || m["a"] != "http://127.0.0.1:9741" || m["b"] != "http://127.0.0.1:9742" {
		t.Fatalf("got %v", m)
	}
	t.Setenv("UT_LAB_MIRROR_PEERS", "")
	if MirrorPeersOverride() != nil {
		t.Fatal("empty env should mean no override")
	}
}

func TestRunFileValidation(t *testing.T) {
	s := testStore(t)
	k, _ := s.CreateKeyRequest("p", "/tmp", "")
	ap, _ := s.Decide(k.Key[:8], true, "", "")
	run, _ := s.NewRun(ap.Set)
	rd := s.RunDir(ap.Set, run)
	os.MkdirAll(filepath.Join(rd, "files"), 0o755)
	os.MkdirAll(filepath.Join(rd, "snapshot"), 0o755)
	os.WriteFile(filepath.Join(rd, "log.txt"), []byte("log"), 0o644)
	os.WriteFile(filepath.Join(rd, "files", "conf.yaml"), []byte("lr: 1"), 0o644)
	os.WriteFile(filepath.Join(rd, "snapshot", "diff.patch"), []byte("--- a"), 0o644)

	for _, ok := range []string{"log.txt", "files/conf.yaml", "snapshot/diff.patch"} {
		if _, err := s.RunFile(ap.Set, run, ok); err != nil {
			t.Fatalf("%s should resolve: %v", ok, err)
		}
	}
	for _, bad := range []string{"../../../etc/passwd", "files/../../keys", "/etc/passwd",
		"files/sub/deep.txt", "events/x.json", "snapshot/../log.txt2"} {
		if _, err := s.RunFile(ap.Set, run, bad); err == nil {
			t.Fatalf("%s should be rejected", bad)
		}
	}
	fl := s.RunFiles(ap.Set, run)
	if len(fl) != 3 {
		t.Fatalf("want 3 files, got %+v", fl)
	}
}
