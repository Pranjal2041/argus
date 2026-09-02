//go:build windows

package main

import (
	cryptorand "crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"time"

	"universal-tmux/internal/broker"
	"universal-tmux/internal/recovery"
)

type brokerRecoveryRuntime struct {
	manager  *broker.Manager
	identity recovery.RuntimeIdentity
}

func newRecoveryRuntime(manager *broker.Manager) recovery.WorkspaceRuntime {
	var nonce [16]byte
	if _, err := cryptorand.Read(nonce[:]); err != nil {
		nonce = [16]byte{}
	}
	started := time.Now().Unix()
	return &brokerRecoveryRuntime{
		manager: manager,
		identity: recovery.RuntimeIdentity{
			BootID:        "windows",
			ServerID:      fmt.Sprintf("conpty:%d:%s", started, hex.EncodeToString(nonce[:])),
			ServerPID:     os.Getpid(),
			ServerStarted: started,
		},
	}
}

func (runtime *brokerRecoveryRuntime) RecoveryIdentity() (recovery.RuntimeIdentity, error) {
	return runtime.identity, nil
}

func (runtime *brokerRecoveryRuntime) RecoveryEntries() ([]recovery.Entry, error) {
	sessions := runtime.manager.Sessions()
	entries := make([]recovery.Entry, 0, len(sessions))
	for _, item := range sessions {
		// Mesh-owned sessions follow their separate cleanup contract. Recovery
		// captures the same user-visible workspace boundary as tmux.
		if item.Agent {
			continue
		}
		entries = append(entries, recovery.Entry{
			Name: item.Name, Directory: item.Path, Agent: recovery.AgentShell,
			Windows: item.Windows, Panes: 1,
			CaptureNotice: "The named shell and its starting folder are recoverable; child-process memory is not checkpointed.",
		})
	}
	return entries, nil
}

func (runtime *brokerRecoveryRuntime) RestoreShell(name, directory string) error {
	return runtime.manager.CreateVisible(name, directory)
}
