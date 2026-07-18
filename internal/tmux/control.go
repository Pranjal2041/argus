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
	"regexp"
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

func (p *Provider) List() []SessionInfo            { return ListSessions(p.socket) }
func (p *Provider) ListInventory() []SessionInfo   { return ListSessionInventory(p.socket) }
func (p *Provider) DetectState(name string) string { return DetectState(p.socket, name) }

// Capture returns a session's recent scrollback as plain rendered text (no
// escapes) — `capture-pane -p -S -<lines>`. Feeds the macOS command center's
// status updater. lines<=0 uses a sane default; the call is bounded and runs
// off the request path's hot loop (the broker rate-limits it).
func (p *Provider) Capture(name string, lines int) (string, error) {
	if lines <= 0 {
		lines = 400
	}
	// -e PRESERVES SGR escapes so we can drop Claude Code's empty-prompt autosuggestion,
	// which it renders FAINT (SGR 2). Plain `-p` discards the color that distinguishes
	// that suggested next message from real input, and the summarizer was reading the
	// suggestion as the user's intent. dropDimAndAnsi then returns plain text as before.
	out, err := exec.Command("tmux", tmuxArgs(p.socket, "capture-pane", "-e", "-p", "-S", "-"+strconv.Itoa(lines), "-t", name)...).Output()
	if err != nil {
		return "", err
	}
	return dropDimAndAnsi(out), nil
}

// dropDimAndAnsi removes any text drawn in the ANSI FAINT style (SGR 2) — the agent's
// dim autosuggestion — then strips all remaining escape sequences, yielding plain text.
// SGR state is tracked across the stream: 2 turns faint on; 0/22 (and a bare ESC[m)
// turn it off; parameters are processed left-to-right within one SGR.
func dropDimAndAnsi(b []byte) string {
	out := make([]byte, 0, len(b))
	faint := false
	for i := 0; i < len(b); {
		if b[i] == 0x1b && i+1 < len(b) && b[i+1] == '[' {
			j := i + 2
			for j < len(b) && !(b[j] >= 0x40 && b[j] <= 0x7e) {
				j++
			}
			if j < len(b) && b[j] == 'm' { // SGR — update faint state
				for _, ppar := range strings.Split(string(b[i+2:j]), ";") {
					switch ppar {
					case "2":
						faint = true
					case "0", "22", "":
						faint = false
					}
				}
			}
			if j < len(b) {
				i = j + 1 // drop the whole escape sequence
			} else {
				i = j
			}
			continue
		}
		if !faint {
			out = append(out, b[i])
		}
		i++
	}
	return string(out)
}
func (p *Provider) Create(name, dir string) error { return CreateSession(p.socket, name, dir) }
func (p *Provider) Spawn(name, dir, cmd string, idleSec int) error {
	return SpawnSession(p.socket, name, dir, cmd, idleSec)
}
func (p *Provider) ReapAgents() []string         { return ReapIdleAgentSessions(p.socket) }
func (p *Provider) Kill(name string) error       { return KillSession(p.socket, name) }
func (p *Provider) Rename(from, to string) error { return RenameSession(p.socket, from, to) }
func (p *Provider) Has(name string) bool         { return HasSession(p.socket, name) }
func (p *Provider) SetHistoryLimit(lines int)    { SetHistoryLimit(p.socket, lines) }

// SessionForID resolves a stable tmux session id ($N) to that session's CURRENT
// name (which follows renames). The broker uses this so a client reconnecting
// by id always reaches the right session no matter how it was renamed. Returns
// ok=false if the id no longer exists or maps to an internal session.
func (p *Provider) SessionForID(id string) (string, bool) {
	out, err := exec.Command("tmux", tmuxArgs(p.socket, "display-message", "-t", id, "-p", "#{session_id}\t#{session_name}")...).Output()
	if err != nil {
		return "", false
	}
	parts := strings.SplitN(strings.TrimSpace(string(out)), "\t", 2)
	// tmux may interpret a dead $N as a literal session NAME "$N". Verify the
	// resolved object's own id so that ambiguity can never resurrect a dead handle.
	if len(parts) != 2 || parts[0] != id {
		return "", false
	}
	name := parts[1]
	if name == "" || isInternalSession(name) {
		return "", false
	}
	return name, true
}
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
// 8 (was 6) absorbs footers that grow suffixes ("· 1 background terminal running ·
// /ps to view · /stop to close") and wrap to an extra line.
const interruptScanLines = 8

