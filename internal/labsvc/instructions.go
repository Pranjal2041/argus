package labsvc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentInstruction is the one durable project-level instruction installed by
// `ut lab init` and by the human dashboard. Keep one shared copy so the CLI and
// broker action can never drift.
const AgentInstruction = "This project uses Argus Lab. Run `ut lab brief` at the start of work and whenever unsure. Run every experiment through `ut lab run` and append results with `ut lab note` (see `ut lab help`).\n"

// InstructionInstall describes one project instruction file considered by an
// install. Changed is false when the file already carried the Lab instruction.
type InstructionInstall struct {
	Path    string `json:"path"`
	Changed bool   `json:"changed"`
}

// InstallInstructions adds the Lab instruction to CLAUDE.md and AGENTS.md when
// present, or creates AGENTS.md when neither exists. The operation is
// idempotent and deliberately matches `ut lab init`.
func InstallInstructions(cwd string) ([]InstructionInstall, error) {
	info, err := os.Stat(cwd)
	if err != nil {
		return nil, fmt.Errorf("project folder: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("project folder is not a directory: %s", cwd)
	}
	targets := []string{}
	for _, name := range []string{"CLAUDE.md", "AGENTS.md"} {
		if _, err := os.Stat(filepath.Join(cwd, name)); err == nil {
			targets = append(targets, name)
		} else if !os.IsNotExist(err) {
			return nil, err
		}
	}
	if len(targets) == 0 {
		targets = []string{"AGENTS.md"}
	}

	results := make([]InstructionInstall, 0, len(targets))
	for _, name := range targets {
		path := filepath.Join(cwd, name)
		b, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			return results, err
		}
		if strings.Contains(string(b), "ut lab brief") {
			results = append(results, InstructionInstall{Path: path})
			continue
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return results, err
		}
		prefix := "\n"
		if len(b) == 0 {
			prefix = ""
		} else if !strings.HasSuffix(string(b), "\n") {
			prefix = "\n\n"
		}
		if _, err := f.WriteString(prefix + AgentInstruction); err != nil {
			_ = f.Close()
			return results, err
		}
		if err := f.Close(); err != nil {
			return results, err
		}
		results = append(results, InstructionInstall{Path: path, Changed: true})
	}
	return results, nil
}

// InstallSetInstructions is the broker-safe dashboard entry point: the set id
// determines the project folder, so the HTTP caller cannot supply an arbitrary
// path.
func (s *Store) InstallSetInstructions(set string) ([]InstructionInstall, error) {
	meta, err := s.Meta(set)
	if err != nil {
		return nil, err
	}
	return InstallInstructions(meta.Cwd)
}
