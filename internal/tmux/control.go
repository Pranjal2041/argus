// Package tmux speaks tmux control mode (`tmux -CC`) and exposes a small,
// backend-agnostic surface that the broker consumes. It is the first
// implementation of the SessionProvider seam described in DESIGN.md.
//
// tmux -CC requires a real terminal (it calls tcgetattr on startup and exits
// with "Inappropriate ioctl for device" on a plain pipe), so we run it under a
// PTY — the same approach iTerm2 uses. The control protocol is line-based text
// over the pty master; tmux puts the pty into raw mode itself, so our own
// command writes are not echoed back into the stream.
//
// Slice 0 scope: stream pane %output (losslessly un-escaped) and forward
// input/resize. Topology notifications and %begin/%end command-response guard
// blocks are parsed away (ignored) for now — they arrive in later slices.
package tmux

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"

	"universal-tmux/internal/session"
)

// Output / SessionInfo alias the shared seam types so existing tmux code is
// unchanged while the broker speaks the backend-agnostic session package.
type Output = session.Output
type SessionInfo = session.Info

// Provider is the tmux implementation of session.Provider: one tmux server
// selected by `-L socket`.
type Provider struct{ socket string }

// NewProvider returns a tmux-backed provider for the given server socket.
func NewProvider(socket string) *Provider { return &Provider{socket: socket} }

func (p *Provider) List() []SessionInfo                  { return ListSessions(p.socket) }
func (p *Provider) Create(name, dir string) error       { return CreateSession(p.socket, name, dir) }
func (p *Provider) Kill(name string) error              { return KillSession(p.socket, name) }
func (p *Provider) Rename(from, to string) error        { return RenameSession(p.socket, from, to) }
func (p *Provider) Has(name string) bool                { return HasSession(p.socket, name) }
func (p *Provider) SetHistoryLimit(lines int)           { SetHistoryLimit(p.socket, lines) }
func (p *Provider) Dial(ctx context.Context, name string) (session.Session, error) {
	c, err := Dial(ctx, p.socket, name)
	if err != nil {
		return nil, err
	}
	return c, nil
}

// interruptHints are the footer strings agents show while a turn is actively
// running — Claude: "… · esc to interrupt"; Codex: "Working (… • esc to
// interrupt)"; some agent modes instead print "/stop to interrupt". Any of them
// on the visible screen is the agent-agnostic "working" signal; their absence
// means idle. This survives a noisy pane: a server logging in the same window
// never prints these, so output-activity false positives disappear.
var interruptHints = []string{"esc to interrupt", "/stop to interrupt"}

// interruptScanLines bounds the scan to the last few non-blank lines — the hint lives
// in the footer, so checking only the bottom avoids matching the phrase in chat text.
const interruptScanLines = 6

// DetectState reports "working" if the session's visible screen shows the agent's
// "esc to interrupt" hint, else "idle". A passive, point-in-time capture-pane read:
// no history, no background sampler — computed on demand when /sessions is requested.
func DetectState(socket, name string) string {
	out, err := exec.Command("tmux", tmuxArgs(socket, "capture-pane", "-p", "-t", name)...).Output()
	if err != nil {
		return "idle"
	}
	if screenHasInterrupt(out) {
		return "working"
	}
	return "idle"
}

// screenHasInterrupt reports whether any interrupt hint appears in the last few
// non-blank lines of a captured screen.
func screenHasInterrupt(screen []byte) bool {
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	checked := 0
	for i := len(lines) - 1; i >= 0 && checked < interruptScanLines; i-- {
		l := strings.TrimSpace(lines[i])
		if l == "" {
			continue
		}
		checked++
		low := strings.ToLower(l)
		for _, hint := range interruptHints {
			if strings.Contains(low, hint) {
				return true
			}
		}
	}
	return false
}

// internalSessionPrefix marks tmux sessions that are ut's own infrastructure
// (the broker supervisor that respawns the broker). They live on the same -L
// socket so they ride tmux's lifecycle, but must never surface to clients.
const internalSessionPrefix = "_ut-"

// isInternalSession reports whether a session is ut infrastructure, not a user
// session — it is hidden from List and rejected by Has so clients can't attach.
func isInternalSession(name string) bool { return strings.HasPrefix(name, internalSessionPrefix) }

