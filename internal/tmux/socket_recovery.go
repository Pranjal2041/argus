package tmux

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Use tmux's resolved endpoint, including TMUX_TMPDIR or an inherited $TMUX,
// rather than guessing a host's temporary directory or server name.
func unavailableSocket(err error) string {
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return ""
	}
	message := strings.TrimSpace(string(exit.Stderr))
	var path string
	if strings.HasPrefix(message, "no server running on ") {
		path = strings.TrimPrefix(message, "no server running on ")
	} else if strings.HasPrefix(message, "error connecting to ") {
		for _, suffix := range []string{" (No such file or directory)", " (Connection refused)"} {
			if strings.HasSuffix(message, suffix) {
				path = strings.TrimSuffix(strings.TrimPrefix(message, "error connecting to "), suffix)
				break
			}
		}
	}
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\r\n\x00") {
		return ""
	}
	return filepath.Clean(path)
}

// All creation paths must first distinguish absence from an unavailable
// transport. Once a server is observed, -N prevents tmux from auto-starting a
// replacement if its socket disappears between the read and new-session.
func sessionCreationArgs(socket, name, dir string) ([]string, bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, running, err := readInventoryOutput(ctx, socket)
	if err != nil {
		return nil, false, fmt.Errorf("refusing session creation without inventory: %w", err)
	}
	exists := false
	for _, line := range strings.Split(string(out), "\n") {
		if first, _, ok := strings.Cut(line, "\t"); ok && first == name {
			exists = true
		}
	}
	args := []string{}
	if running {
		args = append(args, "-N")
	}
	args = append(args, "new-session", "-d", "-s", name)
	if dir != "" {
		args = append(args, "-c", dir)
	}
	return args, exists, nil
}
