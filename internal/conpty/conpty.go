//go:build windows

// Package conpty is the Windows backend for the SessionProvider seam: it hosts
// each session in its own ConPTY-attached PowerShell, owned by the broker so a
// session survives client disconnects (a disconnect just stops streaming). It is
// the ConPtyProvider DESIGN.md anticipated.
//
// Unlike tmux there is no `capture-pane`, so each session keeps a bounded ring
// buffer of its recent raw output; that ring is replayed as the snapshot when a
// client connects (and the resize → redraw fills the rest for TUIs).
package conpty

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/UserExistsError/conpty"

	"universal-tmux/internal/session"
)

const (
	// cmd.exe by default so a Clink autorun (the user's autosuggest + Oh My Posh
	// prompt + zoxide) injects automatically; override with the broker --shell flag.
	defaultShell = "cmd.exe"
	ringMax      = 128 * 1024 // bytes of recent output kept to replay as the snapshot
	// defCols/defRows live in render.go (untagged) so the cross-platform renderer can
	// share the same ConPTY default size.
)

// winSession is one ConPTY-backed session, owned by the Provider.
type winSession struct {
	name  string
	dir   string
	cpty  *conpty.ConPty
	outCh chan session.Output
	once  sync.Once

	agent      bool // created by the mesh (ut spawn / default ut sh): hidden from the UI
	agentShell bool // persistent `ut sh`: seven-day inactivity cleanup instead of completion-based cleanup
	reapIdle   int  // spawned-job idle seconds before early cleanup (0 = retain until the seven-day maximum)
	doneFile   string
	doneAt     int64

	mu      sync.Mutex
	ring    []byte
	modes   modeTracker // DEC private modes, re-emitted in Snapshot so bracketed paste etc. survive attach
	lastOut int64
	cols    int // current ConPTY size (the width all output is formatted for)
	rows    int
}

func (s *winSession) Output() <-chan session.Output { return s.outCh }
func (s *winSession) Pane() string                  { return "%0" }

func (s *winSession) SendKeys(_ string, data []byte) error {
	_, err := s.cpty.Write(data)
	if err == nil && len(data) > 0 {
		s.mu.Lock()
		s.lastOut = time.Now().Unix() // input is activity even before the shell echoes it
		s.mu.Unlock()
	}
	return err
}

func (s *winSession) Resize(cols, rows int) error {
	if cols <= 0 || rows <= 0 || cols > 1000 || rows > 1000 {
		return nil
	}
	if err := s.cpty.Resize(cols, rows); err != nil {
		return err
	}
	s.mu.Lock()
	changed := cols != s.cols || rows != s.rows
	s.cols, s.rows = cols, rows
	s.mu.Unlock()
	if changed {
		// In-band size event so EVERY viewer (not just the one that asked) re-pins
		// its grid to the ConPTY's new size — mirrors the tmux %layout-change path.
		select {
		case s.outCh <- session.Output{Pane: "%0", Cols: cols, Rows: rows}:
		default: // no/slow consumer; the connect-time Size() push covers it
		}
	}
	return nil
}

// Size reports the ConPTY's current dimensions.
func (s *winSession) Size() (int, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cols, s.rows
}

// Snapshot replays the recent raw output; the client's terminal reconstructs the
// screen, and the resize → redraw completes it for full-screen apps.
//
// It is prefixed with clear-screen + clear-scrollback + home (ESC[2J ESC[3J
// ESC[H) so a client may feed it repeatedly — e.g. a redraw on every settled
// resize via opReqSnapshot — without accumulating duplicate output. This mirrors
// the tmux backend's idempotent snapshot.
func (s *winSession) Snapshot() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ring) == 0 {
		return nil
	}
	const prefix = "\x1b[2J\x1b[3J\x1b[H"
	// Re-emit the currently-active DEC private modes (bracketed paste, mouse,
	// cursor, alt-screen, …) so a client attaching to a long-running session
	// restores them even after the mode-set scrolled out of the ring. Without
	// this, bracketed paste was silently off → multi-line pastes lost all but
	// the last line.
	modeSeq := s.modes.restore()
	out := make([]byte, 0, len(prefix)+len(modeSeq)+len(s.ring))
	out = append(out, prefix...)
	out = append(out, modeSeq...)
	out = append(out, s.ring...)
	return out
}

// Close detaches a hub from the session; it does NOT end the session (the
// Provider owns its lifetime — only Kill / process-exit end it).
func (s *winSession) Close() {}

