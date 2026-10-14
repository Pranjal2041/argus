package rendersource

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"universal-tmux/internal/devinsession"
)

func devinConversation(file candidateFile) (devinsession.Conversation, error) {
	if strings.EqualFold(filepath.Ext(file.path), ".json") && file.sessionID == "" {
		return devinsession.ReadExport(file.path)
	}
	return devinsession.Read(file.path, file.sessionID)
}

func devinMessages(file candidateFile) []message {
	conversation, err := devinConversation(file)
	if err != nil {
		return nil
	}
	var turns []message
	var parts, finals []string
	started := false
	flush := func() {
		if !started {
			return
		}
		selected := parts
		if len(finals) > 0 {
			selected = finals
		}
		turns = append(turns, message{provider: "devin", cwd: conversation.Directory,
			text: strings.TrimSpace(strings.Join(selected, "\n\n"))})
		parts, finals, started = nil, nil, false
	}
	for _, entry := range conversation.Messages {
		if entry.Role == "user" {
			flush()
			started = true
			continue
		}
		if entry.Role != "assistant" {
			continue
		}
		started = true
		if strings.TrimSpace(entry.Text) != "" {
			parts = appendDistinct(parts, entry.Text)
			if entry.Phase == "final_answer" {
				finals = appendDistinct(finals, entry.Text)
			}
		}
	}
	flush()
	var result []message
	for index := len(turns) - 1; index >= 0 && len(result) < maxMessagesPerFile; index-- {
		result = append(result, turns[index])
	}
	return result
}

func devinHistory(ref TranscriptRef) []HistoryEntry {
	conversation, err := devinConversation(candidateFile{path: ref.Path, sessionID: ref.SessionID})
	if err != nil {
		return nil
	}
	var result []HistoryEntry
	for _, entry := range conversation.Messages {
		if (entry.Role == "user" || entry.Role == "assistant") && strings.TrimSpace(entry.Text) != "" {
			result = append(result, HistoryEntry{Role: entry.Role, Text: entry.Text})
		}
	}
	return result
}

func discoverDevin(home, cwd string) []candidateFile {
	root := devinsession.DataDirectory(home, "")
	database := filepath.Join(root, "sessions.db")
	var candidates []candidateFile
	cutoff := time.Now().Add(-candidateMaxAge)
	if sessions, err := devinsession.List(database, 256); err == nil {
		for _, session := range sessions {
			if session.UpdatedAt.Before(cutoff) || (cwd != "" && !samePath(cwd, session.Directory)) {
				continue
			}
			candidates = append(candidates, candidateFile{path: database, provider: "devin",
				sessionID: session.ID, mtime: session.UpdatedAt})
			if len(candidates) == maxCandidateFiles {
				break
			}
		}
	}
	// Export is optional. It uses the same selection contract as a database
	// conversation, not terminal-text reconstruction or a different match floor.
	entries, _ := os.ReadDir(filepath.Join(root, "transcripts"))
	for _, entry := range entries {
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".json") {
			continue
		}
		info, err := entry.Info()
		if err == nil && info.ModTime().After(cutoff) {
			candidates = append(candidates, candidateFile{path: filepath.Join(root, "transcripts", entry.Name()),
				provider: "devin", mtime: info.ModTime()})
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].mtime.After(candidates[j].mtime) })
	return candidates[:min(maxCandidateFiles, len(candidates))]
}