// DetectState classifies a session's visible screen:
//   - "working": the agent's "esc to interrupt" footer is showing;
//   - "waiting": the agent is BLOCKED on the user — a numbered option dialog
//     ("Do you want to proceed?  ❯ 1. Yes / 2. No…") is on screen;
//   - "idle": neither.
//
// A passive, point-in-time capture-pane read: no history, no background
// sampler — computed on demand when /sessions is requested.
func DetectState(socket, name string) string {
	// Bound the capture so one wedged pane on a loaded node can't stall the whole
	// (now-parallel) refresh; a timed-out or failed read falls back to "idle".
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "tmux", tmuxArgs(socket, "capture-pane", "-p", "-t", name)...).Output()
	if err != nil {
		return "idle"
	}
	if screenHasInterrupt(out) {
		return "working"
	}
	// The agent delegated to background sub-agents and is waiting on THEM, not on
	// the user ("Waiting for 2 background agents to finish"). That's working, not a
	// decision — never flag it for attention.
	if bgAgentsWaitingRe.Match(out) {
		return "working"
	}
	if screenHasWaitingPrompt(out) {
		return "waiting"
	}
	return "idle"
}

// bgAgentsWaitingRe matches the footer an agent shows while blocked on its own
// spawned sub-agents — "Waiting for N background agents to finish". This is
// delegated WORK in progress, never a prompt for the user.
var bgAgentsWaitingRe = regexp.MustCompile(`(?i)waiting for \d+ background agents?`)

// agentsManagerRe matches the background-agents MANAGER list chrome — "↑/↓ to
// select · Enter to view", "← for agents · ↓ to manage". It reuses the same
// up/down navigation cue as a real option dialog but is NOT a user choice, so it
// must NOT count as "waiting".
var agentsManagerRe = regexp.MustCompile(`(?i)(enter to view|← for agents|↓ to manage|to manage tasks)`)

// waitingScanLines bounds the dialog scan: a selection menu renders near the
// bottom — but some agent TUIs draw a status block BELOW it, so the window is
// generous enough to still reach the menu's footer.
const waitingScanLines = 22

var (
	// The SELECTED row of a numbered option dialog: "❯ 1. Yes". The bare "❯" is
	// just the composer prompt (always on screen), so the digit is required.
	waitingSelectorRe = regexp.MustCompile(`^\s*│?\s*❯\s*\d+\.\s`)
	// Any other (unselected) option row: "  2. No, and tell Claude…".
	waitingOptionRe = regexp.MustCompile(`^\s*│?\s*\d+\.\s`)
	// The footer an interactive selection menu prints WHILE blocked on a choice
	// — e.g. "Enter to select · ↑/↓ to navigate · Esc to cancel". The most
	// robust "waiting for you to pick" signal: an explicit string the TUI emits,
	// independent of any selector GLYPH (custom agents mark the selected row with
	// COLOR, not a "❯", so the glyph heuristic alone misses them). Anchored on
	// the up/down navigation cue so ordinary prose can't trip it.
	waitingFooterRe = regexp.MustCompile(`(?i)(↑/↓|↑ ↓|↑↓|up/?down|arrow keys|use arrows).{0,40}(navigate|select|choose|move)`)
)

// screenHasWaitingPrompt reports whether the screen tail shows an interactive
// selection menu blocked on the user. True if EITHER:
//   - a menu footer hint is present ("↑/↓ to navigate" etc.) — robust across
//     custom TUIs that don't draw a "❯" selector; or
//   - a "❯ N." selected row PLUS another numbered option row (Claude-style
//     permission dialogs) — a single typed draft like "❯ 1. fix it" can't
//     satisfy both.
func screenHasWaitingPrompt(screen []byte) bool {
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	start := len(lines) - waitingScanLines
	if start < 0 {
		start = 0
	}
	tail := lines[start:]
	for _, l := range tail {
		// Skip the background-agents manager list: it shows "↑/↓ to select · Enter
		// to view", which matches the dialog-footer cue but is the agent browsing its
		// own sub-agents, not a choice put to the user.
		if waitingFooterRe.MatchString(l) && !agentsManagerRe.MatchString(l) {
			return true
		}
	}
	selector, options := false, 0
	for _, l := range tail {
		if waitingSelectorRe.MatchString(l) {
			selector = true
			options++
		} else if waitingOptionRe.MatchString(l) {
			options++
		}
	}
	return selector && options >= 2
}