func (s *winSession) closeReal() { s.once.Do(func() { _ = s.cpty.Close() }) }

// readLoop pumps ConPTY output → the ring buffer (always) and → outCh
// (best-effort; the ring covers any drop while no client is attached). It closes
// outCh when the process exits, which ends the hub's pump.
func (s *winSession) readLoop() {
	defer close(s.outCh)
	buf := make([]byte, 32*1024)
	for {
		n, err := s.cpty.Read(buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			s.mu.Lock()
			s.ring = append(s.ring, data...)
			if len(s.ring) > ringMax {
				s.ring = s.ring[len(s.ring)-ringMax:]
			}
			s.modes.feed(data) // track DEC private modes even as they scroll out of the ring
			s.lastOut = time.Now().Unix()
			s.mu.Unlock()
			select {
			case s.outCh <- session.Output{Pane: "%0", Data: data}:
			default: // no/slow consumer — snapshot will carry it
			}
		}
		if err != nil {
			return
		}
	}
}

// Provider implements session.Provider over a set of ConPTY-hosted sessions.
type Provider struct {
	mu       sync.Mutex
	sessions map[string]*winSession
	shell    string // command each session hosts (e.g. "cmd.exe", "powershell.exe -NoLogo")
}

// NewProvider returns an empty ConPTY provider hosting `shell` per session
// (empty → defaultShell).
func NewProvider(shell string) *Provider {
	if strings.TrimSpace(shell) == "" {
		shell = defaultShell
	}
	return &Provider{sessions: make(map[string]*winSession), shell: shell}
}

func (p *Provider) SetHistoryLimit(int) {} // n/a: the ring buffer is fixed-size

func (p *Provider) ListInventory() []session.Info {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]session.Info, 0, len(p.sessions))
	for _, s := range p.sessions {
		s.mu.Lock()
		info := session.Info{
			Name: s.name, Windows: 1, Attached: false,
			Activity: s.lastOut, Path: s.dir,
			Agent: s.agent,
		}
		s.mu.Unlock()
		out = append(out, info)
	}
	return out
}

func (p *Provider) DetectState(name string) string {
	p.mu.Lock()
	s := p.sessions[name]
	p.mu.Unlock()
	if s == nil {
		return "idle"
	}
	s.mu.Lock()
	state := detectState(s.ring)
	s.mu.Unlock()
	return state
}

func (p *Provider) List() []session.Info {
	out := p.ListInventory()
	for i := range out {
		out[i].State = p.DetectState(out[i].Name)
	}
	return out
}

func (p *Provider) Has(name string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, ok := p.sessions[name]
	return ok
}

// Capture renders a session's recent output as plain text for the command-center
// status updater (GET /recent). It implements the broker's optional `capturer`
// capability so the macOS client can summarize Windows sessions too — without it,
// /recent returns "capture not supported" and Windows sessions never get a status.
//
// tmux gets this free from capture-pane over its rendered grid; ConPTY has only the
// raw VT ring, which is a stream of cursor-addressed repaints (not an append log),
// so we emulate it through a vt10x virtual terminal sized to the session and dump
// the screen (see renderRing). `lines` is unused — the visible screen is the bound.
func (p *Provider) Capture(name string, lines int) (string, error) {
	p.mu.Lock()
	s := p.sessions[name]
	p.mu.Unlock()
	if s == nil {
		return "", fmt.Errorf("no such session: %q", name)
	}
	s.mu.Lock()
	ring := append([]byte(nil), s.ring...) // copy so rendering runs off the session lock
	cols, rows := s.cols, s.rows
	s.mu.Unlock()
	return renderRing(ring, cols, rows), nil
}

func (p *Provider) Create(name, dir string) error {
	_, _, err := p.create(name, dir, false, false, 0, "")
	return err
}

// create installs lifecycle metadata before publishing the session in the
// provider map, so a concurrent inventory refresh can never observe an agent
// shell/job as a transient user-visible panel.
func (p *Provider) create(name, dir string, agent, agentShell bool, reapIdle int, doneFile string) (*winSession, bool, error) {
	p.mu.Lock()
	if s, ok := p.sessions[name]; ok { // attach-or-create: existing is a no-op
		p.mu.Unlock()
		return s, false, nil
	}

	if dir == "" {
		dir, _ = os.UserHomeDir()
	}
	cpty, err := conpty.Start(p.shell,
		conpty.ConPtyDimensions(defCols, defRows),
		conpty.ConPtyWorkDir(dir))
	if err != nil {
		p.mu.Unlock()
		return nil, false, fmt.Errorf("start ConPTY for %q: %w", name, err)
	}
	s := &winSession{
		name: name, dir: dir, cpty: cpty,
		outCh: make(chan session.Output, 256), lastOut: time.Now().Unix(),
		cols: defCols, rows: defRows,
		agent: agent, agentShell: agentShell, reapIdle: reapIdle, doneFile: doneFile,
	}
	p.sessions[name] = s
	p.mu.Unlock()

	go s.readLoop()
	go func() { // remove the session when its process exits
		_, _ = cpty.Wait(context.Background())
		p.remove(name)
	}()
	return s, true, nil
}