// ListSessions returns the sessions on the given tmux server (-L socket).
// A missing server / no sessions yields an empty list, not an error.
func ListSessions(socket string) []SessionInfo {
	out, err := exec.Command("tmux", tmuxArgs(socket, "list-sessions", "-F",
		"#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}\t#{pane_current_path}")...).Output()
	if err != nil {
		return []SessionInfo{}
	}
	sessions := []SessionInfo{}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.SplitN(line, "\t", 5)
		if len(f) < 4 {
			continue
		}
		if isInternalSession(f[0]) {
			continue // hide infra sessions (e.g. the broker's own supervisor) from clients
		}
		windows, _ := strconv.Atoi(f[1])
		attached, _ := strconv.Atoi(f[2])
		act, _ := strconv.ParseInt(f[3], 10, 64)
		path := ""
		if len(f) >= 5 {
			path = f[4]
		}
		sessions = append(sessions, SessionInfo{
			Name: f[0], Windows: windows, Attached: attached > 0, Activity: act, Path: path,
			State: DetectState(socket, f[0]),
		})
	}
	return sessions
}

// Client is a running `tmux -CC` control-mode session.
type Client struct {
	cmd     *exec.Cmd
	ptmx    *os.File
	socket  string
	session string
	primary string // pane id of the session's first pane
	outCh   chan Output
	writeMu sync.Mutex
	lastW   int // last size emitted from %layout-change (readLoop goroutine only)
	lastH   int
}

// Dial starts a control-mode client attached to (creating if absent) the named
// session. We OWN this session — see DESIGN.md.
func Dial(ctx context.Context, socket, session string) (*Client, error) {
	// -CC: control mode with echo disabled (the programmatic form iTerm2 uses).
	// -L SOCKET: a dedicated tmux server, isolating our sessions from any other.
	// new-session -A -s NAME: attach if it exists, else create it.
	cmd := exec.CommandContext(ctx, "tmux", tmuxArgs(socket, "-CC", "new-session", "-A", "-s", session)...)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("start tmux under pty: %w", err)
	}
	_ = pty.Setsize(ptmx, &pty.Winsize{Rows: 30, Cols: 100})

	c := &Client{cmd: cmd, ptmx: ptmx, socket: socket, session: session, primary: discoverPane(socket, session), outCh: make(chan Output, 1024)}
	go c.readLoop(ptmx)
	return c, nil
}

// SetHistoryLimit sets the server-wide scrollback limit for NEW panes/sessions.
func SetHistoryLimit(socket string, lines int) {
	_ = exec.Command("tmux", tmuxArgs(socket, "set", "-g", "history-limit", strconv.Itoa(lines))...).Run()
}

