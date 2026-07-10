package labsvc

import "testing"

// The hub's Notes view: scope-level notes are listed with their scope labels,
// hiding marks them for the human and removes them from agent reads.
func TestListAndHideNotes(t *testing.T) {
	st := testStore(t)

	if err := st.HumanNote("global", "", "", "", "always seed 42"); err != nil {
		t.Fatal(err)
	}
	if err := st.HumanNote("machine", "", "", "", "gpu 3 is flaky here"); err != nil {
		t.Fatal(err)
	}
	// a project dir requires a known project: create one through a key
	k, err := st.CreateKeyRequest("proj-x", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Decide(k.Key[:8], true, "", ""); err != nil {
		t.Fatal(err)
	}
	if err := st.HumanNote("project", "proj-x", "", "", "use the small split"); err != nil {
		t.Fatal(err)
	}

	ns, err := st.ListNotes()
	if err != nil {
		t.Fatal(err)
	}
	byScope := map[string]NoteInfo{}
	for _, n := range ns {
		byScope[n.Scope] = n
	}
	if len(ns) != 3 {
		t.Fatalf("want 3 notes, got %d: %+v", len(ns), ns)
	}
	if byScope["global"].Text != "always seed 42" || byScope["global"].Hidden {
		t.Fatalf("global note wrong: %+v", byScope["global"])
	}
	if byScope["project"].Project != "proj-x" {
		t.Fatalf("project note missing its project: %+v", byScope["project"])
	}

	// hide the machine note: still listed, flagged, gone from agent reads
	if err := st.HideNote("machine", "", byScope["machine"].ID); err != nil {
		t.Fatal(err)
	}
	ns, _ = st.ListNotes()
	var mn *NoteInfo
	for i := range ns {
		if ns[i].Scope == "machine" {
			mn = &ns[i]
		}
	}
	if mn == nil || !mn.Hidden {
		t.Fatalf("hidden machine note not flagged: %+v", mn)
	}
	agentEvs, _ := st.Events(st.NotesDir("machine", Hostname()), true)
	for _, e := range agentEvs {
		if e.ID == mn.ID {
			t.Fatal("hidden note still visible to agents")
		}
	}

	// hiding an unknown note is an error, not a silent success
	if err := st.HideNote("global", "", "nope"); err == nil {
		t.Fatal("expected an error for an unknown target")
	}
}

// Archive is a recorded, reversible view flag on sets and runs; agents'
// briefs still include archived content (it is a human view concern).
func TestArchive(t *testing.T) {
	st := testStore(t)
	k, err := st.CreateKeyRequest("proj-a", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if k, err = st.Decide(k.Key[:8], true, "", ""); err != nil {
		t.Fatal(err)
	}
	run, err := st.NewRun(k.Set)
	if err != nil {
		t.Fatal(err)
	}

	if err := st.SetArchived(k.Set, "", true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetArchived(k.Set, run, true); err != nil {
		t.Fatal(err)
	}
	b, err := st.Brief(k.Set, false)
	if err != nil {
		t.Fatal(err)
	}
	if !b.Archived {
		t.Fatal("set not flagged archived")
	}
	if len(b.Runs) != 1 || !b.Runs[0].Archived {
		t.Fatalf("run not flagged archived: %+v", b.Runs)
	}

	// reversible: the latest event wins
	if err := st.SetArchived(k.Set, "", false); err != nil {
		t.Fatal(err)
	}
	b, _ = st.Brief(k.Set, false)
	if b.Archived {
		t.Fatal("unarchive did not win")
	}

	// unknown targets error rather than silently succeed
	if err := st.SetArchived("s-nope", "", true); err == nil {
		t.Fatal("expected error for unknown set")
	}
	if err := st.SetArchived(k.Set, "R99", true); err == nil {
		t.Fatal("expected error for unknown run")
	}
}
