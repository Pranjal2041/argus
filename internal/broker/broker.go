// Package broker fans tmux control-mode sessions out to WebSocket clients.
// A Manager owns one tmux server (-L socket) and a hub per attached session;
// each hub streams its session to N clients and routes their input back.
// Wire format (DESIGN.md): [opcode u8][paneLen u8][pane][payload].
package broker

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"

	"universal-tmux/internal/rendersource"
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

// maxFramePayload caps a single WebSocket message's payload. A larger message
// fails some clients' receive with EMSGSIZE "Message too long"
// (URLSessionWebSocketTask defaults to a 1 MiB limit), and since a reconnect just
// re-sends the same oversized frame, that becomes an infinite reconnect flap — it
// hit sessions whose scrollback snapshot exceeded 1 MiB. A long snapshot or output
// burst is split across several opOutput frames; the terminal feeds them in order,
// so splitting at an arbitrary byte boundary is transparent (TCP already does).
const maxFramePayload = 256 * 1024

// outputFrames encodes data as one or more opOutput frames, each within
// maxFramePayload, preserving byte order.
func outputFrames(pane string, data []byte) [][]byte {
	if len(data) <= maxFramePayload {
		return [][]byte{encodeFrame(opOutput, pane, data)}
	}
	frames := make([][]byte, 0, len(data)/maxFramePayload+1)
	for off := 0; off < len(data); off += maxFramePayload {
		end := off + maxFramePayload
		if end > len(data) {
			end = len(data)
		}
		frames = append(frames, encodeFrame(opOutput, pane, data[off:end]))
	}
	return frames
}

