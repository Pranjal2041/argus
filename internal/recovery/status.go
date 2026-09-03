package recovery

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// statusWithCurrent applies snapshot selection and preflight independently of
// the live session backend. Both tmux and ConPTY feed their current entries into
// this one policy boundary.
func (s *Store) statusWithCurrent(requestedSnapshot string, current map[string]Entry, currentServerID string) Status {
	items, err := s.loadAll()
	if err != nil {
		return Status{Error: err.Error()}
	}
	allItems, err := s.loadCluster()
	if err != nil {
		return Status{Error: err.Error()}
	}
	imported, err := s.loadImported()
	if err != nil {
		return Status{Error: err.Error()}
	}
	var selected *Snapshot
	requestedUnavailable := ""
	if requestedSnapshot != "" {
		available := mergeSnapshots(items, allItems, imported)
		selected = transportSnapshot(available, requestedSnapshot)
		if selected != nil && selected.CapturedAt.Before(s.Now().Add(-RetentionDays*24*time.Hour)) {
			requestedUnavailable = fmt.Sprintf("recovery snapshot %q is older than the %d-day retention window", requestedSnapshot, RetentionDays)
			selected = nil
		}
	} else if currentServerID == "" {
		// Before a backend has restarted, the newest non-empty local manifest is
		// the workspace that disappeared.
		for index := range items {
			if len(items[index].Entries) > 0 {
				selected = &items[index]
				break
			}
		}
	} else {
		var currentSnapshot *Snapshot
		for index := range items {
			if items[index].ServerID == currentServerID {
				currentSnapshot = &items[index]
				break
			}
		}
		if currentSnapshot == nil {
			// Narrow startup race: the backend exists but its first capture has not
			// landed yet.
			for index := range items {
				if len(items[index].Entries) > 0 && items[index].ServerID != currentServerID {
					selected = &items[index]
					break
				}
			}
		} else if currentSnapshot.RecoverySourceID != "" && !currentSnapshot.RecoveryComplete {
			for index := range items {
				if items[index].ID == currentSnapshot.RecoverySourceID {
					selected = &items[index]
					break
				}
			}
		}
	}

	// A status response doubles as a fabric source inventory. Expose the newest
	// non-empty exportable snapshot for every host, including this backend's
	// currently live workspace. Whether it is restorable on the queried target is
	// evaluated separately; a source must not disappear merely because it is live.
	allSnapshots := mergeSnapshots(items, allItems, imported)
	latestByHost := map[string]Snapshot{}
	for _, item := range allSnapshots {
		if item.CapturedAt.Before(s.Now().Add(-RetentionDays * 24 * time.Hour)) {
			continue
		}
		candidate := item
		if len(candidate.Entries) == 0 && candidate.RecoverySourceID != "" && !candidate.RecoveryComplete {
			if source := transportSnapshot(allSnapshots, candidate.RecoverySourceID); source != nil {
				candidate = *source
			}
		}
		if len(candidate.Entries) == 0 {
			continue
		}
		if candidate.ServerID == currentServerID && sameRecoveryHost(candidate.Host, s.Host) {
			live := make([]Entry, 0, len(current))
			for _, entry := range current {
				live = append(live, entry)
			}
			if !entriesSatisfied(candidate.Entries, live) {
				continue
			}
		}
		key := strings.ToLower(strings.TrimSpace(candidate.Host))
		if _, exists := latestByHost[key]; !exists {
			latestByHost[key] = candidate
		}
	}
	unique := map[string]Snapshot{}
	if selected != nil && requestedSnapshot == "" {
		unique[selected.ID] = *selected
	}
	for _, candidate := range latestByHost {
		if len(s.remainingEntries(candidate)) > 0 {
			unique[candidate.ID] = candidate
		}
	}
	candidates := make([]Snapshot, 0, len(unique))
	for _, candidate := range unique {
		candidates = append(candidates, candidate)
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].CapturedAt.After(candidates[j].CapturedAt) })
	if requestedSnapshot == "" && selected == nil && s.Cluster != "" {
		for index := range candidates {
			if !sameRecoveryHost(candidates[index].Host, s.Host) {
				selected = &candidates[index]
				break
			}
		}
	}

	status := Status{Snapshot: selected, CurrentServerID: currentServerID, TargetHost: s.Host}
	for _, candidate := range candidates {
		ready := 0
		remaining := s.remainingEntries(candidate)
		for _, entry := range remaining {
			if preflight(entry, current).State == PanelReady {
				ready++
			}
		}
		status.Candidates = append(status.Candidates, RecoveryCandidate{
			ID: candidate.ID, Host: candidate.Host, CapturedAt: candidate.CapturedAt,
			PanelCount: len(remaining), ReadyCount: ready,
		})
	}
	if selected == nil {
		if requestedSnapshot != "" {
			status.Error = requestedUnavailable
			if status.Error == "" {
				status.Error = fmt.Sprintf("recovery snapshot %q not found", requestedSnapshot)
			}
		}
		return status
	}
	for _, entry := range s.remainingEntries(*selected) {
		panel := preflight(entry, current)
		panel.SuggestedDirectory, panel.SuggestedSessionID = recoverySuggestions(*selected, entry, allSnapshots)
		if panel.State == PanelReady {
			status.ReadyCount++
		}
		status.Panels = append(status.Panels, panel)
	}
	status.Available = status.ReadyCount > 0
	return status
}

// recoverySuggestions follows only explicit recovery lineage. It never guesses
// from an unrelated host or similarly named panel. This lets a user repair an
// old snapshot affected by bad terminal-reported metadata while keeping the
// captured entry immutable and making the correction explicit.
func recoverySuggestions(snapshot Snapshot, entry Entry, all []Snapshot) (directory, sessionID string) {
	needsDirectory := false
	if info, err := os.Stat(entry.Directory); err != nil || !info.IsDir() {
		needsDirectory = true
	}
	needsSessionID := entry.Agent != AgentShell && entry.SessionID == ""
	if !needsDirectory && !needsSessionID {
		return "", ""
	}
	byID := make(map[string]Snapshot, len(all))
	for _, item := range all {
		byID[item.ID] = item
	}
	seen := map[string]bool{snapshot.ID: true}
	for sourceID := snapshot.RecoverySourceID; sourceID != "" && !seen[sourceID]; {
		seen[sourceID] = true
		source, ok := byID[sourceID]
		if !ok {
			break
		}
		for _, candidate := range source.Entries {
			if candidate.Name != entry.Name {
				continue
			}
			if needsDirectory && directory == "" && candidate.Directory != "" && candidate.Directory != entry.Directory {
				if info, err := os.Stat(candidate.Directory); err == nil && info.IsDir() {
					directory = candidate.Directory
				}
			}
			if needsSessionID && sessionID == "" && candidate.Agent == entry.Agent && candidate.SessionID != "" {
				sessionID = candidate.SessionID
			}
			break
		}
		sourceID = source.RecoverySourceID
	}
	return directory, sessionID
}
