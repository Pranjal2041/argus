//go:build !windows

package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// MigrateLegacyVisibility preserves the panels that predate affirmative
// visibility provenance. It runs once per host/socket installation. After the
// marker is written, every newly unmarked direct-tmux session fails closed as a
// background session in ListSessionInventory.
func MigrateLegacyVisibility(socket string) error {
	dir := os.Getenv("UT_VISIBILITY_STATE_DIR")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("resolve home for visibility migration: %w", err)
		}
		if home == "" {
			return fmt.Errorf("resolve home for visibility migration: empty home")
		}
		dir = filepath.Join(home, ".universal-tmux")
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	component := func(value string) string {
		return strings.Map(func(r rune) rune {
			if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
				return r
			}
			return '_'
		}, value)
	}
	marker := filepath.Join(dir, "visibility-v2-"+component(host)+"-"+component(socket))
	if _, err := os.Stat(marker); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}

	out, err := exec.Command("tmux", tmuxArgs(socket, "list-sessions", "-F",
		"#{session_name}\t#{@ut_agent}\t#{@ut_visible}")...).CombinedOutput()
	if err != nil {
		// No tmux server yet is a valid first launch. Record completion so a later
		// direct-tmux session cannot be grandfathered merely by starting first.
		message := strings.ToLower(string(out))
		if !strings.Contains(message, "no server running") && !strings.Contains(message, "failed to connect") {
			return fmt.Errorf("inspect legacy visibility: %v: %s", err, strings.TrimSpace(string(out)))
		}
		return writeVisibilityMarker(dir, marker, "no legacy server\n")
	}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		fields := strings.SplitN(line, "\t", 3)
		if len(fields) != 3 || fields[0] == "" || isInternalSession(fields[0]) || fields[1] == "1" || fields[2] == "1" {
			continue
		}
		args := tmuxArgs(socket,
			"set-option", "-t", literalSessionTarget(fields[0]), optVisible, "1",
			";", "set-option", "-t", literalSessionTarget(fields[0]), optOrigin, "legacy-migration",
		)
		if output, err := exec.Command("tmux", args...).CombinedOutput(); err != nil {
			return fmt.Errorf("mark legacy session %q visible: %v: %s", fields[0], err, strings.TrimSpace(string(output)))
		}
	}
	return writeVisibilityMarker(dir, marker, "legacy sessions marked visible\n")
}

func writeVisibilityMarker(dir, marker, contents string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".visibility-v2-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(contents); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, marker)
}