// CreateSession creates a new detached session. startDir, if non-empty, sets
// its working directory (so "new session in this folder" works).
func CreateSession(socket, name, startDir string) error {
	args := []string{"new-session", "-d", "-s", name}
	if startDir != "" {
		args = append(args, "-c", startDir)
	}
	out, err := exec.Command("tmux", tmuxArgs(socket, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create %q: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// KillSession terminates a session and everything running in it.
func KillSession(socket, name string) error {
	out, err := exec.Command("tmux", tmuxArgs(socket, "kill-session", "-t", name)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("kill %q: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// HasSession reports whether an exact-named session exists on the server.
// `=name` forces an exact match so "will" can't match "will-rename".
func HasSession(socket, name string) bool {
	if isInternalSession(name) {
		return false // infra sessions are not attachable by clients
	}
	return exec.Command("tmux", tmuxArgs(socket, "has-session", "-t", "="+name)...).Run() == nil
}

// RenameSession renames a session in place.
func RenameSession(socket, from, to string) error {
	out, err := exec.Command("tmux", tmuxArgs(socket, "rename-session", "-t", from, to)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("rename %q->%q: %v: %s", from, to, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// tmuxArgs prepends `-L SOCKET` (select a dedicated server) when set.
func tmuxArgs(socket string, rest ...string) []string {
	if socket == "" {
		return rest
	}
	return append([]string{"-L", socket}, rest...)
}

// Pane returns the session's primary pane id (best default for input routing).
func (c *Client) Pane() string { return c.primary }

// Close detaches this control-mode client (closing the PTY makes tmux -CC exit).
// Used when a session is killed or renamed out from under its hub.
func (c *Client) Close() {
	if c.ptmx != nil {
		_ = c.ptmx.Close()
	}
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
}

// Output returns the channel of pane output chunks.
func (c *Client) Output() <-chan Output { return c.outCh }

// send writes one control-mode command line to tmux.
func (c *Client) send(line string) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err := io.WriteString(c.ptmx, line+"\n")
	return err
}

// SendKeys forwards raw input bytes to a pane via `send-keys -H` (hex
// keycodes), which transparently handles control chars, escape sequences and
// UTF-8 — each byte becomes one hex token.
func (c *Client) SendKeys(pane string, data []byte) error {
	if pane == "" || len(data) == 0 {
		return nil
	}
	const hexdigits = "0123456789abcdef"
	var b strings.Builder
	b.WriteString("send-keys -t ")
	b.WriteString(pane)
	b.WriteString(" -H")
	for _, by := range data {
		b.WriteByte(' ')
		b.WriteByte(hexdigits[by>>4])
		b.WriteByte(hexdigits[by&0x0f])
	}
	return c.send(b.String())
}

// Resize sizes the window to the client's terminal. Safe because we own this
// session (DESIGN.md: never refresh-client -C against a foreign session).
//
// This is an ASK, not a command: the window's actual size is negotiated by tmux
// across ALL attached clients (window-size policy) — e.g. a real `tmux attach`
// terminal can win. Whatever tmux decides comes back as a %layout-change size
// event, which is the AUTHORITATIVE size viewers must render at.
func (c *Client) Resize(cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return nil
	}
	return c.send(fmt.Sprintf("refresh-client -C %dx%d", cols, rows))
}

// Size reports the session's active window size — the width every byte of
// %output is formatted for. Queried once per client connect; live changes
// arrive as in-band size events from %layout-change.
func (c *Client) Size() (int, int) {
	out := c.paneFlag("#{window_width} #{window_height}")
	var w, h int
	if _, err := fmt.Sscanf(out, "%d %d", &w, &h); err != nil {
		return 0, 0
	}
	return w, h
}

// paneFlag reads a single tmux format value for the pane we stream, e.g.
// "#{alternate_on}" → "1" when a full-screen (TUI) app is on the alternate
// screen. Returns "" on error.
//
// Targeted by PANE ID, never by session name: the session can be renamed out
// from under a live client (Manager.Rename keeps hubs streaming across a
// rename), and a stale name made every name-targeted command fail silently —
// no snapshot, no size, a freshly-attached viewer stuck on "connecting".
func (c *Client) paneFlag(format string) string {
	out, err := exec.Command("tmux", tmuxArgs(c.socket, "display-message", "-p", "-t", c.primary, format)...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Snapshot returns the active pane's current content so a freshly-connected
// client renders immediately instead of a blank terminal. It is screen-aware:
//   - Alternate screen (a TUI like an agent, vim, htop): capture ONLY the visible
//     screen and prefix with the enter-alt-screen sequence, so the snapshot lands
//     on the client's alternate buffer — where the app's subsequent delta updates
//     also write — instead of the main screen (which caused the garbled overlay).
//   - Main screen (a shell): leave the alternate screen and include scrollback so
//     history is visible and scrollable.
//
// Capture happens at the window's CURRENT width, so the broker must apply the
// client's resize BEFORE calling this (see the hub's first-resize priming).
func (c *Client) Snapshot() []byte {
	esc := string(rune(27))
	alt := c.paneFlag("#{alternate_on}") == "1"
	var args []string
	var prefix string
	// [3J clears the client's scrollback before repaint, so a client may feed this
	// snapshot repeatedly (e.g. a redraw on every settled resize) without ever
	// duplicating history — the snapshot is an idempotent "here is the truth now".
	if alt {
		args = []string{"capture-pane", "-p", "-e", "-t", c.primary}                  // visible screen only
		prefix = esc + "[?1049h" + esc + "[2J" + esc + "[3J" + esc + "[H"              // enter alt, clear, clear scrollback, home
	} else {
		args = []string{"capture-pane", "-p", "-e", "-S", "-10000", "-t", c.primary}  // + scrollback
		prefix = esc + "[?1049l" + esc + "[2J" + esc + "[3J" + esc + "[H"              // ensure main, clear, clear scrollback, home
	}
	out, err := exec.Command("tmux", tmuxArgs(c.socket, args...)...).Output()
	if err != nil || len(out) == 0 {
		return nil
	}
	body := strings.ReplaceAll(strings.TrimRight(string(out), "\n"), "\n", "\r\n")
	return []byte(prefix + body)
}

func (c *Client) readLoop(r io.Reader) {
	defer close(c.outCh)
	br := bufio.NewReaderSize(r, 1<<20)
	for {
		line, err := br.ReadString('\n')
		if len(line) > 0 {
			c.handleLine(strings.TrimRight(line, "\r\n"))
		}
		if err != nil {
			return
		}
	}
}

// handleLine processes one control-mode line: %output (pane bytes) and
// %layout-change (the window was resized — by anyone — so emit an in-band size
// event). Everything else (guard blocks, other notifications) is ignored.
func (c *Client) handleLine(line string) {
	if strings.HasPrefix(line, "%layout-change ") {
		// %layout-change @id window-layout window-visible-layout flags
		// The layout's second field is the window size, e.g. "ac1d,139x53,0,0,0".
		// Emitting it IN-BAND (same channel as %output) is essential: output
		// produced before the reflow renders at the old size, after at the new.
		f := strings.Fields(line)
		if len(f) >= 3 {
			if w, h, ok := layoutSize(f[2]); ok && (w != c.lastW || h != c.lastH) {
				c.lastW, c.lastH = w, h
				c.outCh <- Output{Pane: c.primary, Cols: w, Rows: h}
			}
		}
		return
	}
	if !strings.HasPrefix(line, "%output ") {
		return // ignore guard blocks, topology notifications, echoed commands
	}
	rest := line[len("%output "):]
	sp := strings.IndexByte(rest, ' ')
	if sp < 0 {
		return
	}
	pane := rest[:sp]
	data := stripWindowName(unescapeOutput(rest[sp+1:]))
	c.outCh <- Output{Pane: pane, Data: data} // block for backpressure; broker always drains
}

// layoutSize extracts WxH from a tmux layout string ("ac1d,139x53,0,0,0").
func layoutSize(layout string) (w, h int, ok bool) {
	parts := strings.SplitN(layout, ",", 3)
	if len(parts) < 2 {
		return 0, 0, false
	}
	if _, err := fmt.Sscanf(parts[1], "%dx%d", &w, &h); err != nil || w <= 0 || h <= 0 {
		return 0, 0, false
	}
	return w, h, true
}

// discoverPane asks tmux (via a plain subprocess on the same server) for the
// session's first pane id, retrying briefly while the session comes up.
func discoverPane(socket, session string) string {
	for i := 0; i < 20; i++ {
		out, err := exec.Command("tmux", tmuxArgs(socket, "list-panes", "-t", session, "-F", "#{pane_id}")...).Output()
		if err == nil {
			if id := strings.TrimSpace(strings.SplitN(string(out), "\n", 2)[0]); id != "" {
				return id
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return "%0"
}

// stripWindowName removes screen/tmux "set window name" sequences
// (ESC k ... ST, or ESC k ... BEL). Shells/prompts (e.g. powerlevel10k) emit
// these inside tmux to rename the window; control mode forwards them verbatim,
// and renderers like SwiftTerm don't understand ESC k, so they would print the
// name as stray text. Only complete sequences within the chunk are removed.
func stripWindowName(b []byte) []byte {
	for {
		k := -1
		for i := 0; i+1 < len(b); i++ {
			if b[i] == 0x1b && b[i+1] == 'k' {
				k = i
				break
			}
		}
		if k < 0 {
			return b
		}
		end := -1
		for j := k + 2; j < len(b); j++ {
			if b[j] == 0x07 { // BEL
				end = j + 1
				break
			}
			if b[j] == 0x1b && j+1 < len(b) && b[j+1] == '\\' { // ST
				end = j + 2
				break
			}
		}
		if end < 0 {
			return b // incomplete in this chunk; leave it rather than eat content
		}
		b = append(b[:k:k], b[end:]...)
	}
}

func isOctal(b byte) bool { return b >= '0' && b <= '7' }

// unescapeOutput reverses tmux control-mode escaping: every escaped byte
// appears as a backslash followed by exactly three octal digits.
func unescapeOutput(s string) []byte {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) && isOctal(s[i+1]) && isOctal(s[i+2]) && isOctal(s[i+3]) {
			out = append(out, byte(int(s[i+1]-'0')<<6|int(s[i+2]-'0')<<3|int(s[i+3]-'0')))
			i += 3
			continue
		}
		out = append(out, s[i])
	}
	return out
}
