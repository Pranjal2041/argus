//go:build windows

package recovery

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

func InspectAgentSession(socket, name string) (AgentSession, error) {
	return AgentSession{}, fmt.Errorf("live agent session inspection is not yet supported on Windows")
}

func (s *Store) runtimeEntries() (map[string]Entry, string, error) {
	if s.runtime == nil {
		return nil, "", errors.New("workspace recovery requires the running Windows broker endpoint")
	}
	identity, err := s.runtime.RecoveryIdentity()
	if err != nil {
		return nil, "", err
	}
	entries, err := s.runtime.RecoveryEntries()
	if err != nil {
		return nil, "", err
	}
	current := make(map[string]Entry, len(entries))
	for _, entry := range entries {
		current[entry.Name] = entry
	}
	return current, identity.ServerID, nil
}

// Capture records the user-visible workspace owned by the running ConPTY
// broker. It uses the same snapshot schema and lineage rules as tmux.
func (s *Store) Capture() (Snapshot, error) {
	if s.runtime == nil {
		return Snapshot{}, errors.New("workspace capture requires the running Windows broker")
	}
	identity, err := s.runtime.RecoveryIdentity()
	if err != nil {
		return Snapshot{}, err
	}
	entries, err := s.runtime.RecoveryEntries()
	if err != nil {
		return Snapshot{}, err
	}
	for _, entry := range entries {
		if strings.TrimSpace(entry.Name) == "" || strings.TrimSpace(entry.Directory) == "" {
			return Snapshot{}, errors.New("live session has incomplete recovery identity")
		}
	}
	host := s.Host
	if host == "" {
		host, _ = os.Hostname()
	}
	now := time.Now
	if s.Now != nil {
		now = s.Now
	}
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion,
		ID:            snapshotID(identity.ServerID),
		Host:          host,
		Socket:        s.Socket,
		BootID:        identity.BootID,
		ServerID:      identity.ServerID,
		ServerPID:     identity.ServerPID,
		ServerStarted: identity.ServerStarted,
		CapturedAt:    now().UTC(),
		Entries:       append([]Entry(nil), entries...),
	}
	if err := s.saveCaptured(&snapshot); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

func (s *Store) RunCaptureLoop(ctx context.Context, interval time.Duration, report func(error)) {
	capture := func() {
		_, err := s.Capture()
		if err != nil && report != nil {
			report(err)
		}
	}
	capture()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			capture()
			return
		case <-ticker.C:
			capture()
		}
	}
}

func (s *Store) Status(requestedSnapshot string) Status {
	current, currentServerID, err := s.runtimeEntries()
	if err != nil {
		return Status{Error: err.Error(), TargetHost: s.Host}
	}
	return s.statusWithCurrent(requestedSnapshot, current, currentServerID)
}

func (s *Store) restoreOneRuntime(panel PanelStatus) RestoreResult {
	result := RestoreResult{Name: panel.Name, SessionID: panel.SessionID}
	if s.runtime == nil {
		result.State = RestoreFailed
		result.Detail = "workspace restore requires the running Windows broker"
		return result
	}
	current, _, err := s.runtimeEntries()
	if err != nil {
		result.State = RestoreFailed
		result.Detail = err.Error()
		return result
	}
	fresh := preflight(panel.Entry, current)
	if fresh.State == PanelAlreadyRunning {
		result.State = RestoreAlreadyRunning
		result.Detail = fresh.Detail
		return result
	}
	if fresh.State != PanelReady {
		result.State = RestoreFailed
		result.Detail = fresh.Detail
		return result
	}
	if fresh.Agent != AgentShell {
		result.State = RestoreFailed
		result.Detail = "this backend snapshot does not contain a restorable agent launch"
		return result
	}
	if err := s.runtime.RestoreShell(fresh.Name, fresh.Directory); err != nil {
		result.State = RestoreFailed
		result.Detail = err.Error()
		return result
	}
	current, _, err = s.runtimeEntries()
	live, ok := current[fresh.Name]
	if err != nil || !ok || !entriesMatch(fresh.Entry, live) {
		result.State = RestoreFailed
		result.Detail = "Created, but workspace identity verification failed."
		return result
	}
	result.State = RestoreRestored
	result.Detail = "Interactive shell restored in its original folder."
	return result
}

func (s *Store) Restore(snapshotID string, names []string, concurrency int) RestoreResponse {
	status := s.Status(snapshotID)
	if status.Error != "" || status.Snapshot == nil {
		detail := status.Error
		if detail == "" {
			detail = "recovery snapshot is unavailable"
		}
		return RestoreResponse{SnapshotID: snapshotID, Results: []RestoreResult{{State: RestoreFailed, Detail: detail}}}
	}
	wanted := map[string]bool{}
	for _, name := range names {
		wanted[name] = true
	}
	var panels []PanelStatus
	found := map[string]bool{}
	for _, panel := range status.Panels {
		if (len(wanted) == 0 && panel.State == PanelReady) || wanted[panel.Name] {
			panels = append(panels, panel)
			found[panel.Name] = true
		}
	}
	if concurrency < 1 {
		concurrency = 3
	}
	if concurrency > 6 {
		concurrency = 6
	}
	results := make([]RestoreResult, len(panels))
	sem := make(chan struct{}, concurrency)
	var wait sync.WaitGroup
	for index, panel := range panels {
		wait.Add(1)
		go func(index int, panel PanelStatus) {
			defer wait.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			results[index] = s.restoreOneRuntime(panel)
		}(index, panel)
	}
	wait.Wait()
	for _, name := range names {
		if !found[name] {
			results = append(results, RestoreResult{Name: name, State: RestoreFailed, Detail: "Panel is not present in this recovery snapshot."})
		}
	}
	for _, result := range results {
		if result.State == RestoreRestored || result.State == RestoreAlreadyRunning {
			if _, err := s.Capture(); err != nil {
				results = append(results, RestoreResult{
					State: RestoreFailed, Detail: "Workspace resumed, but the target recovery snapshot could not be saved: " + err.Error(),
				})
			}
			break
		}
	}
	return RestoreResponse{SnapshotID: snapshotID, Results: results}
}

func (s *Store) RestoreCapturedLaunch(snapshotID string, names []string, concurrency int) RestoreResponse {
	results := make([]RestoreResult, 0, len(names))
	for _, name := range names {
		results = append(results, RestoreResult{Name: name, State: RestoreFailed, Detail: "This snapshot does not contain an explicitly reviewable captured launch."})
	}
	if len(results) == 0 {
		results = append(results, RestoreResult{State: RestoreFailed, Detail: "An explicitly reviewed panel name is required."})
	}
	return RestoreResponse{SnapshotID: snapshotID, Results: results}
}

func (s *Store) Bootstrap(sessionName string) error {
	return fmt.Errorf("the Windows broker must already be running to restore its ConPTY workspace")
}
