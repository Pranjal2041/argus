// Package session defines the backend-agnostic seam (DESIGN.md L1
// "SessionProvider") that the broker consumes. A Provider owns one host's
// sessions; a Session is one live, attachable session. tmux (Unix) and ConPTY
// (Windows) each implement these so the broker, protocol, and clients never
// know which backend is underneath.
package session

import "context"

// Output is a chunk of raw bytes produced by a session's pane — or, when
// Cols/Rows are non-zero, an in-band SIZE EVENT: the pane was resized (by any
// tmux client, this broker, or another viewer) and all output after this event
// is formatted for the new width. In-band ordering matters: bytes generated
// before the resize must be rendered at the old size, bytes after at the new.
type Output struct {
	Pane string // backend pane id (tmux "%0"); a constant for single-pane backends
	Data []byte
	Cols int // >0 with Rows: size event (Data is empty)
	Rows int
}

// Info describes one session for the client's sidebar (JSON shape is the wire
// contract — do not change tags without updating the clients).
type Info struct {
	Name     string `json:"name"`
	Windows  int    `json:"windows"`
	Attached bool   `json:"attached"`
	Activity int64  `json:"activity"` // unix seconds of last activity
	Path     string `json:"path"`     // active pane cwd (folder grouping)
	State    string `json:"state"`    // attention: working | waiting | idle
	Agent    bool   `json:"agent"`    // created by the mesh (ut spawn): hidden by default and auto-reaped after completion
	Hidden   bool   `json:"hidden"`   // user-hidden in a client UI; broker-owned so the hide syncs across devices
	ID       string `json:"id"`       // backend's STABLE session handle (tmux $N): unchanged across rename, so clients connect by it to survive a rename across any reconnect
}

// Session is one live session the broker streams to/from clients.
type Session interface {
	Output() <-chan Output // raw pane bytes + in-band size events (closed when the session ends)
	SendKeys(pane string, data []byte) error
	Resize(cols, rows int) error
	Size() (cols, rows int) // the pane's CURRENT size (0,0 if unknown)
	Snapshot() []byte       // current screen to prime a freshly-connected client
	Pane() string           // default pane id for input routing
	Close()                 // detach this control client (session itself persists)
}

// ExecRequest runs a command on this host (the mesh's remote-exec primitive).
// With Session set, the command runs INSIDE that persistent shell — preserving
// its env, cwd, and any activated venv — instead of a fresh process.
type ExecRequest struct {
	Cmd        string // the command line(s) to run; arbitrary content (may be multi-line)
	Session    string // run inside this persistent session's shell; "" = one-shot fresh process
	Dir        string // working dir for a one-shot exec (ignored when Session is set)
	TimeoutSec int    // 0 → a sane default
}

// ExecResult is the captured outcome of an ExecRequest.
type ExecResult struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	Exit     int    `json:"exit"`
	TimedOut bool   `json:"timedOut"`
	Error    string `json:"error,omitempty"` // setup failure (couldn't run at all)
}

// Provider owns all sessions on one host (a tmux server, or the ConPTY set).
type Provider interface {
	List() []Info
	Create(name, dir string) error
	Kill(name string) error
	Rename(from, to string) error
	Has(name string) bool
	SetHistoryLimit(lines int)
	Dial(ctx context.Context, name string) (Session, error) // attach (creating the control client)
	Exec(req ExecRequest) ExecResult                        // run a command on this host (mesh primitive)
	SendText(session, text string, enter bool) error        // type text into a session (fire-and-forget)
	Spawn(name, dir, cmd string, idleSec int) error         // create an agent session RUNNING cmd; idleSec=0 skips early cleanup, not the hard maximum
	ReapAgents() []string                                   // remove finished agent sessions after idle cleanup or the hard maximum; returns reaped names
}

const (
	// DefaultReapIdleSec is how long a finished `ut spawn` session may sit at
	// its shell prompt before the reaper removes it. `--idle` overrides this;
	// zero disables this shorter idle cleanup.
	DefaultReapIdleSec = 6 * 3600

	// MaxAgentRetentionSec is the hard limit for retaining a finished agent
	// session. It applies even when `--idle 0` was requested. A job that has not
	// finished is never eligible for either cleanup rule.
	MaxAgentRetentionSec = 7 * 24 * 3600
)

// AgentSessionExpired reports whether a finished agent session has reached
// either its requested idle cleanup time or the seven-day hard maximum. The
// caller remains responsible for proving that the original job finished and
// that no new foreground work is using the retained shell.
func AgentSessionExpired(now, lastActivity, finishedAt int64, idleSec int) bool {
	if finishedAt <= 0 || now < finishedAt {
		return false
	}
	if now-finishedAt >= int64(MaxAgentRetentionSec) {
		return true
	}
	return idleSec > 0 && lastActivity > 0 && now-lastActivity >= int64(idleSec)
}
