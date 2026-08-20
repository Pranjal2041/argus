//go:build !windows

package main

import (
	"log"

	"universal-tmux/internal/session"
	"universal-tmux/internal/tmux"
)

// makeProvider returns the tmux-backed session provider on Unix. The `--tmux-socket`
// flag selects the dedicated tmux server; `shell` is ignored (tmux picks the shell).
func makeProvider(socket string, _ string) session.Provider {
	if err := tmux.MigrateLegacyVisibility(socket); err != nil {
		log.Printf("warn: legacy panel visibility migration: %v", err)
	}
	return tmux.NewProvider(socket)
}
