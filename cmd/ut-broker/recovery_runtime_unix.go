//go:build !windows

package main

import (
	"universal-tmux/internal/broker"
	"universal-tmux/internal/recovery"
)

// Unix recovery can inspect tmux even before the HTTP broker exists, so it does
// not need an in-process runtime adapter.
func newRecoveryRuntime(*broker.Manager) recovery.WorkspaceRuntime { return nil }
