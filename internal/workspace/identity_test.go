package workspace

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestInstallationRootsIgnoreClonedOrMissingOSIdentity(t *testing.T) {
	state := t.TempDir()
	for _, machineID := range []string{"cloned-os-identity", ""} {
		t.Run("machine="+machineID, func(t *testing.T) {
			machine := func() string { t.Fatal("runtime identity must not consult the OS"); return machineID }
			a, err := resolveRoot(state, "ut", "", "runtime:installation-a", machine)
			if err != nil {
				t.Fatal(err)
			}
			b, err := resolveRoot(state, "ut", "", "runtime:installation-b", machine)
			if err != nil {
				t.Fatal(err)
			}
			if a == b {
				t.Fatal("distinct installations share a root")
			}
			again, err := resolveRoot(state, "ut", "", "runtime:installation-a", machine)
			if err != nil || again != a {
				t.Fatalf("unstable root: %q %v", again, err)
			}
			// Exercise the shared store boundary, not only path generation: both
			// installations must be usable concurrently and keep distinct IDs.
			first, err := Open(a)
			if err != nil {
				t.Fatal(err)
			}
			defer first.Close()
			second, err := Open(b)
			if err != nil {
				t.Fatal(err)
			}
			defer second.Close()
			one, err := first.Info()
			if err != nil {
				t.Fatal(err)
			}
			two, err := second.Info()
			if err != nil {
				t.Fatal(err)
			}
			if one.BrokerID == two.BrokerID {
				t.Fatal("distinct installations share a broker ID")
			}
		})
	}
}

func TestLocalIdentityAndExplicitOverridesKeepExistingRoots(t *testing.T) {
	state := t.TempDir()
	for _, tc := range []struct{ name, override, runtime, machine, want string }{
		{"local", "", "", "existing-os", "existing-os"},
		{"explicit", " explicit-install ", "runtime:any", "cloned", "explicit-install"},
		{"explicit-without-os", "explicit-install", "", "", "explicit-install"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, err := resolveRoot(state, "ut", tc.override, tc.runtime, func() string { return tc.machine })
			if err != nil {
				t.Fatal(err)
			}
			h := sha256.Sum256([]byte(tc.want + "\x00ut"))
			want := filepath.Join(state, "workspaces", hex.EncodeToString(h[:16]))
			if root != want {
				t.Fatalf("got %q, want %q", root, want)
			}
		})
	}
	if _, err := resolveRoot(state, "ut", "", "", func() string { return "" }); err == nil {
		t.Fatal("missing installation identity silently minted a new identity")
	}
}

func TestInstallationRootsRespectInstanceNamespaces(t *testing.T) {
	state := t.TempDir()
	seen := map[string]bool{}
	for _, tc := range []struct{ state, socket string }{
		{state, "ut"}, {state, "other"}, {filepath.Join(state, "separate"), "ut"},
	} {
		root, err := resolveRoot(tc.state, tc.socket, "", "runtime:installation", func() string { return "" })
		if err != nil {
			t.Fatal(err)
		}
		if seen[root] {
			t.Fatal("separate state/socket namespaces share a root")
		}
		seen[root] = true
	}
}

func TestRuntimeIdentityMigrationNeverGuessesLegacyOwnership(t *testing.T) {
	state := t.TempDir()
	machine := func() string { return "cloned-os" }
	legacy, err := resolveRoot(state, "ut", "", "", machine)
	if err != nil {
		t.Fatal(err)
	}
	previous, err := Open(legacy)
	if err != nil {
		t.Fatal(err)
	}
	info, err := previous.Info()
	if err != nil {
		t.Fatal(err)
	}
	written, err := previous.Mutate(mutation("preserved", "session-backlog", "session", 0, `{"value":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := previous.Close(); err != nil {
		t.Fatal(err)
	}
	if root, err := resolveInstallationRoot(state, "ut", "", "runtime:owner", machine); err == nil {
		t.Fatalf("silently replaced or claimed legacy identity at %q", root)
	}
	// An operator can explicitly choose a fresh root for the other installation.
	other, _ := resolveRoot(state, "ut", "", "runtime:other", machine)
	if err := os.MkdirAll(other, 0700); err != nil {
		t.Fatal(err)
	}
	if root, err := resolveInstallationRoot(state, "ut", "", "runtime:other", machine); err != nil || root != other {
		t.Fatalf("explicit fresh installation rejected: %q %v", root, err)
	}
	if runtime.GOOS == "windows" {
		return
	} // Symlink creation requires a Windows privilege.
	// A verified owner maps the new path to the SAME existing store. No copy,
	// receipt replay, or session lifetime reset is involved.
	canonical, _ := resolveRoot(state, "ut", "", "runtime:owner", machine)
	if err := os.Symlink(legacy, canonical); err != nil {
		t.Fatal(err)
	}
	root, err := resolveInstallationRoot(state, "ut", "", "runtime:owner", machine)
	if err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	after, err := reopened.Info()
	if err != nil || after != info {
		t.Fatalf("migration changed identity: %+v %v", after, err)
	}
	snapshot, err := reopened.Snapshot("")
	if err != nil || len(snapshot.Records) != 1 || snapshot.Cursor != written.Cursor {
		t.Fatalf("migration lost records: %+v %v", snapshot, err)
	}
}

func TestRuntimeRootWithoutOSIdentity(t *testing.T) {
	state := t.TempDir()
	root, err := resolveInstallationRoot(state, "ut", "", "runtime:installation", func() string { return "" })
	if err != nil || root == "" {
		t.Fatalf("missing OS identity broke runtime installation: %q %v", root, err)
	}
}
