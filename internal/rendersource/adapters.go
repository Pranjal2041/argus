package rendersource

import "path/filepath"

// A provider adapter translates storage only. Exact ownership, newest-turn
// barriers, screen corroboration, budgets and terminal fallback stay shared.
type transcriptAdapter struct {
	provider         string
	messages         func(candidateFile) []message
	history          func(TranscriptRef) []HistoryEntry
	discover         func(home, cwd string) []candidateFile
	fallbackDiscover func(home, cwd string) []candidateFile
}

var transcriptAdapters = []transcriptAdapter{
	{
		provider: "codex",
		messages: func(file candidateFile) []message { return codexMessages(file.path) },
		history:  func(ref TranscriptRef) []HistoryEntry { return readHistoryTail(ref.Path, codexHistoryEntry) },
		discover: func(home, cwd string) []candidateFile {
			return discover(filepath.Join(home, ".codex", "sessions"), "codex", cwd)
		},
	},
	{
		provider: "claude",
		messages: func(file candidateFile) []message { return claudeMessages(file.path) },
		history:  func(ref TranscriptRef) []HistoryEntry { return readHistoryTail(ref.Path, claudeHistoryEntry) },
		discover: func(home, cwd string) []candidateFile {
			return discover(filepath.Join(home, ".claude", "projects"), "claude", cwd)
		},
		fallbackDiscover: func(home, cwd string) []candidateFile {
			root := filepath.Join(home, ".claude", "projects")
			// An encoded launch path can differ from the physical cwd. The shared
			// path and screen checks remain authoritative after broadening the scan.
			if _, scoped := claudeProjectRoot(root, cwd); cwd != "" && scoped {
				return discoverCandidates(root, "claude", cwd, false)
			}
			return nil
		},
	},
	{provider: "devin", messages: devinMessages, history: devinHistory, discover: discoverDevin},
}

func adapterFor(provider string) *transcriptAdapter {
	for index := range transcriptAdapters {
		if transcriptAdapters[index].provider == provider {
			return &transcriptAdapters[index]
		}
	}
	return nil
}