// screenHasInterrupt reports whether any interrupt hint appears in the last few
// non-blank lines of a captured screen.
//
// ADJACENT lines are checked JOINED (no separator): the footer grows suffixes
// and wraps at the pane width, and the wrap point — which shifts as the
// elapsed-time text ticks ("8s" → "1m 42s") — can land INSIDE the phrase
// ("…esc to inte" / "rrupt) · 1 background…"), so no single captured line
// contains it. A wrapped line is always immediately followed by its
// continuation, so joining adjacent lines reconstructs the phrase; a blank
// line is never a wrap and breaks the join.
func screenHasInterrupt(screen []byte) bool {
	lines := strings.Split(strings.TrimRight(string(screen), "\n"), "\n")
	checked := 0
	var run []string // current run of ADJACENT non-blank lines, gathered bottom-up
	runHasHint := func() bool {
		if len(run) == 0 {
			return false
		}
		var b strings.Builder
		for i := len(run) - 1; i >= 0; i-- { // back to screen order
			b.WriteString(run[i])
		}
		joined := strings.ToLower(b.String())
		for _, hint := range interruptHints {
			if strings.Contains(joined, hint) {
				return true
			}
		}
		return false
	}
	for i := len(lines) - 1; i >= 0 && checked < interruptScanLines; i-- {
		l := strings.TrimRight(lines[i], " \t")
		if strings.TrimSpace(l) == "" {
			if runHasHint() {
				return true
			}
			run = run[:0]
			continue
		}
		checked++
		run = append(run, l)
	}
	return runHasHint()
}

// internalSessionPrefix marks tmux sessions that are ut's own infrastructure
// (the broker supervisor that respawns the broker). They live on the same -L
// socket so they ride tmux's lifecycle, but must never surface to clients.
const internalSessionPrefix = "_ut-"

// isInternalSession reports whether a session is ut infrastructure, not a user
// session — it is hidden from List and rejected by Has so clients can't attach.
func isInternalSession(name string) bool { return strings.HasPrefix(name, internalSessionPrefix) }

// ListSessionInventory returns session metadata without capturing every pane.
// A missing server / no sessions yields an empty list, not an error.
func ListSessionInventory(socket string) []SessionInfo {
	// session_id ($N) is the STABLE handle clients connect by (survives rename).
	// It and @ut_agent are placed AFTER pane_current_path so a tab inside the path
	// can't shift the fixed trailing fields — both id and the agent flag are
	// tab-free, so reading from the end is safe (SplitN keeps the path in f[4]).
	out, err := exec.Command("tmux", tmuxArgs(socket, "list-sessions", "-F",
		"#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}\t#{pane_current_path}\t#{session_id}\t#{@ut_agent}")...).Output()
	if err != nil {
		return []SessionInfo{}
	}
	sessions := []SessionInfo{}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		f := strings.SplitN(line, "\t", 7)
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
		id := ""
		if len(f) >= 6 {
			id = f[5]
		}
		agent := len(f) >= 7 && f[6] == "1"
		sessions = append(sessions, SessionInfo{
			Name: f[0], Windows: windows, Attached: attached > 0, Activity: act, Path: path,
			Agent: agent, ID: id,
		})
	}
	return sessions
}

// ListSessions returns a fully-classified snapshot for direct Provider callers.
// The broker uses ListSessionInventory + DetectState separately so it can avoid
// scanning hidden and agent panes on every foreground refresh.
func ListSessions(socket string) []SessionInfo {
	sessions := ListSessionInventory(socket)
	classifySessions(socket, sessions)
	return sessions
}

// classifySessions classifies each session's state CONCURRENTLY. DetectState
// forks a capture-pane, which is slow on a loaded node; doing it serially made a full refresh cost
// (N × slow-capture), so the cached state lagged reality by tens of seconds — a
// finished agent kept its "working" dot long after its turn ended. Fan out
// (bounded) so a refresh costs ~one slow capture, not N. Each goroutine writes a
// distinct slice element, so no lock is needed.
func classifySessions(socket string, sessions []SessionInfo) {
	sem := make(chan struct{}, 16)
	var wg sync.WaitGroup
	for i := range sessions {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			sessions[i].State = DetectState(socket, sessions[i].Name)
		}(i)
	}
	wg.Wait()
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

