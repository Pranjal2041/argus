// Package broker fans tmux control-mode sessions out to WebSocket clients.
// A Manager owns one tmux server (-L socket) and a hub per attached session;
// each hub streams its session to N clients and routes their input back.
// Wire format (DESIGN.md): [opcode u8][paneLen u8][pane][payload].
package broker

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"

	"universal-tmux/internal/session"
)

const (
	opOutput      = 0x01 // server -> client: pane bytes
	opInput       = 0x02 // client -> server: keystrokes
	opResize      = 0x03 // client -> server: payload = cols u16, rows u16 (big-endian)
	opReqSnapshot = 0x04 // client -> server: send a fresh snapshot now (deterministic redraw)
	opPaneSize    = 0x05 // server -> client: payload = cols u16, rows u16 — the pane's
	// AUTHORITATIVE size. Sent on connect and whenever the pane is resized (by any
	// tmux client or another viewer). Viewers must render at exactly this grid
	// (letterboxing spare pixels): %output bytes are formatted for this width, and
	// rendering at any other width shears the screen. opResize remains an ask.
)

// sizePayload encodes cols/rows the same way clients encode opResize.
func sizePayload(cols, rows int) []byte {
	return []byte{byte(cols >> 8), byte(cols), byte(rows >> 8), byte(rows)}
}

type subscriber struct {
	ch     chan []byte
	done   chan struct{}
	cancel context.CancelFunc // cancels this client's serve ctx (used to evict on kill/rename)
}

// sessionHub owns one backend session (tmux or ConPTY) and its connected clients.
type sessionHub struct {
	tm       session.Session
	mu       sync.Mutex
	subs     map[*subscriber]struct{}
	lastPane string
	dead     chan struct{} // closed when the backend session ended (pump exited)
}

func newSessionHub(tm session.Session) *sessionHub {
	h := &sessionHub{tm: tm, subs: make(map[*subscriber]struct{}), lastPane: tm.Pane(), dead: make(chan struct{})}
	go h.pump()
	return h
}

func (h *sessionHub) pump() {
	defer close(h.dead)
	for out := range h.tm.Output() {
		var frame []byte
		if out.Cols > 0 && out.Rows > 0 {
			// In-band size event: broadcast the authoritative pane size in stream
			// order, so each client re-pins its grid exactly between the bytes
			// formatted for the old width and those formatted for the new.
			frame = encodeFrame(opPaneSize, out.Pane, sizePayload(out.Cols, out.Rows))
		} else {
			frame = encodeFrame(opOutput, out.Pane, out.Data)
		}
		h.mu.Lock()
		h.lastPane = out.Pane
		subs := make([]*subscriber, 0, len(h.subs))
		for s := range h.subs {
			subs = append(subs, s)
		}
		h.mu.Unlock()
		for _, s := range subs {
			select {
			case s.ch <- frame:
			case <-s.done:
			default:
				// Subscriber can't keep up — e.g. a laptop that slept or dropped off
				// whose TCP hasn't timed out yet. EVICT it instead of blocking: a
				// blocked send here stalls pump → outCh → the control PTY → the session's
				// program, freezing it (a wedged agent after laptop sleep). The evicted
				// client reconnects and resyncs from the snapshot. A live client drains
				// its 1024-deep buffer far faster than this ever fills.
				s.cancel()
			}
		}
	}
}