func (h *sessionHub) pump() {
	defer close(h.dead)
	for out := range h.tm.Output() {
		var frames [][]byte
		if out.Cols > 0 && out.Rows > 0 {
			// In-band size event: broadcast the authoritative pane size in stream
			// order, so each client re-pins its grid exactly between the bytes
			// formatted for the old width and those formatted for the new.
			frames = [][]byte{encodeFrame(opPaneSize, out.Pane, sizePayload(out.Cols, out.Rows))}
		} else {
			frames = outputFrames(out.Pane, out.Data)
		}
		h.mu.Lock()
		h.lastPane = out.Pane
		subs := make([]*subscriber, 0, len(h.subs))
		for s := range h.subs {
			subs = append(subs, s)
		}
		h.mu.Unlock()
		for _, s := range subs {
		send:
			for _, frame := range frames {
				select {
				case s.ch <- frame:
				case <-s.done:
					break send
				default:
					// Subscriber can't keep up — e.g. a laptop that slept or dropped off
					// whose TCP hasn't timed out yet. EVICT it instead of blocking: a
					// blocked send here stalls pump → outCh → the control PTY → the session's
					// program, freezing it (a wedged agent after laptop sleep). The evicted
					// client reconnects and resyncs from the snapshot. A live client drains
					// its 1024-deep buffer far faster than this ever fills.
					s.cancel()
					break send
				}
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
			for _, frame := range outputFrames(h.tm.Pane(), snap) {
				select {
				case sub.ch <- frame:
				case <-sub.done:
					return
				}
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

	// Command-center status blob: opaque JSON the macOS client publishes (the
	// per-session AI status summaries) and other clients (phone) read back. The
	// broker is a dumb relay here — it never parses or interprets the blob.
	ccMu   sync.Mutex
	ccBlob []byte

	// Command-center status OVERRIDES: a client that can't run the status model (the
	// phone) POSTs a manual label here; the Mac (the only generator) polls these,
	// applies each through its normal correction path, and clears it. Transient —
	// consumed within seconds — so kept in memory only.
	ccOvMu      sync.Mutex
	ccOverrides map[string]CCOverride

	// Hidden sessions: names the user hid in a client UI. Broker-owned + persisted so the
	// hide STICKS (survives broker restarts) and SYNCS across devices — both clients read
	// the `hidden` flag on /sessions and toggle it via POST /hidden.
	hiddenMu   sync.Mutex
	hidden     map[string]bool
	hiddenPath string

	// Session history: a durable per-node log of every session that has existed —
	// name, node, and the folders it ran in (with timestamps) — so the user can
	// recover where a now-gone session was running. Recorded off the refresh loop,
	// persisted per-host (like the hidden set).
	histMu    sync.Mutex
	history   map[string]*SessionHistory
	histPath  string
	histNode  string
	histDirty bool
}

// SetCommandCenter stores the latest command-center status blob (from the Mac).
func (m *Manager) SetCommandCenter(b []byte) {
	m.ccMu.Lock()
	m.ccBlob = b
	m.ccMu.Unlock()
}

// CommandCenter returns the last published status blob (or nil if none yet).
func (m *Manager) CommandCenter() []byte {
	m.ccMu.Lock()
	defer m.ccMu.Unlock()
	return m.ccBlob
}

// CCOverride is a phone-set manual status awaiting the Mac's pickup.
type CCOverride struct {
	Label string `json:"label"`
	TS    int64  `json:"ts"`
}

// SetCCOverride records a manual status a client set for a session and returns its
// timestamp; the Mac clears it by matching this TS, so a newer override set in
// between is never lost.
func (m *Manager) SetCCOverride(session, label string) int64 {
	ts := time.Now().UnixMilli()
	m.ccOvMu.Lock()
	if m.ccOverrides == nil {
		m.ccOverrides = map[string]CCOverride{}
	}
	m.ccOverrides[session] = CCOverride{Label: label, TS: ts}
	m.ccOvMu.Unlock()
	return ts
}

// CCOverrides returns a copy of the pending manual-status overrides.
func (m *Manager) CCOverrides() map[string]CCOverride {
	m.ccOvMu.Lock()
	defer m.ccOvMu.Unlock()
	out := make(map[string]CCOverride, len(m.ccOverrides))
	for k, v := range m.ccOverrides {
		out[k] = v
	}
	return out
}

// ClearCCOverride drops a pending override once the Mac has consumed it, but only if
// the timestamp still matches — so a newer override set in between is preserved.
func (m *Manager) ClearCCOverride(session string, ts int64) {
	m.ccOvMu.Lock()
	defer m.ccOvMu.Unlock()
	if v, ok := m.ccOverrides[session]; ok && v.TS == ts {
		delete(m.ccOverrides, session)
	}
}

func NewManager(ctx context.Context, prov session.Provider) *Manager {
	m := &Manager{ctx: ctx, prov: prov, hubs: make(map[string]*sessionHub), hidden: map[string]bool{}, ccOverrides: map[string]CCOverride{}, history: map[string]*SessionHistory{}}
	m.hiddenPath = hiddenStatePath()
	m.loadHidden()
	m.histPath = historyStatePath()
	m.histNode = histNodeName()
	m.loadHistory()
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
// adds it to the cache so it shows up immediately. idleSec is its early idle
// cleanup time in seconds (0 retains a finished shell until the 7-day maximum).
func (m *Manager) Spawn(name, dir, cmd string, idleSec int) error {
	if m.reservesStableIDs() && isStableSessionID(name) {
		return fmt.Errorf("session name %q is reserved for a stable session handle", name)
	}
	if err := m.prov.Spawn(name, dir, cmd, idleSec); err != nil {
		return err
	}
	go m.refreshSessions(false)
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

// capturer is the optional capability a backend implements to return a session's
// recent scrollback as plain text. tmux implements it; conpty (Windows) does not
// yet, so /recent is a no-op there until added.
type capturer interface {
	Capture(name string, lines int) (string, error)
}

// Has reports whether a session with this exact name exists right now.
func (m *Manager) Has(name string) bool { return m.prov.Has(name) }

// Recent returns a session's recent rendered output for the command-center status
// updater. Errors if the session is gone or the backend can't capture. This DOES
// fork tmux capture-pane on the request path (unlike /sessions), so the caller
// must rate-limit it (the client polls per active session on a ~30s cadence).
func (m *Manager) Recent(name string, lines int) (string, error) {
	if !m.prov.Has(name) {
		return "", fmt.Errorf("no such session: %q", name)
	}
	c, ok := m.prov.(capturer)
	if !ok {
		return "", fmt.Errorf("capture not supported on this backend")
	}
	return c.Capture(name, lines)
}

// RenderSource returns the authoritative Markdown behind the agent response
// visible in a session. The transcript resolver must prove strong overlap with
// the rendered screen; if it cannot, callers fall back to their lossless styled
// terminal snapshot instead of ever showing text from the wrong agent.
func (m *Manager) RenderSource(name string) (rendersource.Result, error) {
	text, err := m.Recent(name, 600)
	if err != nil {
		return rendersource.Result{}, err
	}
	var cwd string
	for _, info := range m.Sessions() {
		if info.Name == name {
			cwd = info.Path
			break
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return rendersource.Result{}, fmt.Errorf("resolve home directory: %w", err)
	}
	if home == "" {
		return rendersource.Result{}, fmt.Errorf("resolve home directory: empty path")
	}
	return rendersource.Resolve(home, cwd, text)
}

// Sessions returns the cached session list (refreshed in the background). Always
// fast — it never calls the provider on the request path.
func (m *Manager) Sessions() []session.Info {
	m.sessMu.Lock()
	out := make([]session.Info, len(m.sessCache))
	copy(out, m.sessCache)
	m.sessMu.Unlock()
	// Stamp the user-hidden flag on a COPY so toggles reflect immediately (no wait for the
	// session-cache refresh) without mutating the cache.
	m.hiddenMu.Lock()
	for i := range out {
		if m.hidden[out[i].Name] {
			out[i].Hidden = true
		}
	}
	m.hiddenMu.Unlock()
	return out
}

// ForegroundSessions is the fast client snapshot: only ordinary, user-visible
// sessions. Hidden and agent sessions remain in Sessions() for restore/history and
// explicit full refreshes, but do not need to cross the UI hot path every two seconds.
func (m *Manager) ForegroundSessions() []session.Info {
	all := m.Sessions()
	out := make([]session.Info, 0, len(all))
	for _, info := range all {
		if !info.Agent && !info.Hidden {
			out = append(out, info)
		}
	}
	return out
}

// hiddenStatePath is a per-HOST file (not the NFS-shared home key) so brokers on
// different nodes don't clobber each other's hidden state.
func hiddenStatePath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	host, _ := os.Hostname()
	if host == "" {
		host = "local"
	}
	dir := filepath.Join(home, ".universal-tmux")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "hidden-"+host+".json")
}

func (m *Manager) loadHidden() {
	b, err := os.ReadFile(m.hiddenPath)
	if err != nil {
		return
	}
	var names []string
	if json.Unmarshal(b, &names) == nil {
		m.hiddenMu.Lock()
		for _, n := range names {
			m.hidden[n] = true
		}
		m.hiddenMu.Unlock()
	}
}

func (m *Manager) saveHiddenLocked() {
	names := make([]string, 0, len(m.hidden))
	for n := range m.hidden {
		names = append(names, n)
	}
	if b, err := json.Marshal(names); err == nil {
		_ = os.WriteFile(m.hiddenPath, b, 0o644)
	}
}

// SetHidden marks/unmarks a session name as hidden and persists.
func (m *Manager) SetHidden(name string, hidden bool) {
	m.hiddenMu.Lock()
	defer m.hiddenMu.Unlock()
	if hidden {
		m.hidden[name] = true
	} else {
		delete(m.hidden, name)
	}
	m.saveHiddenLocked()
}

// HiddenNames returns the hidden session names (for GET /hidden).
func (m *Manager) HiddenNames() []string {
	m.hiddenMu.Lock()
	defer m.hiddenMu.Unlock()
	names := make([]string, 0, len(m.hidden))
	for n := range m.hidden {
		names = append(names, n)
	}
	return names
}

// refreshSessions recomputes the cache from the provider. May be slow under load;
// always runs OFF the /sessions request path. Providers with tiered state support
// inventory every session cheaply, but capture/classify hidden and agent panes only
// on the background pass. Their last classified state is retained between passes.
func (m *Manager) refreshSessions(includeBackground bool) {
	var list []session.Info
	if provider, ok := m.prov.(session.TieredStateProvider); ok {
		list = provider.ListInventory()

		m.sessMu.Lock()
		previous := make(map[string]string, len(m.sessCache))
		for _, info := range m.sessCache {
			previous[sessionStateKey(info)] = info.State
		}
		m.sessMu.Unlock()

		m.hiddenMu.Lock()
		hidden := make(map[string]bool, len(m.hidden))
		for name, value := range m.hidden {
			hidden[name] = value
		}
		m.hiddenMu.Unlock()

		indexes := make([]int, 0, len(list))
		for i := range list {
			if state := previous[sessionStateKey(list[i])]; state != "" {
				list[i].State = state
			} else {
				list[i].State = "idle"
			}
			if includeBackground || (!list[i].Agent && !hidden[list[i].Name]) {
				indexes = append(indexes, i)
			}
		}

		sem := make(chan struct{}, 16)
		var wg sync.WaitGroup
		for _, i := range indexes {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				state := provider.DetectState(list[i].Name)
				if state == "" {
					state = "idle"
				}
				list[i].State = state
			}(i)
		}
		wg.Wait()
	} else {
		list = m.prov.List()
	}
	if list == nil {
		list = []session.Info{}
	}
	m.sessMu.Lock()
	m.sessCache = list
	m.sessMu.Unlock()
	m.recordHistory(list)
}

func sessionStateKey(info session.Info) string {
	if info.ID != "" {
		return info.ID
	}
	return info.Name
}

// sessionRefreshLoop primes the cache, then refreshes it on an interval until ctx
// is done. Ticks arriving during a slow refresh are coalesced (Ticker drops them).
func (m *Manager) sessionRefreshLoop(interval time.Duration) {
	m.refreshSessions(true)
	t := time.NewTicker(interval)
	defer t.Stop()
	ticks := 0
	for {
		select {
		case <-m.ctx.Done():
			m.flushHistory() // persist lastSeen on clean shutdown
			return
		case <-t.C:
			ticks++
			m.refreshSessions(ticks%15 == 0) // 2s foreground; 30s hidden/agent classification
			if ticks%30 == 0 {               // ~every 60s at the 2s interval: flush lastSeen updates
				m.flushHistory()
			}
		}
	}
}

// WarmExisting attaches a hub only when the session already exists. A missing
// fallback session is normal: broker/app startup must never resurrect a session
// the user deliberately killed. Sessions are created only by explicit commands.
func (m *Manager) WarmExisting(name string) error {
	if m.reservesStableIDs() && isStableSessionID(name) {
		return fmt.Errorf("session name %q is reserved for a stable session handle", name)
	}
	if !m.prov.Has(name) {
		return nil
	}
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
	// Defense in depth: attaching is never creation. Every caller currently checks
	// existence, but keep the invariant at the one function that actually dials the
	// backend too.
	if !m.prov.Has(name) {
		return nil, fmt.Errorf("no such session: %q", name)
	}
	tm, err := m.prov.Dial(m.ctx, name)
	if err != nil {
		return nil, err
	}
	h := newSessionHub(tm)
	m.hubs[name] = h
	return h, nil
}

// isStableSessionID recognizes tmux's reserved stable-handle namespace. Limit it
// to $ followed by digits so an ordinary session name such as "$scratch" remains
// legal.
func isStableSessionID(target string) bool {
	if len(target) < 2 || target[0] != '$' {
		return false
	}
	for i := 1; i < len(target); i++ {
		if target[i] < '0' || target[i] > '9' {
			return false
		}
	}
	return true
}

type sessionIDResolver interface {
	SessionForID(string) (string, bool)
}

func (m *Manager) reservesStableIDs() bool {
	_, ok := m.prov.(sessionIDResolver)
	return ok
}

// resolveTarget maps a connection target to a session NAME. A $N target is a
// stable tmux session id; the provider resolves it to the current name (which
// follows renames). If a tmux provider cannot resolve the id, resolution FAILS:
// tmux's target parser also treats $N as an id when asked for an "exact name",
// so passing a dead/transiently-unresolved id through can make a later attach
// create a literal "$N" duplicate. Backends without stable ids (ConPTY) retain
// normal name behavior, including a user-created name that happens to look like $N.
func (m *Manager) resolveTarget(target string) (string, bool) {
	if !isStableSessionID(target) {
		return target, true
	}
	if r, ok := m.prov.(sessionIDResolver); ok {
		cur, ok := r.SessionForID(target)
		return cur, ok
	}
	return target, true
}

// Serve attaches a client to an EXISTING session. It never creates one: a
// WebSocket reconnecting to a name that was renamed away (or killed) must NOT
// resurrect it — that bug produced a duplicate "ghost" session after a rename.
// Sessions are created only via the explicit /control?action=create path.
//
// A client may connect by the session's STABLE tmux id ($N) instead of its
// name: the id never changes across a rename, so an auto-reconnecting socket
// survives a rename (from any client) even across a broker or app restart — the
// name-based reconnect bug that made a renamed pane stick on "reconnecting".
// We resolve the id back to the session's CURRENT name here, then run the
// existing name-keyed machinery (so id- and name-connections share one hub).
func (m *Manager) Serve(ctx context.Context, c *websocket.Conn, name string) error {
	resolved, ok := m.resolveTarget(name)
	if !ok {
		return fmt.Errorf("no such session handle: %q", name)
	}
	name = resolved
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
	if m.reservesStableIDs() && isStableSessionID(name) {
		return fmt.Errorf("session name %q is reserved for a stable session handle", name)
	}
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
	go m.refreshSessions(false)
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
	go m.refreshSessions(false)
	return err
}

// Rename renames a session in place and RE-KEYS its live hub from old→new
// instead of dropping it. The control-mode client stays attached across a
// tmux rename-session, so connected WebSocket clients keep streaming without a
// reconnect — the rename is seamless and the session is never interrupted.
func (m *Manager) Rename(from, to string) error {
	if m.reservesStableIDs() && isStableSessionID(to) {
		return fmt.Errorf("session name %q is reserved for a stable session handle", to)
	}
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
	go m.refreshSessions(false)
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
