package broker

import (
	"os/exec"
	"testing"

	"universal-tmux/internal/tmux"
)

// resolveTarget maps a stable tmux session id ($N) to the session's CURRENT
// name and keeps mapping it correctly across a rename — the property that lets
// a client's reconnect survive a rename. Plain names and dead ids pass through
// unchanged (so the Has() guard still rejects a renamed-away NAME / dead id).
func TestResolveTargetFollowsRename(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not installed")
	}
	const socket = "ut-resolve-test"
	prov := tmux.NewProvider(socket)
	defer exec.Command("tmux", "-L", socket, "kill-server").Run()

	if err := prov.Create("alpha", ""); err != nil {
		t.Fatalf("create alpha: %v", err)
	}
	m := &Manager{prov: prov}

	var id string
	for _, s := range prov.List() {
		if s.Name == "alpha" {
			id = s.ID
		}
	}
	if len(id) == 0 || id[0] != '$' {
		t.Fatalf("expected a $N id for alpha, got %q", id)
	}

	if got := m.resolveTarget(id); got != "alpha" {
		t.Fatalf("resolveTarget(%q) = %q, want alpha", id, got)
	}

	// Rename, then resolve the SAME id again — it must follow to the new name.
	if err := prov.Rename("alpha", "beta"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if got := m.resolveTarget(id); got != "beta" {
		t.Fatalf("after rename resolveTarget(%q) = %q, want beta", id, got)
	}

	// A plain name passes through unchanged.
	if got := m.resolveTarget("beta"); got != "beta" {
		t.Fatalf("name passthrough = %q, want beta", got)
	}
	// A dead id is left as-is so the downstream Has() guard rejects it.
	if got := m.resolveTarget("$99999"); got != "$99999" {
		t.Fatalf("dead id passthrough = %q, want $99999", got)
	}
}