func (h *sessionHub) serve(ctx context.Context, c *websocket.Conn) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	sub := &subscriber{ch: make(chan []byte, 1024), done: make(chan struct{}), cancel: cancel}
	h.mu.Lock()
	h.subs[sub] = struct{}{}
	h.mu.Unlock()
	// Tell this client the pane's current authoritative size FIRST — before the
	// snapshot and any live output — so it renders everything at the right width.
	if cols, rows := h.tm.Size(); cols > 0 && rows > 0 {
		sub.ch <- encodeFrame(opPaneSize, h.tm.Pane(), sizePayload(cols, rows))
	}
	defer func() {
		h.mu.Lock()
		delete(h.subs, sub)
		h.mu.Unlock()
		close(sub.done)
	}()

	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case msg := <-sub.ch:
				if err := c.Write(ctx, websocket.MessageBinary, msg); err != nil {
					cancel()
					return
				}
			}
		}
	}()

	// sendSnapshot captures the pane's current screen and delivers it to THIS
	// client, in order on its own channel. Used both for the one-shot initial
	// prime and for explicit on-resize redraw requests (opReqSnapshot).
	sendSnapshot := func() {
		if snap := h.tm.Snapshot(); len(snap) > 0 {
			select {
			case sub.ch <- encodeFrame(opOutput, h.tm.Pane(), snap):
			case <-sub.done:
			}
		}
	}

	// `primed` ensures we send the initial screen snapshot exactly once, AFTER the
	// client's first resize has been applied — so the snapshot is captured at the
	// client's real width (and current screen mode). Snapshotting before the resize
	// produced the garbled/duplicated overlay and blank panes. New clients also
	// send opReqSnapshot once their size settles for a deterministic redraw; old
	// clients (e.g. the web UI) rely on this prime alone.
	primed := false
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return err
		}
		op, pane, payload, ok := decodeFrame(data)
		if !ok {
			continue
		}
		if pane == "" {
			h.mu.Lock()
			pane = h.lastPane
			h.mu.Unlock()
		}
		switch op {
		case opInput:
			_ = h.tm.SendKeys(pane, payload)
		case opResize:
			if len(payload) < 4 {
				continue
			}
			cols := int(binary.BigEndian.Uint16(payload[0:2]))
			rows := int(binary.BigEndian.Uint16(payload[2:4]))
			_ = h.tm.Resize(cols, rows)
			if !primed {
				primed = true
				go func() {
					time.Sleep(150 * time.Millisecond) // let tmux apply the resize + reflow
					sendSnapshot()
				}()
			}
		case opReqSnapshot:
			// The client applied its final size and now asks for an authoritative
			// redraw. Snapshot() clears scrollback+screen before painting, so this
			// is idempotent — feeding it on every settled resize never duplicates
			// history and makes tmux (not the local reflow) the source of truth.
			sendSnapshot()
		}
	}
}

// stream writes the session's snapshot + live output (raw terminal bytes) to w
// as a flushing HTTP response — the read-only feed behind `ut tail`. Plain HTTP
// so it relays through the mesh's HTTP proxy with no WebSocket double-hop.
func (h *sessionHub) stream(parent context.Context, w io.Writer, flush func()) {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	sub := &subscriber{ch: make(chan []byte, 1024), done: make(chan struct{}), cancel: cancel}
	h.mu.Lock()
	h.subs[sub] = struct{}{}
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.subs, sub)
		h.mu.Unlock()
		close(sub.done)
	}()
	// Size the control client so tmux STREAMS %output: control mode only emits a
	// pane's output once a client has given the window a size (refresh-client -C).
	// The /ws path gets this from the client's first resize; /stream must prime
	// it itself, or no live output flows (only the snapshot).
	_ = h.tm.Resize(200, 50)
	if snap := h.tm.Snapshot(); len(snap) > 0 {
		if _, err := w.Write(snap); err != nil {
			return
		}
		flush()
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-h.dead:
			return
		case frame := <-sub.ch:
			op, _, payload, ok := decodeFrame(frame)
			if !ok || op != opOutput {
				continue
			}
			if _, err := w.Write(payload); err != nil {
				return
			}
			flush()
		}
	}
}

// close evicts every connected client (cancelling each serve ctx closes its
// WebSocket) and detaches the control-mode client. Used on kill/rename.
func (h *sessionHub) close() {
	h.mu.Lock()
	subs := make([]*subscriber, 0, len(h.subs))
	for s := range h.subs {
		subs = append(subs, s)
	}
	h.mu.Unlock()
	for _, s := range subs {
		if s.cancel != nil {
			s.cancel()
		}
	}
	h.tm.Close()
}

// Manager owns all session hubs for one host, via a pluggable backend Provider
// (tmux on Unix, ConPTY on Windows).
type Manager struct {
	ctx  context.Context
	prov session.Provider
	mu   sync.Mutex
	hubs map[string]*sessionHub

	// /sessions is served from this cache, refreshed in the background, so the HTTP
	// handler NEVER blocks on prov.List() — which on the tmux backend forks tmux +
	// capture-pane per session and, on a loaded node, can take many seconds (making
	// the broker look "unreachable" to a client with a request timeout).
	sessMu    sync.Mutex
	sessCache []session.Info
}

