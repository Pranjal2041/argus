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
	out := make([]session.Info, 0, len(p.sessions))
	for _, s := range p.sessions {
		s.mu.Lock()
		info := session.Info{
			Name: s.name, Windows: 1, Attached: false,
			Activity: s.lastOut, Path: s.dir,
			State: detectState(s.ring),
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