// CreateAgentShell creates the persistent stateful shell used by `ut sh` and
// marks it as mesh-owned. Existing sessions retain their original provenance;
// invoking `ut sh` must not silently hide a user-created panel with the same
// name.
func (p *Provider) CreateAgentShell(name, dir string) error {
	_, _, err := p.create(name, dir, true, true, 0, "")
	return err
}

func (p *Provider) Kill(name string) error {
	p.remove(name)
	return nil
}

func (p *Provider) remove(name string) {
	p.mu.Lock()
	s := p.sessions[name]
	delete(p.sessions, name)
	p.mu.Unlock()
	if s != nil {
		s.mu.Lock()
		doneFile := s.doneFile
		s.mu.Unlock()
		if doneFile != "" {
			_ = os.Remove(doneFile)
		}
		s.closeReal() // ends readLoop → closes outCh
	}
}

func (p *Provider) Rename(from, to string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	s, ok := p.sessions[from]
	if !ok {
		return fmt.Errorf("no such session %q", from)
	}
	if _, exists := p.sessions[to]; exists {
		return fmt.Errorf("session %q already exists", to)
	}
	delete(p.sessions, from)
	s.name = to
	p.sessions[to] = s
	return nil
}

func (p *Provider) Dial(_ context.Context, name string) (session.Session, error) {
	p.mu.Lock()
	s, ok := p.sessions[name]
	p.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("no such session %q", name)
	}
	return s, nil
}

// Spawn creates a session, then writes the command into its shell. (A future
// pass can start the ConPTY with the command directly, like the tmux backend.)
// It is tagged as an agent session (hidden from the UI, idle-reaped after
// idleSec seconds of no activity; 0 retains the finished shell until the
// seven-day maximum). A private completion file lets the reaper distinguish a
// silent live command from a finished command waiting at its prompt.
func (p *Provider) Spawn(name, dir, cmd string, idleSec int) error {
	done, err := os.CreateTemp("", "ut-agent-done-*")
	if err != nil {
		return fmt.Errorf("prepare completion marker: %w", err)
	}
	doneFile := done.Name()
	_ = done.Close()
	_ = os.Remove(doneFile)

	s, _, err := p.create(name, dir, true, false, idleSec, doneFile)
	if err != nil {
		_ = os.Remove(doneFile)
		return err
	}
	// An existing session retains Spawn's historical attach-and-run behavior;
	// update its metadata now. A newly created session already carried these
	// fields before it became observable.
	s.mu.Lock()
	oldDoneFile := s.doneFile
	s.agent = true
	s.agentShell = false
	s.reapIdle = idleSec
	s.doneFile = doneFile
	s.doneAt = 0
	s.mu.Unlock()
	if oldDoneFile != "" && oldDoneFile != doneFile {
		_ = os.Remove(oldDoneFile)
	}
	time.Sleep(400 * time.Millisecond) // let the shell come up before typing
	return p.SendText(name, commandWithDoneFile(p.shell, cmd, doneFile), true)
}

func commandWithDoneFile(shell, cmd, path string) string {
	lowerShell := strings.ToLower(shell)
	if strings.Contains(lowerShell, "powershell") || strings.Contains(lowerShell, "pwsh") {
		return cmd + "; Set-Content -LiteralPath '" + strings.ReplaceAll(path, "'", "''") + "' -Value done"
	}
	if strings.Contains(lowerShell, "cmd") {
		return cmd + " & (echo done>\"" + path + "\")"
	}
	return cmd + "; printf done > '" + strings.ReplaceAll(path, "'", "'\"'\"'") + "'"
}

