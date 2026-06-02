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
	"context"
	"fmt"
	"os"
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
	defCols      = 120
	defRows      = 30
)

// winSession is one ConPTY-backed session, owned by the Provider.
type winSession struct {
	name    string
	dir     string
	cpty    *conpty.ConPty
	outCh   chan session.Output
	once    sync.Once

	mu      sync.Mutex
	ring    []byte
	lastOut int64
}

func (s *winSession) Output() <-chan session.Output { return s.outCh }
func (s *winSession) Pane() string                  { return "%0" }

func (s *winSession) SendKeys(_ string, data []byte) error {
	_, err := s.cpty.Write(data)
	return err
}

func (s *winSession) Resize(cols, rows int) error {
	if cols <= 0 || rows <= 0 || cols > 1000 || rows > 1000 {
		return nil
	}
	return s.cpty.Resize(cols, rows)
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
	out := make([]byte, 0, len(prefix)+len(s.ring))
	out = append(out, prefix...)
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

func (p *Provider) List() []session.Info {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now().Unix()
	out := make([]session.Info, 0, len(p.sessions))
	for _, s := range p.sessions {
		s.mu.Lock()
		info := session.Info{
			Name: s.name, Windows: 1, Attached: false,
			Activity: s.lastOut, Path: s.dir,
			State: detectState(s.ring, s.lastOut, now),
		}
		s.mu.Unlock()
		out = append(out, info)
	}
	return out
}

func (p *Provider) Has(name string) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	_, ok := p.sessions[name]
	return ok
}

func (p *Provider) Create(name, dir string) error {
	p.mu.Lock()
	if _, ok := p.sessions[name]; ok { // attach-or-create: existing is a no-op
		p.mu.Unlock()
		return nil
	}
	p.mu.Unlock()

	if dir == "" {
		dir, _ = os.UserHomeDir()
	}
	cpty, err := conpty.Start(p.shell,
		conpty.ConPtyDimensions(defCols, defRows),
		conpty.ConPtyWorkDir(dir))
	if err != nil {
		return fmt.Errorf("start ConPTY for %q: %w", name, err)
	}
	s := &winSession{
		name: name, dir: dir, cpty: cpty,
		outCh: make(chan session.Output, 256), lastOut: time.Now().Unix(),
	}
	p.mu.Lock()
	p.sessions[name] = s
	p.mu.Unlock()

	go s.readLoop()
	go func() { // remove the session when its process exits
		_, _ = cpty.Wait(context.Background())
		p.remove(name)
	}()
	return nil
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

// --- attention-state detection (no capture-pane on Windows) -----------------
//
// Same signal as the tmux backend: the agent's "esc to interrupt" footer (Claude:
// "… · esc to interrupt"; Codex: "Working (… • esc to interrupt)") means a turn is
// running. But ConPTY hands us the raw output STREAM, not a rendered screen, so we
// can't snapshot the current footer the way tmux capture-pane does. Instead we gate on
// recency (an idle agent stops repainting its footer) and then look for the hint in the
// recent output tail: working = produced output within the window AND that tail shows
// the hint. The recency gate stops a stale hint left in the ring from reading as
// working once the agent goes quiet; the hint check stops a noisy server (which never
// prints it) from reading as working.

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]`)

const (
	interruptHint      = "esc to interrupt"
	workingQuietWindow = 4    // seconds since last output to still treat the screen as live
	ringTailScan       = 8192 // bytes of recent output to scan for the hint
)

// detectState classifies a ConPTY session as "working" or "idle".
func detectState(ring []byte, lastOut, now int64) string {
	if now-lastOut > workingQuietWindow {
		return "idle" // no recent repaint → the agent isn't running
	}
	tail := ring
	if len(tail) > ringTailScan {
		tail = tail[len(tail)-ringTailScan:]
	}
	text := strings.ToLower(ansiRe.ReplaceAllString(string(tail), ""))
	if strings.Contains(text, interruptHint) {
		return "working"
	}
	return "idle"
}
