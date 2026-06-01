// Package session defines the backend-agnostic seam (DESIGN.md L1
// "SessionProvider") that the broker consumes. A Provider owns one host's
// sessions; a Session is one live, attachable session. tmux (Unix) and ConPTY
// (Windows) each implement these so the broker, protocol, and clients never
// know which backend is underneath.
package session

import "context"

// Output is a chunk of raw bytes produced by a session's pane.
type Output struct {
	Pane string // backend pane id (tmux "%0"); a constant for single-pane backends
	Data []byte
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
}

// Session is one live session the broker streams to/from clients.
type Session interface {
	Output() <-chan Output             // raw pane bytes (closed when the session ends)
	SendKeys(pane string, data []byte) error
	Resize(cols, rows int) error
	Snapshot() []byte                  // current screen to prime a freshly-connected client
	Pane() string                      // default pane id for input routing
	Close()                            // detach this control client (session itself persists)
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
}
