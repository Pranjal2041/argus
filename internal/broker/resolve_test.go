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

	if got, ok := m.resolveTarget(id); !ok || got != "alpha" {
		t.Fatalf("resolveTarget(%q) = (%q, %v), want (alpha, true)", id, got, ok)
	}

	// Rename, then resolve the SAME id again — it must follow to the new name.
	if err := prov.Rename("alpha", "beta"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if got, ok := m.resolveTarget(id); !ok || got != "beta" {
		t.Fatalf("after rename resolveTarget(%q) = (%q, %v), want (beta, true)", id, got, ok)
	}

	// A plain name passes through unchanged.
	if got, ok := m.resolveTarget("beta"); !ok || got != "beta" {
		t.Fatalf("name passthrough = (%q, %v), want (beta, true)", got, ok)
	}
	// A dead id must fail closed. Passing it through is unsafe because tmux's
	// supposedly-exact name target still interprets $N as an id.
	if got, ok := m.resolveTarget("$99999"); ok || got != "" {
		t.Fatalf("dead id resolution = (%q, %v), want (empty, false)", got, ok)
	}

	// The stable-id namespace is reserved on tmux backends, so no explicit API
	// call can create the same phantom form either.
	if err := m.Create(id, ""); err == nil {
		t.Fatalf("Create(%q) succeeded; stable handle names must be rejected", id)
	}
}
