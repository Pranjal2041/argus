//go:build !windows

package main

import (
	"universal-tmux/internal/session"
	"universal-tmux/internal/tmux"
)

// makeProvider returns the tmux-backed session provider on Unix. The `--tmux-socket`
// flag selects the dedicated tmux server; `shell` is ignored (tmux picks the shell).
func makeProvider(socket string, _ string) session.Provider {
	return tmux.NewProvider(socket)
}