// ReapAgents removes finished spawned jobs after their requested idle time or
// seven-day maximum, and persistent agent shells after seven days without
// activity. The completion file proves a spawned command returned; the visible
// "working" guard protects both a silent live command and a new command started
// in a retained shell. Returns reaped names. Called periodically by the broker.
func (p *Provider) ReapAgents() []string {
	now := time.Now().Unix()
	var stale []string
	p.mu.Lock()
	for name, s := range p.sessions {
		s.mu.Lock()
		if s.doneAt <= 0 && s.doneFile != "" {
			if info, err := os.Stat(s.doneFile); err == nil {
				s.doneAt = info.ModTime().Unix()
			}
		}
		expired := false
		if s.agent {
			if s.agentShell {
				expired = session.AgentShellExpired(now, s.lastOut)
			} else {
				expired = session.AgentSessionExpired(now, s.lastOut, s.doneAt, s.reapIdle)
			}
		}
		idle := expired && detectState(s.ring) != "working"
		s.mu.Unlock()
		if idle {
			stale = append(stale, name)
		}
	}
	p.mu.Unlock()
	for _, name := range stale {
		p.remove(name)
	}
	return stale
}

// SendText writes text (and optionally a carriage return) into a session's
// ConPTY — fire-and-forget input for `ut spawn` / `ut send`.
func (p *Provider) SendText(name, text string, enter bool) error {
	p.mu.Lock()
	s, ok := p.sessions[name]
	p.mu.Unlock()
	if !ok {
		return fmt.Errorf("no such session %q", name)
	}
	data := text
	if enter {
		data += "\r"
	}
	return s.SendKeys("%0", []byte(data))
}

// Exec runs a command on this Windows host. One-shot only for now (fresh
// process via the shell); in-session exec (capturing output from a live ConPTY
// shell while preserving its env) is a follow-up.
func (p *Provider) Exec(req session.ExecRequest) session.ExecResult {
	if req.Session != "" {
		return session.ExecResult{Error: "in-session exec not yet supported on Windows; use a one-shot exec or attach the session", Exit: -1}
	}
	timeout := time.Duration(req.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = 120 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	shell := p.shell
	if strings.TrimSpace(shell) == "" {
		shell = defaultShell
	}
	c := exec.CommandContext(ctx, "cmd", "/c", req.Cmd)
	if strings.Contains(strings.ToLower(shell), "powershell") {
		c = exec.CommandContext(ctx, "powershell", "-NoProfile", "-Command", req.Cmd)
	}
	if req.Dir != "" {
		c.Dir = req.Dir
	}
	var so, se bytes.Buffer
	c.Stdout = &so
	c.Stderr = &se
	err := c.Run()
	res := session.ExecResult{Stdout: so.String(), Stderr: se.String()}
	if ctx.Err() == context.DeadlineExceeded {
		res.TimedOut = true
		res.Exit = 124
		return res
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			res.Exit = ee.ExitCode()
		} else {
			res.Exit = 1
		}
	}
	return res
}

// --- attention-state detection: the agent's OSC window-title spinner ---------
//
// A running turn animates a braille spinner in the WINDOW TITLE via OSC 0/2 — e.g.
// `ESC]0;⠴ research BEL`, re-emitted ~10x/s — and the agent emits one final
// non-spinner title (`ESC]0;research BEL`) the instant the turn ends. Unlike the
// "esc to interrupt" footer (which the TUI cell-diffs and almost never re-emits, so
// it's effectively absent from the byte stream), the title is an explicit escape
// sequence the agent SENDS every frame, so it's reliably in the raw ConPTY output —
// a DETERMINISTIC signal we can read without a rendered screen (ConPTY has no
// capture-pane). Verified on both Codex and Claude on Windows: working titles carry
// a braille glyph; the idle title does not. No recency gate, no screen-scraping.
var titleRe = regexp.MustCompile(`\x1b\][012];([^\x07\x1b]*)(?:\x07|\x1b\\)`)

const titleTailScan = 8192 // bytes of recent output to find the latest window title in

// detectState classifies a ConPTY session from its MOST RECENT OSC window title:
// a braille glyph (U+2800–U+28FF, the animated spinner) means a turn is running.
func detectState(ring []byte) string {
	tail := ring
	if len(tail) > titleTailScan {
		tail = tail[len(tail)-titleTailScan:]
	}
	m := titleRe.FindAllSubmatch(tail, -1)
	if len(m) == 0 {
		return "idle" // no recent window title → no working signal
	}
	for _, r := range string(m[len(m)-1][1]) { // the latest title's text
		if r >= 0x2800 && r <= 0x28FF {
			return "working"
		}
	}
	return "idle"
}
