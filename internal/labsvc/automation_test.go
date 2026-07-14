package labsvc

import "testing"

func TestAutoApprovePendingResolvesKeysAndRunProposals(t *testing.T) {
	store := testStore(t)

	pendingKey, err := store.CreateKeyRequest("new-project", "/tmp/new", "agent-new")
	if err != nil {
		t.Fatal(err)
	}
	ownerRequest, _ := store.CreateKeyRequest("existing-project", "/tmp/existing", "agent-existing")
	owner, err := store.Decide(ownerRequest.Key, true, "", "")
	if err != nil {
		t.Fatal(err)
	}
	run, err := store.NewRun(owner.Set)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(store.RunDir(owner.Set, run), Event{
		Author: "machine", Kind: "proposal", Text: "compare two checkpoints",
		Data: map[string]any{"tier": "full", "argv": []string{"python", "eval.py"}},
	}); err != nil {
		t.Fatal(err)
	}

	result, err := store.AutoApprovePending()
	if err != nil {
		t.Fatal(err)
	}
	if result.Keys != 1 || result.Proposals != 1 {
		t.Fatalf("result = %+v, want one key and one proposal", result)
	}
	key, err := store.Lookup(pendingKey.Key)
	if err != nil {
		t.Fatal(err)
	}
	if key.Status != "active" || key.Set == "" || key.Note != UnattendedApprovalNote {
		t.Fatalf("auto-approved key missing state or audit note: %+v", key)
	}
	decided, approved, note := store.RunDecision(owner.Set, run)
	if !decided || !approved || note != UnattendedApprovalNote {
		t.Fatalf("run decision = decided:%v approved:%v note:%q", decided, approved, note)
	}
	if keys, _ := store.Keys(); len(keys) != 2 {
		t.Fatalf("unexpected key count after sweep: %d", len(keys))
	}
	if proposals, _ := store.PendingProposals(); len(proposals) != 0 {
		t.Fatalf("pending proposals remain: %+v", proposals)
	}
}

func TestDecideRunRejectsDuplicateDecision(t *testing.T) {
	store := testStore(t)
	request, _ := store.CreateKeyRequest("project", "/tmp/project", "agent")
	key, _ := store.Decide(request.Key, true, "", "")
	run, _ := store.NewRun(key.Set)
	_, _ = store.Append(store.RunDir(key.Set, run), Event{Author: "machine", Kind: "proposal", Text: "test"})

	if err := store.DecideRun(key.Set, run, true, "first"); err != nil {
		t.Fatal(err)
	}
	if err := store.DecideRun(key.Set, run, true, "second"); err == nil {
		t.Fatal("duplicate decision unexpectedly succeeded")
	}
	events, _ := store.Events(store.RunDir(key.Set, run), false)
	decisions := 0
	for _, event := range events {
		if event.Kind == "decision" {
			decisions++
		}
	}
	if decisions != 1 {
		t.Fatalf("wrote %d decision events, want 1", decisions)
	}
}
