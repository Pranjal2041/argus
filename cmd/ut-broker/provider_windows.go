//go:build windows

package main

import (
	"universal-tmux/internal/conpty"
	"universal-tmux/internal/session"
)

// makeProvider returns the ConPTY-backed session provider on Windows. The
// tmux-socket flag is ignored (there is no tmux server); sessions are ConPTY
// processes owned by the broker, each hosting `shell` (default cmd.exe).
func makeProvider(_ string, shell string) session.Provider {
	return conpty.NewProvider(shell)
}
