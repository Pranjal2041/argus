package tmux

import (
	"context"
	"os/exec"
	"testing"
)

func tmuxIdentityTestProvider(t *testing.T) (*Provider, string) {
	t.Helper()
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	socket := "ut-identity-test-" + t.Name()
	provider := NewProvider(socket)
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	return provider, socket
}

func TestHasSessionDoesNotTreatStableIDAsExactName(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Create("alpha", ""); err != nil {
		t.Fatalf("create alpha: %v", err)
	}
	id := provider.List()[0].ID
	if id == "" {
		t.Fatal("alpha has no stable id")
	}
	if provider.Has(id) {
		t.Fatalf("Has(%q) = true: a stable id is not a literal session name", id)
	}
}

func TestSessionLineageSurvivesRename(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Create("alpha", ""); err != nil {
		t.Fatalf("create alpha: %v", err)
	}
	before := provider.ListInventory()[0]
	if before.LineageID == "" {
		t.Fatal("alpha has no lineage id")
	}
	if err := provider.Rename("alpha", "beta"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	after := provider.ListInventory()[0]
	if after.ID != before.ID || after.LineageID != before.LineageID {
		t.Fatalf("rename changed identity: before=%+v after=%+v", before, after)
	}
}

func TestSessionLineageDistinguishesTmuxIDReuseAfterServerRestart(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	if err := provider.Create("before", ""); err != nil {
		t.Fatalf("create before: %v", err)
	}
	before := provider.ListInventory()[0]
	if err := exec.Command("tmux", "-L", socket, "kill-server").Run(); err != nil {
		t.Fatalf("kill first server: %v", err)
	}
	if err := provider.Create("after", ""); err != nil {
		t.Fatalf("create after: %v", err)
	}
	after := provider.ListInventory()[0]
	if before.ID != after.ID {
		t.Fatalf("fixture did not reuse a transport id: before=%q after=%q", before.ID, after.ID)
	}
	if before.LineageID == after.LineageID {
		t.Fatalf("reused transport id also reused lineage: %q", before.LineageID)
	}
}

func TestSessionForIDRejectsLiteralNameAfterIDDies(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Create("alpha", ""); err != nil {
		t.Fatalf("create alpha: %v", err)
	}
	id := provider.List()[0].ID
	// Keep the tmux server alive after alpha dies so its id counter does not reset;
	// the literal "$0" fixture must receive a DIFFERENT underlying id.
	if err := provider.Create("keeper", ""); err != nil {
		t.Fatalf("create keeper: %v", err)
	}
	if err := provider.Kill("alpha"); err != nil {
		t.Fatalf("kill alpha: %v", err)
	}
	if err := provider.Create(id, ""); err != nil {
		t.Fatalf("create literal %q fixture: %v", id, err)
	}
	if got, ok := provider.SessionForID(id); ok {
		t.Fatalf("SessionForID(%q) = %q: matched a literal name with a different id", id, got)
	}
}

func TestDialMissingSessionCannotCreateIt(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	client, err := provider.Dial(context.Background(), "missing")
	if client != nil {
		client.Close()
	}
	if err == nil {
		t.Fatal("Dial(missing) succeeded; Dial must be attach-only")
	}
	if provider.Has("missing") {
		t.Fatal("Dial(missing) created a session")
	}
}

func TestDialExistingSessionStillAttaches(t *testing.T) {
	provider, _ := tmuxIdentityTestProvider(t)
	if err := provider.Create("alpha", ""); err != nil {
		t.Fatalf("create alpha: %v", err)
	}
	client, err := provider.Dial(context.Background(), "alpha")
	if err != nil {
		t.Fatalf("Dial(alpha): %v", err)
	}
	client.Close()
	if !provider.Has("alpha") {
		t.Fatal("closing the control client killed the underlying session")
	}
}
