// Package recovery records enough authoritative live state to reconstruct a
// user's workspace after its owning backend restarts. It restores shells and,
// where process evidence is available, resumable Claude/Codex conversations;
// it is not a process checkpoint and never claims to restore RAM.
package recovery

import "time"

const (
	SchemaVersion = 1
	RetentionDays = 7
)

const (
	AgentShell  = "shell"
	AgentClaude = "claude"
	AgentCodex  = "codex"
)

// AgentSession is the conversation identity proven from process-owned state for
// the live agent in one pane. Agent selects a transcript-format adapter; Path
// is the exact conversation file, never a directory-scan guess.
type AgentSession struct {
	Agent string
	ID    string
	Path  string
}

// Entry is one user-owned tmux session in a recovery snapshot. Argv is the
// kernel-owned argument vector, not a transcript-derived reconstruction.
type Entry struct {
	Name        string   `json:"name"`
	Directory   string   `json:"directory"`
	Agent       string   `json:"agent"`
	AgentPID    int      `json:"agentPid,omitempty"`
	Executable  string   `json:"executable,omitempty"`
	Argv        []string `json:"argv,omitempty"`
	SessionID   string   `json:"sessionId,omitempty"`
	SessionPath string   `json:"sessionPath,omitempty"`
	// SessionEvidence records the process-owned source used to identify the
	// conversation when no transcript file is currently open. Today the only
	// alternate source is an unambiguous `resume <UUID>` selector in kernel argv.
	SessionEvidence string `json:"sessionEvidence,omitempty"`
	CodexHome       string `json:"codexHome,omitempty"`
	ClaudeConfig    string `json:"claudeConfig,omitempty"`
	Windows         int    `json:"windows"`
	Panes           int    `json:"panes"`
	CaptureError    string `json:"captureError,omitempty"`
	CaptureNotice   string `json:"captureNotice,omitempty"`
}

// RecoveryCandidate is one prior workspace that can be inspected or restored
// on the current host. Babel candidates can originate on a different node
// because those nodes share the recovery store and agent transcript storage.
type RecoveryCandidate struct {
	ID         string    `json:"id"`
	Host       string    `json:"host"`
	CapturedAt time.Time `json:"capturedAt"`
	PanelCount int       `json:"panelCount"`
	ReadyCount int       `json:"readyCount"`
}

// Snapshot is the latest valid workspace observed for one session-backend
// lifetime. A new backend receives a new ID, even within the same OS boot, so a
// freshly-created empty backend can never overwrite the workspace it replaced.
type Snapshot struct {
	SchemaVersion int       `json:"schemaVersion"`
	ID            string    `json:"id"`
	Host          string    `json:"host"`
	Socket        string    `json:"socket"`
	BootID        string    `json:"bootId"`
	ServerID      string    `json:"serverId"`
	ServerPID     int       `json:"serverPid"`
	ServerStarted int64     `json:"serverStarted"`
	CapturedAt    time.Time `json:"capturedAt"`
	Entries       []Entry   `json:"entries"`
	// RecoverySourceID binds a new tmux server lifetime to exactly one prior
	// workspace. Once every source entry has been observed intact,
	// RecoveryComplete stays true so a later intentional panel close is not
	// mistaken for another reboot loss.
	RecoverySourceID string `json:"recoverySourceId,omitempty"`
	RecoveryComplete bool   `json:"recoveryComplete,omitempty"`
}

const (
	PanelReady            = "ready"
	PanelAlreadyRunning   = "already-running"
	PanelConflict         = "conflict"
	PanelMissingDirectory = "missing-directory"
	PanelMissingSession   = "missing-session"
	PanelUnsupported      = "unsupported"
)

// PanelStatus is the preflight result presented to the user. RestoreCommand is
// display-only; restoration executes ResumeArgv directly through tmux.
type PanelStatus struct {
	Entry
	State                    string   `json:"state"`
	Detail                   string   `json:"detail,omitempty"`
	ResumeArgv               []string `json:"resumeArgv,omitempty"`
	RestoreCommand           string   `json:"restoreCommand,omitempty"`
	CapturedLaunchReviewable bool     `json:"capturedLaunchReviewable,omitempty"`
	Selected                 bool     `json:"selected"`
}

// Status is the startup offer. Available means at least one panel can be
// restored without overwriting or guessing.
type Status struct {
	Available       bool                `json:"available"`
	Snapshot        *Snapshot           `json:"snapshot,omitempty"`
	Candidates      []RecoveryCandidate `json:"candidates,omitempty"`
	TargetHost      string              `json:"targetHost,omitempty"`
	CurrentServerID string              `json:"currentServerId,omitempty"`
	ReadyCount      int                 `json:"readyCount"`
	Panels          []PanelStatus       `json:"panels"`
	Error           string              `json:"error,omitempty"`
}

const (
	RestoreRestored       = "restored"
	RestoreAlreadyRunning = "already-running"
	RestoreFailed         = "failed"
)

type RestoreResult struct {
	Name      string `json:"name"`
	State     string `json:"state"`
	Detail    string `json:"detail,omitempty"`
	SessionID string `json:"sessionId,omitempty"`
}

type RestoreResponse struct {
	SnapshotID string          `json:"snapshotId"`
	Results    []RestoreResult `json:"results"`
	Bootstrap  string          `json:"bootstrap,omitempty"`
}
