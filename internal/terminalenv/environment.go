// Package terminalenv defines the environment boundary between a launcher and
// the interactive terminals it owns. A launcher's output policy is not a user
// terminal preference, regardless of which program will run in that terminal.
package terminalenv

import (
	"runtime"
	"strings"
)

// Keep the standalone ut launcher's interactive_color_overrides in sync. Its
// real-tmux integration tests exercise the same contract as the Go providers.
var colorOverrides = [...]string{"NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR"}

// Interactive removes inherited output overrides, without forcing a color mode
// or changing terminal capabilities, credentials, PATH, or application settings.
// User shell initialization and explicit commands run afterward and may set
// their own preferences. Noninteractive exec must retain its original environment.
func Interactive(base []string) []string {
	return interactive(base, runtime.GOOS == "windows")
}

func interactive(base []string, caseInsensitive bool) []string {
	out := make([]string, 0, len(base))
	for _, value := range base {
		key, _, _ := strings.Cut(value, "=")
		if caseInsensitive {
			key = strings.ToUpper(key)
		}
		drop := false
		for _, override := range colorOverrides {
			if key == override {
				drop = true
				break
			}
		}
		if !drop {
			out = append(out, value)
		}
	}
	return out
}

// TmuxNewSession removes stale launcher overrides from the server's inherited
// defaults BEFORE creating the first pane. Cleaning only the tmux client does
// not cover an already-running server. This never respawns a pane or alters the
// environment of a running process; attach-only paths do not call it.
// Global tmux flags (such as -N) must precede the returned command sequence.
func TmuxNewSession(args ...string) []string {
	commands := make([]string, 0, len(colorOverrides)*4+1+len(args))
	for _, key := range colorOverrides {
		commands = append(commands, "set-environment", "-gu", key, ";")
	}
	commands = append(commands, "new-session")
	return append(commands, args...)
}