func NewManager(ctx context.Context, prov session.Provider) *Manager {
	m := &Manager{ctx: ctx, prov: prov, hubs: make(map[string]*sessionHub)}
	go m.sessionRefreshLoop(2 * time.Second)
	// Reap idle agent sessions on an interval; UT_REAP_INTERVAL_SEC overrides the
	// 5-min default (operational knob; also makes the reaper testable).
	reapEvery := 5 * time.Minute
	if v, err := strconv.Atoi(os.Getenv("UT_REAP_INTERVAL_SEC")); err == nil && v > 0 {
		reapEvery = time.Duration(v) * time.Second
	}
	go m.reapLoop(reapEvery)
	return m
}

// SetHistoryLimit raises the backend's scrollback limit for new sessions.
func (m *Manager) SetHistoryLimit(lines int) { m.prov.SetHistoryLimit(lines) }

// Exec runs a command on this host (the mesh remote-exec primitive).
func (m *Manager) Exec(req session.ExecRequest) session.ExecResult { return m.prov.Exec(req) }

// SendText types text into a session's shell (fire-and-forget; no capture).
func (m *Manager) SendText(name, text string, enter bool) error {
	return m.prov.SendText(name, text, enter)
}

// Spawn creates an agent session that runs cmd directly (no keystroke race) and
// adds it to the cache so it shows up immediately. idleSec is its idle-reap
// leash in seconds (0 = never).
func (m *Manager) Spawn(name, dir, cmd string, idleSec int) error {
	if err := m.prov.Spawn(name, dir, cmd, idleSec); err != nil {
		return err
	}
	go m.refreshSessions()
	return nil
}

// reapLoop periodically asks the provider to remove idle agent sessions (created
// by `ut spawn`), then tears down each reaped session's hub and refreshes the
// cache so the change is reflected immediately. Without this, every finished
// spawn would linger as a heavyweight interactive shell (rc + p10k/gitstatus),
// piling up dozens of processes on a busy node.
func (m *Manager) reapLoop(interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-t.C:
			for _, name := range m.prov.ReapAgents() {
				m.dropHub(name)
				m.sessMu.Lock()
				c := make([]session.Info, 0, len(m.sessCache))
				for _, s := range m.sessCache {
					if s.Name != name {
						c = append(c, s)
					}
				}
				m.sessCache = c
				m.sessMu.Unlock()
			}
		}
	}
}

// Stream feeds a session's snapshot + live output to w (the read-only `ut tail`
// feed). It never creates a session — tailing a missing one is an error.
func (m *Manager) Stream(ctx context.Context, w io.Writer, flush func(), name string) error {
	if !m.prov.Has(name) {
		return fmt.Errorf("no such session: %q", name)
	}
	h, err := m.hub(name)
	if err != nil {
		return err
	}
	h.stream(ctx, w, flush)
	return nil
}

// Sessions returns the cached session list (refreshed in the background). Always
// fast — it never calls the provider on the request path.
func (m *Manager) Sessions() []session.Info {
	m.sessMu.Lock()
	defer m.sessMu.Unlock()
	return m.sessCache
}

// refreshSessions recomputes the cache from the provider. May be slow under load;
// always runs OFF the /sessions request path.
func (m *Manager) refreshSessions() {
	list := m.prov.List()
	if list == nil {
		list = []session.Info{}
	}
	m.sessMu.Lock()
	m.sessCache = list
	m.sessMu.Unlock()
}

// sessionRefreshLoop primes the cache, then refreshes it on an interval until ctx
// is done. Ticks arriving during a slow refresh are coalesced (Ticker drops them).
func (m *Manager) sessionRefreshLoop(interval time.Duration) {
	m.refreshSessions()
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-t.C:
			m.refreshSessions()
		}
	}
}

// Ensure pre-creates/attaches a session hub (used to warm a default session).
func (m *Manager) Ensure(name string) error {
	_, err := m.hub(name)
	return err
}

