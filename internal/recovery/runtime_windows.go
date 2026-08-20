//go:build windows

package recovery

import (
	"context"
	"fmt"
	"time"
)

func InspectCodexSession(socket, name string) (CodexSession, error) {
	return CodexSession{}, fmt.Errorf("live Codex session inspection is not yet supported on Windows")
}

// Windows sessions are ConPTY-backed and do not survive a reboot. Conversation
// identity capture will be added when the Windows agent CLIs expose the same
// authoritative process-owned session state used on macOS/Linux.
func (s *Store) Capture() (Snapshot, error) {
	return Snapshot{}, fmt.Errorf("workspace recovery is not yet supported on Windows")
}

func (s *Store) RunCaptureLoop(ctx context.Context, interval time.Duration, report func(error)) {
	<-ctx.Done()
}

func (s *Store) Status(requestedSnapshot string) Status {
	return Status{Error: "workspace recovery is not yet supported on Windows"}
}

func (s *Store) Restore(snapshotID string, names []string, concurrency int) RestoreResponse {
	return RestoreResponse{SnapshotID: snapshotID, Results: []RestoreResult{{State: RestoreFailed, Detail: "workspace recovery is not yet supported on Windows"}}}
}

func (s *Store) Bootstrap(sessionName string) error {
	return fmt.Errorf("workspace recovery is not yet supported on Windows")
}