// Dial starts a control-mode client attached to an EXISTING named session.
// Creation belongs exclusively to Create/Spawn/Manager.Ensure. Keeping Dial
// attach-only is a safety boundary: a stale stable id or reconnect typo can
// disconnect, but can never manufacture a duplicate session.
func Dial(ctx context.Context, socket, session string) (*Client, error) {
	id, ok := sessionIDForName(socket, session)
	if !ok {
		return nil, fmt.Errorf("no such session: %q", session)
	}
	// -CC: control mode with echo disabled (the programmatic form iTerm2 uses).
	// -L SOCKET: a dedicated tmux server, isolating our sessions from any other.
	// Attach by the already-resolved stable id, avoiding tmux's name-prefix and
	// $N name/id ambiguity. attach-session cannot create if the session disappears
	// in the small gap after the lookup.
	cmd := exec.CommandContext(ctx, "tmux", tmuxArgs(socket, "-CC", "attach-session", "-t", id)...)
	ptmx, err := pty.Start(cmd)
	if err != nil {
		return nil, fmt.Errorf("start tmux under pty: %w", err)
	}
	_ = pty.Setsize(ptmx, &pty.Winsize{Rows: 30, Cols: 100})

	c := &Client{cmd: cmd, ptmx: ptmx, socket: socket, session: session, primary: discoverPane(socket, id), outCh: make(chan Output, 1024)}
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

// tmux user-options that mark a session as agent-created (via `ut spawn`) and
// record its cleanup timing. @ut_agent hides it from the app UI (shown only
// behind a toggle); @ut_reap_idle is the per-session idle budget in seconds
// (0 skips early idle cleanup); @ut_done_at records when the command finished
// so every finished agent session can be retained for at most seven days.
const (
	optAgent    = "@ut_agent"
	optReapIdle = "@ut_reap_idle"
	optDone     = "@ut_done" // set by the wrapper the instant cmd returns — the deterministic "job finished" signal
	optDoneAt   = "@ut_done_at"
)

// SpawnSession creates a detached session that RUNS cmd directly as its process
// — no send-keys, so there is no race against a still-starting shell (the bug
// that left `ut spawn` commands typed-but-unsubmitted on a loaded node). After
// cmd finishes it drops into an interactive shell so the session persists with
// the output visible (for `ut tail` / attach). cmd is passed as one argv to
// `sh -c`, so arbitrary content is safe (no shell re-quoting by us).
//
// It is tagged as an agent session (hidden from the UI, idle-reaped) with the
// given idle cleanup time in seconds (0 skips the shorter idle cleanup, while
// the seven-day post-completion maximum still applies). Because that trailing
// interactive shell loads the user's full rc (e.g. p10k + gitstatus → ~3
// processes per shell), dozens of finished spawns would otherwise pile up; the
// reaper clears the idle ones.
func SpawnSession(socket, name, startDir, cmd string, idleSec int) error {
	args := []string{"new-session", "-d", "-s", name}
	if startDir != "" {
		args = append(args, "-c", startDir)
	}
	// When cmd returns, mark the session done (a tmux option, set from inside the
	// pane via $TMUX) BEFORE dropping into the interactive shell. This is the
	// reaper's deterministic "the job finished" signal — far more robust than
	// guessing from the foreground command name (on macOS `/bin/sh` is bash, so a
	// still-running `sh -c` wrapper looks like an interactive bash).
	wrapper := cmd + "\ntmux set-option " + optDoneAt + " \"$(date +%s)\" 2>/dev/null\n" +
		"tmux set-option " + optDone + " 1 2>/dev/null\nexec \"${SHELL:-sh}\" -i"
	args = append(args, "sh", "-c", wrapper)
	out, err := exec.Command("tmux", tmuxArgs(socket, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("spawn %q: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	// Tag it (best-effort): the reaper and UI filter key off these options.
	_ = exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", name, optAgent, "1")...).Run()
	_ = exec.Command("tmux", tmuxArgs(socket, "set-option", "-t", name, optReapIdle, strconv.Itoa(idleSec))...).Run()
	return nil
}

// reapableShells are the interactive shells a spawned session drops into once
// its command finishes (the `exec "${SHELL:-sh}" -i` tail). After @ut_done is
// set, the wrapper is gone, so the foreground is either this idle shell (safe to
// reap) or a NEW job the user started in the post-job shell (foreground = that
// job → not a shell → keep). This guard is only consulted once @ut_done==1, so
// the macOS "sh==bash wrapper" false positive can't occur here.
var reapableShells = map[string]bool{
	"zsh": true, "bash": true, "fish": true, "ksh": true, "tcsh": true, "csh": true, "sh": true, "dash": true,
}

// ReapIdleAgentSessions kills agent (@ut_agent) sessions whose command has
// finished (@ut_done) and which have either sat idle longer than their
// @ut_reap_idle setting or passed the seven-day post-completion maximum. It
// returns the reaped names. Deterministic and
// conservative — a session is removed ONLY when ALL hold:
//   - it is tagged agent (@ut_agent==1),
//   - its job has finished (@ut_done==1) — a still-running job, even a silent
//     one, never sets this, so live work is never touched,
//   - its idle setting or the hard maximum has expired,
//   - its foreground is an interactive shell (guards the rare case of a new job
//     started by hand in the post-job shell).
//
// Called periodically by the broker.
func ReapIdleAgentSessions(socket string) []string {
	out, err := exec.Command("tmux", tmuxArgs(socket, "list-sessions", "-F",
		fmt.Sprintf("#{session_name}\t#{%s}\t#{%s}\t#{%s}\t#{%s}\t#{session_activity}",
			optAgent, optDone, optReapIdle, optDoneAt))...).Output()
	if err != nil {
		return nil
	}
	now := time.Now().Unix()
	var reaped []string
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		f := strings.SplitN(line, "\t", 6)
		if len(f) < 6 || f[1] != "1" || f[2] != "1" { // not agent, or job not finished
			continue
		}
		name := f[0]
		leash := session.DefaultReapIdleSec
		if f[3] != "" {
			if n, e := strconv.Atoi(f[3]); e == nil {
				leash = n
			}
		}
		doneAt, _ := strconv.ParseInt(f[4], 10, 64)
		act, _ := strconv.ParseInt(f[5], 10, 64)
		if doneAt <= 0 {
			// Sessions created before @ut_done_at was introduced still carry a
			// reliable @ut_done marker. Their last tmux activity is the safest
			// available approximation of completion time.
			doneAt = act
		}
		if !session.AgentSessionExpired(now, act, doneAt, leash) {
			continue
		}
		// Finished + expired — reap unless a NEW job is now running.
		fg, e := exec.Command("tmux", tmuxArgs(socket, "display-message", "-p", "-t", name, "#{pane_current_command}")...).Output()
		if e != nil || !reapableShells[strings.TrimSpace(string(fg))] {
			continue
		}
		if KillSession(socket, name) == nil {
			reaped = append(reaped, name)
		}
	}
	return reaped
}

// KillSession terminates a session and everything running in it.
func KillSession(socket, name string) error {
	out, err := exec.Command("tmux", tmuxArgs(socket, "kill-session", "-t", name)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("kill %q: %v: %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

// sessionIDForName performs a genuinely exact name lookup. `tmux has-session
// -t =NAME` is not exact when NAME looks like "$N": tmux still interprets it as
// a session id, which is the ambiguity that allowed literal-$N duplicates.
func sessionIDForName(socket, name string) (string, bool) {
	if isInternalSession(name) {
		return "", false // infra sessions are not attachable by clients
	}
	out, err := exec.Command("tmux", tmuxArgs(socket, "list-sessions", "-F", "#{session_name}\t#{session_id}")...).Output()
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) == 2 && parts[0] == name {
			return parts[1], true
		}
	}
	return "", false
}

// HasSession reports whether a session with this exact NAME exists. It does not
// treat a stable session id as a name.
func HasSession(socket, name string) bool {
	_, ok := sessionIDForName(socket, name)
	return ok
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

// Resize sizes the window to this client's view. It is an ASK, not a command:
// tmux's window-size=latest policy gives the window to the client that most
// recently interacted — so whichever client you're actively USING (this viewer,
// or a real terminal) drives the size, and the others render that authoritative
// %layout-change size (shrinking their own font to fit). That is exactly the
// behavior we want: the pane you're working in fills; an idle co-attached client
// just follows. (An earlier "stay passive when a terminal is attached" override
// was wrong — it made Argus defer to an IDLE terminal and letterbox itself.)
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
		args = []string{"capture-pane", "-p", "-e", "-t", c.primary}      // visible screen only
		prefix = esc + "[?1049h" + esc + "[2J" + esc + "[3J" + esc + "[H" // enter alt, clear, clear scrollback, home
	} else {
		args = []string{"capture-pane", "-p", "-e", "-S", "-10000", "-t", c.primary} // + scrollback
		prefix = esc + "[?1049l" + esc + "[2J" + esc + "[3J" + esc + "[H"            // ensure main, clear, clear scrollback, home
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