// hub returns the hub for a session, creating (and attaching to) it if needed.
// The control-mode client lives on the Manager's context, so the hub persists
// across individual client connections.
func (m *Manager) hub(name string) (*sessionHub, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if h, ok := m.hubs[name]; ok {
		select {
		case <-h.dead: // backend session ended — drop the stale hub and re-dial
			delete(m.hubs, name)
		default:
			return h, nil
		}
	}
	tm, err := m.prov.Dial(m.ctx, name)
	if err != nil {
		return nil, err
	}
	h := newSessionHub(tm)
	m.hubs[name] = h
	return h, nil
}

// Serve attaches a client to an EXISTING session. It never creates one: a
// WebSocket reconnecting to a name that was renamed away (or killed) must NOT
// resurrect it — that bug produced a duplicate "ghost" session after a rename.
// Sessions are created only via the explicit /control?action=create path.
func (m *Manager) Serve(ctx context.Context, c *websocket.Conn, name string) error {
	if !m.prov.Has(name) {
		return fmt.Errorf("no such session: %q", name)
	}
	h, err := m.hub(name)
	if err != nil {
		return err
	}
	return h.serve(ctx, c)
}

// Create makes a new detached session (optionally rooted at startDir).
func (m *Manager) Create(name, startDir string) error {
	err := m.prov.Create(name, startDir)
	if err == nil {
		// Optimistically add to the cache so a client's refresh-after-create sees the
		// new session immediately; the background refresh fills in the real details.
		m.sessMu.Lock()
		seen := false
		for _, s := range m.sessCache {
			if s.Name == name {
				seen = true
				break
			}
		}
		if !seen {
			c := append([]session.Info(nil), m.sessCache...)
			c = append(c, session.Info{Name: name, Windows: 1, Path: startDir, State: "idle"})
			m.sessCache = c
		}
		m.sessMu.Unlock()
	}
	go m.refreshSessions()
	return err
}

// Kill terminates a session and evicts its connected clients.
func (m *Manager) Kill(name string) error {
	m.dropHub(name)
	err := m.prov.Kill(name)
	m.sessMu.Lock() // drop it from the cache immediately
	c := make([]session.Info, 0, len(m.sessCache))
	for _, s := range m.sessCache {
		if s.Name != name {
			c = append(c, s)
		}
	}
	m.sessCache = c
	m.sessMu.Unlock()
	go m.refreshSessions()
	return err
}

// Rename renames a session in place and RE-KEYS its live hub from old→new
// instead of dropping it. The control-mode client stays attached across a
// tmux rename-session, so connected WebSocket clients keep streaming without a
// reconnect — the rename is seamless and the session is never interrupted.
func (m *Manager) Rename(from, to string) error {
	if err := m.prov.Rename(from, to); err != nil {
		return err
	}
	m.mu.Lock()
	if h, ok := m.hubs[from]; ok {
		delete(m.hubs, from)
		m.hubs[to] = h
	}
	m.mu.Unlock()
	m.sessMu.Lock() // re-key the cached entry so the new name shows immediately
	c := append([]session.Info(nil), m.sessCache...)
	for i := range c {
		if c[i].Name == from {
			c[i].Name = to
		}
	}
	m.sessCache = c
	m.sessMu.Unlock()
	go m.refreshSessions()
	return nil
}

func (m *Manager) dropHub(name string) {
	m.mu.Lock()
	h := m.hubs[name]
	delete(m.hubs, name)
	m.mu.Unlock()
	if h != nil {
		h.close()
	}
}

func encodeFrame(op byte, pane string, payload []byte) []byte {
	p := []byte(pane)
	buf := make([]byte, 0, 2+len(p)+len(payload))
	buf = append(buf, op, byte(len(p)))
	buf = append(buf, p...)
	buf = append(buf, payload...)
	return buf
}

func decodeFrame(b []byte) (op byte, pane string, payload []byte, ok bool) {
	if len(b) < 2 {
		return 0, "", nil, false
	}
	op = b[0]
	pl := int(b[1])
	if len(b) < 2+pl {
		return 0, "", nil, false
	}
	return op, string(b[2 : 2+pl]), b[2+pl:], true
}
