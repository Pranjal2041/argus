package recovery

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// preflight defines restore safety once for every session backend. A backend
// may supply richer agent evidence, but name conflicts, directories, transcript
// presence, and executable review all follow this shared contract.
func preflight(entry Entry, current map[string]Entry) PanelStatus {
	entry = enrichProcessOwnedSessionEvidence(entry)
	panel := PanelStatus{Entry: entry}
	if live, exists := current[entry.Name]; exists {
		if entriesMatch(entry, live) {
			panel.State = PanelAlreadyRunning
			panel.Detail = "This exact workspace is already running."
			return panel
		}
		panel.State = PanelConflict
		panel.Detail = "A different live session already uses this panel name."
		return panel
	}
	if info, err := os.Stat(entry.Directory); err != nil || !info.IsDir() {
		panel.State = PanelMissingDirectory
		panel.Detail = "The original working directory is no longer available."
		return panel
	}
	if entry.CaptureError != "" {
		panel.State = PanelUnsupported
		panel.Detail = entry.CaptureError
		panel.CapturedLaunchReviewable = capturedLaunchAvailable(entry)
		return panel
	}
	if entry.Agent != AgentShell {
		if entry.SessionPath == "" && entry.SessionEvidence != "resume-argv" && entry.SessionEvidence != SessionEvidenceUserEdit {
			panel.CapturedLaunchReviewable = capturedLaunchAvailable(entry)
			panel.State = PanelMissingSession
			if panel.CapturedLaunchReviewable {
				panel.State = PanelUnsupported
			}
			panel.Detail = "The conversation transcript was not found when this snapshot was recorded."
			return panel
		}
		if entry.SessionEvidence != "resume-argv" && entry.SessionEvidence != SessionEvidenceUserEdit {
			if _, err := os.Stat(entry.SessionPath); err != nil {
				panel.CapturedLaunchReviewable = capturedLaunchAvailable(entry)
				panel.State = PanelMissingSession
				if panel.CapturedLaunchReviewable {
					panel.State = PanelUnsupported
				}
				panel.Detail = "The saved conversation is no longer present on disk."
				return panel
			}
		}
		argv, err := resumeArgv(entry)
		if err != nil {
			panel.State = PanelUnsupported
			panel.Detail = err.Error()
			panel.CapturedLaunchReviewable = capturedLaunchAvailable(entry)
			return panel
		}
		panel.ResumeArgv = argv
		panel.RestoreCommand = shellJoin(argv)
	}
	panel.State = PanelReady
	panel.Selected = true
	if entry.Agent == AgentShell {
		panel.Detail = "Restore an interactive shell in its original folder."
	} else {
		panel.Detail = "Resume the exact saved conversation."
	}
	if entry.CaptureNotice != "" {
		panel.Detail += " " + entry.CaptureNotice
	}
	return panel
}

func applyEntryEdit(entry Entry, edit EntryEdit) (Entry, error) {
	if strings.TrimSpace(edit.Panel) == "" || edit.Panel != entry.Name {
		return Entry{}, fmt.Errorf("recovery edit does not identify panel %q", entry.Name)
	}
	if edit.Directory != nil {
		directory := strings.TrimSpace(*edit.Directory)
		if directory == "" || !filepath.IsAbs(directory) {
			return Entry{}, fmt.Errorf("edited working directory must be an absolute path")
		}
		entry.Directory = filepath.Clean(directory)
	}
	if edit.Agent != nil {
		entry.Agent = strings.ToLower(strings.TrimSpace(*edit.Agent))
	}
	switch entry.Agent {
	case AgentShell:
		entry.AgentPID = 0
		entry.Executable = ""
		entry.Argv = nil
		entry.SessionID = ""
		entry.SessionPath = ""
		entry.SessionEvidence = ""
		entry.CodexHome = ""
		entry.ClaudeConfig = ""
		entry.CaptureError = ""
		return entry, nil
	case AgentCodex, AgentClaude:
	default:
		return Entry{}, fmt.Errorf("edited agent type %q is unsupported", entry.Agent)
	}
	if edit.SessionID != nil {
		entry.SessionID = strings.TrimSpace(*edit.SessionID)
		entry.SessionPath = ""
		entry.SessionEvidence = SessionEvidenceUserEdit
	}
	if !uuidPattern.MatchString(entry.SessionID) {
		return Entry{}, fmt.Errorf("edited %s conversation ID must be a UUID", entry.Agent)
	}
	if edit.Executable != nil {
		entry.Executable = strings.TrimSpace(*edit.Executable)
	}
	executable := entry.Executable
	if executable == "" {
		executable = firstArg(entry.Argv)
	}
	if executable == "" {
		executable = entry.Agent
	}
	if edit.Arguments != nil {
		entry.Argv = append([]string{executable}, (*edit.Arguments)...)
	} else if len(entry.Argv) == 0 {
		entry.Argv = []string{executable}
	} else if edit.Executable != nil {
		entry.Argv = append([]string{executable}, entry.Argv[1:]...)
	}
	if edit.CodexHome != nil {
		entry.CodexHome = strings.TrimSpace(*edit.CodexHome)
	}
	if edit.ClaudeConfig != nil {
		entry.ClaudeConfig = strings.TrimSpace(*edit.ClaudeConfig)
	}
	entry.CaptureError = ""
	return entry, nil
}
