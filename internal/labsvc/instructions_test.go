package labsvc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallInstructionsCreatesAndDoesNotDuplicateAgentsFile(t *testing.T) {
	dir := t.TempDir()
	first, err := InstallInstructions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 || !first[0].Changed || filepath.Base(first[0].Path) != "AGENTS.md" {
		t.Fatalf("unexpected first install: %+v", first)
	}
	second, err := InstallInstructions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 1 || second[0].Changed {
		t.Fatalf("second install should be unchanged: %+v", second)
	}
	b, err := os.ReadFile(filepath.Join(dir, "AGENTS.md"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(b), "ut lab brief") != 1 {
		t.Fatalf("instruction duplicated: %q", b)
	}
}

func TestInstallInstructionsUpdatesBothExistingInstructionFiles(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"CLAUDE.md", "AGENTS.md"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("# Project\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	results, err := InstallInstructions(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 2 || !results[0].Changed || !results[1].Changed {
		t.Fatalf("unexpected install results: %+v", results)
	}
	for _, result := range results {
		b, err := os.ReadFile(result.Path)
		if err != nil || !strings.Contains(string(b), AgentInstruction) {
			t.Fatalf("instruction missing from %s: %v %q", result.Path, err, b)
		}
	}
}

func TestProviderSpecificInstructionsDoNotSuppressSharedAgentContract(t *testing.T) {
	for _, initial := range []string{"CLAUDE.md", "AGENTS.md"} {
		t.Run(initial, func(t *testing.T) {
			dir := t.TempDir()
			original := "# Existing project rules\nPreserve this instruction.\n"
			if err := os.WriteFile(filepath.Join(dir, initial), []byte(original), 0o644); err != nil {
				t.Fatal(err)
			}
			for pass := 0; pass < 2; pass++ {
				if _, err := InstallInstructions(dir); err != nil {
					t.Fatal(err)
				}
			}
			shared, err := os.ReadFile(filepath.Join(dir, "AGENTS.md"))
			if err != nil || strings.Count(string(shared), AgentInstruction) != 1 {
				t.Fatalf("missing or duplicated shared contract: %v %q", err, shared)
			}
			kept, err := os.ReadFile(filepath.Join(dir, initial))
			if err != nil || !strings.HasPrefix(string(kept), original) || strings.Count(string(kept), AgentInstruction) != 1 {
				t.Fatalf("existing instructions changed or duplicated: %v %q", err, kept)
			}
		})
	}
}
