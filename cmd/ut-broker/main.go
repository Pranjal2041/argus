// Command ut-broker is the per-host universal_tmux broker. It owns one tmux
// server (a dedicated `-L` socket), lists its sessions, and serves each to
// xterm.js / native clients over a binary WebSocket — on a local TCP port
// (dev) or, with --tsnet-host, directly on the tailnet via embedded tsnet.
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"

	"github.com/coder/websocket"
	"tailscale.com/tsnet"

	"universal-tmux/internal/broker"
	"universal-tmux/internal/forward"
	"universal-tmux/internal/fsvc"
	"universal-tmux/internal/gitsvc"
	"universal-tmux/internal/gitui"
	"universal-tmux/internal/jupyter"
	"universal-tmux/internal/labsvc"
	"universal-tmux/internal/mesh"
	"universal-tmux/internal/portfwd"
	sess "universal-tmux/internal/session" // aliased: the `session` flag var below shadows the package name
	webassets "universal-tmux/web"
)

func main() {
	// Mesh CLIENT mode: `ut-broker <verb> ...` (wrapped by the `ut` script) is a
	// fabric command, not the server. Dispatch before any server setup.
	if len(os.Args) > 1 && isMeshVerb(os.Args[1]) {
		os.Exit(runClient(os.Args[1:]))
	}

	listen := flag.String("listen", "127.0.0.1:8722", "local host:port (the port is reused on the tailnet when --tsnet-host is set)")
	session := flag.String("session", "ut-demo", "fallback session when none is requested; warmed only when it already exists")
	tmuxSock := flag.String("tmux-socket", "ut", "dedicated tmux server socket (-L); isolates our sessions from any other tmux")
	webDir := flag.String("web", "", "serve web assets from this dir instead of the embedded copy (dev)")
	tsHost := flag.String("tsnet-host", "", "join the tailnet under this hostname and listen there instead of locally")
	tsDir := flag.String("tsnet-dir", "", "tsnet state dir (default: tsnet's own under $HOME)")
	name := flag.String("name", "", "display name reported to clients via /whoami (default: hostname)")
	shell := flag.String("shell", "", "shell to host for new sessions (Windows ConPTY only; default cmd.exe)")
	extraListen := flag.String("extra-listen", "", "additional best-effort host:port to ALSO serve the same mux on (e.g. this host's tailnet IP, so remote tailnet clients can reach a loopback-bound broker). A bind failure here is logged and ignored — it never stops the primary --listen.")
	flag.Parse()

	// Display name the client shows for this broker's device, plus the OS hostname.
	// The hostname is what /history records as a session's `node`; reporting it here
	// (alongside the possibly-different display name from --name) lets a client map a
	// history row back to this machine even when --name != hostname (e.g. Windows
	// runs with --name=pranjala-win but Hostname()=DESKTOP-EFJI6J4). Same "local"
	// fallback as histNodeName so the two always agree.
	hostName, _ := os.Hostname()
	if hostName == "" {
		hostName = "local"
	}
	displayName := *name
	if displayName == "" {
		displayName = hostName
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := broker.BackupDurableState(); err != nil {
		log.Printf("warn: initial durable-state backup: %v", err)
	}
	go broker.RunDailyBackupLoop(ctx)

	mgr := broker.NewManager(ctx, makeProvider(*tmuxSock, *shell)) // makeProvider: tmux (Unix) or ConPTY (Windows)
	fwdMgr := forward.NewManager()                                 // port-hub agent (used when this broker is the local agent)
	jupyterMgr := jupyter.NewManager()                             // ensures a JupyterLab on this host for the notebook feature
	mgr.SetHistoryLimit(100000)                                    // large scrollback for new sessions
	if *session != "" {
		if err := mgr.WarmExisting(*session); err != nil {
			log.Printf("warn: warming session %q: %v", *session, err)
		}
	}

	var assets http.FileSystem = http.FS(webassets.Assets)
	if *webDir != "" {
		if st, e := os.Stat(*webDir); e == nil && st.IsDir() {
			assets = http.Dir(*webDir)
		}
	}

	mux := http.NewServeMux()
	mux.Handle("/", http.FileServer(assets))
	// Identity handshake: the client probes this on every online tailnet peer and
	// treats a device as a broker ONLY if it returns this exact marker — so an
	// unrelated service listening on :8722 is never mistaken for one.
	mux.HandleFunc("/whoami", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"service": "universal-tmux-broker",
			"proto":   1,
			"name":    displayName,
			"host":    hostName, // os.Hostname(): equals /history's `node`, so a client can map a history row to this machine even when name (--name) differs
			"socket":  *tmuxSock,
			"os":      runtime.GOOS, // lets the phone pick the Mac broker as the sync host
		})
	})
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		var sessions []sess.Info
		if r.URL.Query().Get("scope") == "foreground" {
			sessions = mgr.ForegroundSessions()
		} else {
			sessions = mgr.Sessions()
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"sessions": sessions})
	})
	// /ccstatus — command-center status relay. POST: the macOS client publishes its
	// per-session AI status blob (opaque JSON). GET: any client (the phone) reads the
	// last published blob. The broker only stores+serves bytes; it never parses them.
	mux.HandleFunc("/ccstatus", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method == http.MethodPost {
			body, _ := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			mgr.SetCommandCenter(body)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if b := mgr.CommandCenter(); b != nil {
			_, _ = w.Write(b)
		} else {
			_, _ = io.WriteString(w, "{}")
		}
	})
	// /ccoverride — a manual command-center status set from a client that can't run
	// the status model (the phone). POST ?session=NAME&label=LABEL queues it; the Mac
	// polls GET, applies it as a correction + re-publishes /ccstatus, then clears it
	// with POST ?session=NAME&clear=TS. Transient relay (in-memory).
	mux.HandleFunc("/ccoverride", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		if r.Method == http.MethodPost {
			if session := q.Get("session"); session != "" {
				if cs := q.Get("clear"); cs != "" {
					ts, _ := strconv.ParseInt(cs, 10, 64)
					mgr.ClearCCOverride(session, ts)
				} else if label := q.Get("label"); label != "" {
					mgr.SetCCOverride(session, label)
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
			return
		}
		ovs := mgr.CCOverrides()
		list := make([]map[string]any, 0, len(ovs))
		for s, v := range ovs {
			list = append(list, map[string]any{"session": s, "label": v.Label, "ts": v.TS})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"overrides": list})
	})
	// /hidden — user-hidden sessions, broker-owned so the hide syncs across devices.
	// POST ?session=NAME&hidden=true|false toggles + persists; the flag also rides
	// /sessions (Info.Hidden). GET returns the set (debugging).
	mux.HandleFunc("/hidden", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			if name := r.URL.Query().Get("session"); name != "" {
				mgr.SetHidden(name, r.URL.Query().Get("hidden") == "true")
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"hidden": mgr.HiddenNames()})
	})
	// /history — durable per-node session history: every session that has existed
	// here, with its node + the folders it ran in (with timestamps). Lets a client
	// show "where was session X running" after it's gone. GET only.
	mux.HandleFunc("/history", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"sessions": mgr.History()})
	})
	// /userdata — sync store for user-global app data (Workflows, Todo Maps). The user's
	// Mac broker is the designated sync host; the macOS app and the phone both keep a local
	// copy and sync here with last-write-wins (the blob carries its own `updatedAt`).
	// GET ?key=K returns the stored blob; POST ?key=K body=<blob> stores it (keeping the
	// newer of incoming vs stored) and returns the winner.
	// /journal/* — the sync host's append-only inbox for phone-captured journal
	// events (utterances typed on Android). POST /journal/append adds JSONL;
	// GET /journal/peek returns {off, data}; POST /journal/ack?off=N truncates
	// what the Mac app has ingested. See userdata.go.
	mux.HandleFunc("/journal/append", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 1*1024*1024))
		if err := broker.JournalAppend(body); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	mux.HandleFunc("/journal/peek", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		off, data := broker.JournalPeek()
		_ = json.NewEncoder(w).Encode(map[string]any{"off": off, "data": string(data)})
	})
	mux.HandleFunc("/journal/ack", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if r.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		off, _ := strconv.ParseInt(r.URL.Query().Get("off"), 10, 64)
		if err := broker.JournalAck(off); err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	mux.HandleFunc("/userdata", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		key := r.URL.Query().Get("key")
		if key == "" {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": "missing key"})
			return
		}
		if r.Method == http.MethodPost {
			body, _ := io.ReadAll(io.LimitReader(r.Body, 8*1024*1024))
			_, _ = w.Write(broker.SetUserData(key, body))
			return
		}
		if b := broker.UserData(key); b != nil {
			_, _ = w.Write(b)
		} else {
			_, _ = w.Write([]byte("{}"))
		}
	})
	// /automation/unattended is the one durable cross-device switch for work
	// that may proceed without the user present. The first capability is narrow:
	// automatically approve Lab access requests and recorded run proposals.
	mux.HandleFunc("/automation/unattended", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		state := broker.UnattendedMode()
		switch r.Method {
		case http.MethodGet:
		case http.MethodPost:
			raw := strings.ToLower(r.URL.Query().Get("enabled"))
			if raw != "1" && raw != "0" && raw != "true" && raw != "false" {
				http.Error(w, "enabled must be true or false", http.StatusBadRequest)
				return
			}
			state = broker.SetUnattendedMode(raw == "1" || raw == "true")
			if state.Enabled {
				go labUnattendedSweep() // resolve anything already waiting immediately
			}
		default:
			http.Error(w, "GET or POST only", http.StatusMethodNotAllowed)
			return
		}
		_ = json.NewEncoder(w).Encode(state)
	})
	// /recent — a session's recent rendered scrollback as plain text, for the
	// macOS command center's status updater (claude -p reads it). ?session=NAME
	// &lines=N (default 400). Forks capture-pane per call, so clients must poll
	// it sparingly (per active session, ~30s).
	mux.HandleFunc("/recent", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		name := q.Get("session")
		if name == "" {
			name = *session
		}
		lines, _ := strconv.Atoi(q.Get("lines"))
		text, err := mgr.Recent(name, lines)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, text)
	})
	// /render-source — exact agent-authored Markdown for the response currently
	// visible in a terminal. Resolution is transcript-backed and screen-matched;
	// a miss is a normal 404 so old/non-agent sessions retain the styled-terminal
	// fallback in clients. Nothing is sampled in the background: this runs only
	// when the user explicitly invokes Render Output.
	mux.HandleFunc("/render-source", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet {
			http.Error(w, "GET only", http.StatusMethodNotAllowed)
			return
		}
		name := r.URL.Query().Get("session")
		if name == "" {
			name = *session
		}
		source, err := mgr.RenderSource(name)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(source)
	})
	mux.HandleFunc("/control", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		var err error
		switch q.Get("action") {
		case "create":
			err = mgr.Create(q.Get("session"), q.Get("dir"))
		case "spawn": // create a session RUNNING the POST-body command (no keystroke race)
			body, _ := io.ReadAll(r.Body)
			idleSec := sess.DefaultReapIdleSec // idle cleanup; ?idle=SEC overrides (0 = retain until the 7d maximum)
			if v := q.Get("idle"); v != "" {
				idleSec, _ = strconv.Atoi(v)
			}
			err = mgr.Spawn(q.Get("session"), q.Get("dir"), string(body), idleSec)
		case "kill":
			err = mgr.Kill(q.Get("session"))
		case "rename":
			err = mgr.Rename(q.Get("session"), q.Get("to"))
		default:
			err = fmt.Errorf("unknown action %q", q.Get("action"))
		}
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("session")
		if name == "" {
			name = *session
		}
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer c.CloseNow()
		_ = mgr.Serve(r.Context(), c, name) // err is normal on client disconnect
	})
	// /exec — the mesh's remote-exec primitive: run a command on THIS host and
	// return its captured output + exit code. With ?session=NAME it runs inside
	// that persistent shell (env/cwd/venv preserved); otherwise a fresh process.
	// POST body = the command; query: session, dir, timeout(sec). Reached from
	// another machine through the local broker's /mesh/proxy.
	mux.HandleFunc("/exec", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		cmd := q.Get("cmd")
		if cmd == "" {
			if body, _ := io.ReadAll(r.Body); len(body) > 0 {
				cmd = string(body)
			}
		}
		if strings.TrimSpace(cmd) == "" {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": "empty command"})
			return
		}
		timeout, _ := strconv.Atoi(q.Get("timeout"))
		res := mgr.Exec(sess.ExecRequest{
			Cmd: cmd, Session: q.Get("session"), Dir: q.Get("dir"), TimeoutSec: timeout,
		})
		_ = json.NewEncoder(w).Encode(res)
	})
	// /stream — read-only live feed of a session (snapshot + output) as a flushing
	// HTTP response. Behind `ut tail`; plain HTTP so it relays cleanly through the
	// mesh proxy without a WebSocket double-hop.
	mux.HandleFunc("/stream", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("session")
		if name == "" {
			name = *session
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("X-Accel-Buffering", "no")
		flush := func() {
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
		w.WriteHeader(http.StatusOK)
		flush()
		_ = mgr.Stream(r.Context(), w, flush, name)
	})
	// /send — type text into a session's shell and return immediately (no capture).
	// Used by `ut spawn` (fire a long job into a fresh session) and `ut send`.
	mux.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		text := q.Get("text")
		if text == "" {
			if body, _ := io.ReadAll(r.Body); len(body) > 0 {
				text = string(body)
			}
		}
		enter := q.Get("enter") != "0" // append Enter unless ?enter=0
		if err := mgr.SendText(q.Get("session"), text, enter); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	})
	// Port hub: list this host's listening ports, and tunnel one to a tailnet
	// client (WebSocket <-> 127.0.0.1:port). localhost-only target.
	mux.HandleFunc("/ports", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		ports := portfwd.ListeningPorts()
		if r.URL.Query().Get("probe") == "1" { // mark which ports actually speak HTTP
			ports = portfwd.ProbeWeb(ports)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ports": ports})
	})
	mux.HandleFunc("/forward", func(w http.ResponseWriter, r *http.Request) {
		port := r.URL.Query().Get("port")
		if !portfwd.ValidPort(port) {
			http.Error(w, "bad port", http.StatusBadRequest)
			return
		}
		c, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer c.CloseNow()
		portfwd.Forward(r.Context(), c, port)
	})
	// Port-hub agent: manage local forwards (bind a local port, tunnel it to a
	// remote broker's /forward). GET=list, POST=start, DELETE=stop.
	mux.HandleFunc("/forwards", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		switch r.Method {
		case http.MethodPost:
			remotePort, _ := strconv.Atoi(q.Get("remotePort"))
			localPort, _ := strconv.Atoi(q.Get("localPort"))
			f, err := fwdMgr.Start(q.Get("brokerHost"), q.Get("brokerName"), q.Get("scheme"), remotePort, localPort, q.Get("label"))
			if err != nil {
				w.WriteHeader(http.StatusBadRequest)
				_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
				return
			}
			_ = json.NewEncoder(w).Encode(f)
		case http.MethodDelete:
			fwdMgr.Stop(q.Get("id"))
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"forwards": fwdMgr.List()})
		}
	})
	// Notebook (Exp 0): ensure a JupyterLab is running on THIS host and return its
	// loopback {port, token}; the client reaches it over a port-forward + webview.
	mux.HandleFunc("/jupyter", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		info, err := jupyterMgr.Ensure()
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(info)
	})
	// Git panel: ensure lazygit on this host (PATH → UT_HOME → one-time download)
	// and run it in ?dir as a hidden agent session the client attaches to like any
	// terminal. Same dir → same session (fast re-open); quitting lazygit marks the
	// session done for the idle reaper.
	mux.HandleFunc("/gitui", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		dir := r.URL.Query().Get("dir")
		if dir == "" {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": "missing dir"})
			return
		}
		bin, err := gitui.Resolve()
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		sum := sha256.Sum256([]byte(dir))
		name := "_git-" + hex.EncodeToString(sum[:4])
		if !mgr.Has(name) {
			// 30-min idle leash: an abandoned panel gets reaped; quitting lazygit
			// sets @ut_done so the reaper collects it promptly. Plain double-quote
			// wrapping works for BOTH sh and cmd.exe (strconv.Quote would escape
			// Windows backslashes and break the path).
			if err := mgr.Spawn(name, dir, "\""+bin+"\"", 1800); err != nil {
				w.WriteHeader(http.StatusBadRequest)
				_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
				return
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"session": name})
	})
	// Git panel (read-only viewer): thin views over `git` in a working directory —
	// status summary, log, unified diffs, blame, file-at-revision. All read-only
	// (--no-optional-locks); the client webview renders (diff2html + hljs).
	gitJSON := func(w http.ResponseWriter, v any, err error) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("/git/summary", func(w http.ResponseWriter, r *http.Request) {
		s, err := gitsvc.GetSummary(r.URL.Query().Get("dir"))
		gitJSON(w, s, err)
	})
	mux.HandleFunc("/git/log", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		n, _ := strconv.Atoi(q.Get("n"))
		skip, _ := strconv.Atoi(q.Get("skip"))
		log, err := gitsvc.GetLog(q.Get("dir"), n, skip, q.Get("all") == "1")
		gitJSON(w, log, err)
	})
	mux.HandleFunc("/git/blame", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		lines, err := gitsvc.GetBlame(q.Get("dir"), q.Get("path"), q.Get("ref"))
		gitJSON(w, map[string]any{"lines": lines}, err)
	})
	mux.HandleFunc("/git/diff", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		out, err := gitsvc.GetDiff(q.Get("dir"), q.Get("scope"), q.Get("hash"), q.Get("hash2"), q.Get("path"))
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write(out)
	})
	mux.HandleFunc("/git/show", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		out, err := gitsvc.GetShow(q.Get("dir"), q.Get("ref"), q.Get("path"))
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write(out)
	})
	// Pull-request review via gh (see internal/gitsvc/prsvc.go). All keyed by
	// ?dir=; write actions (review/merge/comment) are POST. Errors carry
	// needsAuth/noGH/notRepo flags so the UI can guide.
	prJSON := func(w http.ResponseWriter, body []byte, e *gitsvc.PRError) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		if e != nil {
			w.WriteHeader(http.StatusOK) // a classified error, not an HTTP failure
			_, _ = w.Write(prErrorJSON(e))
			return
		}
		_, _ = w.Write(body)
	}
	mux.HandleFunc("/git/prs", func(w http.ResponseWriter, r *http.Request) {
		out, e := gitsvc.ListPRs(r.URL.Query().Get("dir"), r.URL.Query().Get("state"))
		prJSON(w, out, e)
	})
	mux.HandleFunc("/git/pr", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		out, e := gitsvc.ViewPR(q.Get("dir"), q.Get("num"))
		prJSON(w, out, e)
	})
	mux.HandleFunc("/git/pr/diff", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		out, e := gitsvc.PRDiff(q.Get("dir"), q.Get("num"))
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if e != nil {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(prErrorJSON(e))
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write(out)
	})
	mux.HandleFunc("/git/pr/review", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		e := gitsvc.ReviewPR(q.Get("dir"), q.Get("num"), q.Get("event"), q.Get("body"))
		prActionResult(w, e)
	})
	mux.HandleFunc("/git/pr/merge", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		e := gitsvc.MergePR(q.Get("dir"), q.Get("num"), q.Get("method"))
		prActionResult(w, e)
	})
	mux.HandleFunc("/git/pr/comment", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		e := gitsvc.CommentPR(q.Get("dir"), q.Get("num"), q.Get("body"))
		prActionResult(w, e)
	})
	// File service: browse this host's filesystem (as the broker's user) and
	// stream file contents. /fs/home → starting points, /fs/list → a directory
	// (path may be relative/~/$VAR, resolved against an optional base cwd),
	// /fs/read → a file (Range + content-type, so large files and media stream).
	mux.HandleFunc("/fs/home", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(fsvc.Home())
	})
	mux.HandleFunc("/fs/list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		res, err := fsvc.List(q.Get("path"), q.Get("base"))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(res)
	})
	mux.HandleFunc("/fs/read", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fsvc.ServeFile(w, r, r.URL.Query().Get("path"))
	})
	// /fs/find → the files under a root (recursive, capped), for the editor's ⌘P quick-open.
	mux.HandleFunc("/fs/find", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		_ = json.NewEncoder(w).Encode(fsvc.Find(r.URL.Query().Get("path"), limit))
	})
	// /fs/grep → content search under a root (ripgrep if present, else a bounded
	// walk), for the Files "search in folder" panel. query=, regex=1 optional.
	mux.HandleFunc("/fs/grep", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		_ = json.NewEncoder(w).Encode(fsvc.Grep(q.Get("path"), q.Get("query"), q.Get("regex") == "1"))
	})
	// /fs/stat → resolve+classify a (possibly relative/~/$VAR) path against a base
	// cwd, so a terminal-clicked path routes into Files on the right host.
	mux.HandleFunc("/fs/stat", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		_ = json.NewEncoder(w).Encode(fsvc.Stat(q.Get("path"), q.Get("base")))
	})
	// File mutations (the Files browser's context-menu ops + editor save).
	mux.HandleFunc("/fs/mkdir", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fsResult(w, fsvc.Mkdir(r.URL.Query().Get("path")))
	})
	mux.HandleFunc("/fs/rename", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		fsResult(w, fsvc.Rename(q.Get("path"), q.Get("to")))
	})
	mux.HandleFunc("/fs/delete", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fsResult(w, fsvc.Remove(r.URL.Query().Get("path")))
	})
	mux.HandleFunc("/fs/write", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		data, _ := io.ReadAll(r.Body)
		fsResult(w, fsvc.Write(r.URL.Query().Get("path"), data))
	})

	// Argus Lab (LAB-DESIGN.md): read routes for the hub plus key decisions for
	// the phone. The `ut lab` CLI operates on the store directly; these serve
	// remote viewers. The hub passes agentView=false and sees hidden content.
	mux.HandleFunc("/lab/sets", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		sets, _ := st.Sets()
		_ = json.NewEncoder(w).Encode(map[string]any{"sets": sets})
	})
	mux.HandleFunc("/lab/keys", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		ks, _ := st.Keys()
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": ks})
	})
	mux.HandleFunc("/lab/decide", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		policy := q.Get("policy")
		if q.Get("approve") == "1" && policy != "" && !labsvc.ValidPolicy(policy) {
			http.Error(w, "policy must be all, full-only, or none", http.StatusBadRequest)
			return
		}
		k, err := st.Decide(q.Get("key"), q.Get("approve") == "1", q.Get("project"), q.Get("note"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if k.Status == "active" && policy != "" {
			if err := st.SetPolicy(k.Set, policy); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(k)
	})
	mux.HandleFunc("/lab/brief", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		b, err := st.Brief(r.URL.Query().Get("set"), false)
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(b)
	})
	mux.HandleFunc("/lab/proposals", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		ps, _ := st.PendingProposals()
		_ = json.NewEncoder(w).Encode(map[string]any{"proposals": ps})
	})
	mux.HandleFunc("/lab/decide-run", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		if err := st.DecideRun(q.Get("set"), q.Get("run"), q.Get("approve") == "1", q.Get("note")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/lab/events", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		var evs []labsvc.Event
		if machine := q.Get("machine"); machine != "" {
			evs, err = st.MirrorEvents(machine, q.Get("set"), q.Get("run"))
		} else {
			dir := st.SetDir(q.Get("set"))
			if run := q.Get("run"); run != "" {
				dir = st.RunDir(q.Get("set"), run)
			}
			evs, err = st.Events(dir, false)
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"events": evs})
	})
	// Curation (human channel): hide an event, write a scoped human note.
	mux.HandleFunc("/lab/hide", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		// scope-level notes (global/machine/project) live outside sets;
		// ?scope routes the hide to the right notes directory
		var hideErr error
		if sc := q.Get("scope"); sc != "" {
			hideErr = st.HideNote(sc, q.Get("project"), q.Get("target"))
		} else {
			hideErr = st.Hide(q.Get("set"), q.Get("target"))
		}
		if hideErr != nil {
			http.Error(w, hideErr.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	// Archive view-state for a set or one run: a recorded, reversible human
	// event; agents are unaffected and nothing is deleted.
	mux.HandleFunc("/lab/archive", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		if err := st.SetArchived(q.Get("set"), q.Get("run"), q.Get("on") == "1"); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	// Human lifecycle correction for an orphaned run. This records that the
	// operator already verified the process is stopped; it never sends a signal.
	mux.HandleFunc("/lab/mark-stopped", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		if err := st.MarkRunStopped(q.Get("set"), q.Get("run"), q.Get("reason")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	// Scope-level notes (global, this machine, each project) for the hub's
	// Notes view. Hidden ones are included and flagged: the human sees what
	// they hid, agents never do.
	mux.HandleFunc("/lab/notes", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		ns, err := st.ListNotes()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		// store identity lets the hub write store-wide notes once per store,
		// not once per broker (cluster nodes share one NFS store)
		_ = json.NewEncoder(w).Encode(map[string]any{"store": st.StoreID(), "notes": ns})
	})
	mux.HandleFunc("/lab/note", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		if err := st.HumanNote(q.Get("scope"), q.Get("project"), q.Get("set"), q.Get("run"), q.Get("text")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	// A run's stored files (the params copy, the code diff, the log, the env
	// freeze), so the hub can show the substance of an experiment. ?tail=N
	// serves only the last N bytes (for logs).
	mux.HandleFunc("/lab/files", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		_ = json.NewEncoder(w).Encode(map[string]any{"files": st.RunFiles(q.Get("set"), q.Get("run"))})
	})
	mux.HandleFunc("/lab/file", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		p, err := st.RunFile(q.Get("set"), q.Get("run"), q.Get("name"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}
		if tail, _ := strconv.Atoi(q.Get("tail")); tail > 0 {
			f, err := os.Open(p)
			if err != nil {
				http.Error(w, err.Error(), http.StatusNotFound)
				return
			}
			defer f.Close()
			if fi, err := f.Stat(); err == nil && fi.Size() > int64(tail) {
				_, _ = f.Seek(fi.Size()-int64(tail), 0)
			}
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			_, _ = io.Copy(w, f)
			return
		}
		http.ServeFile(w, r, p)
	})
	// Human-only set controls for the hub: change the approval policy, revoke
	// the key.
	mux.HandleFunc("/lab/policy", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		q := r.URL.Query()
		if !labsvc.ValidPolicy(q.Get("policy")) {
			http.Error(w, "policy must be all, full-only, or none", http.StatusBadRequest)
			return
		}
		if err := st.SetPolicy(q.Get("set"), q.Get("policy")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/lab/revoke", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if _, err := st.Revoke(r.URL.Query().Get("key")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	// Dashboard equivalent of `ut lab init`. The set resolves the project cwd;
	// callers cannot provide an arbitrary filesystem path.
	mux.HandleFunc("/lab/init", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		results, err := st.InstallSetInstructions(r.URL.Query().Get("set"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"files": results})
	})
	// The permanent mirror this machine keeps of other machines' lab stores.
	mux.HandleFunc("/lab/mirror", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		st, err := labsvc.Open()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		ms, _ := st.ReadMirror()
		_ = json.NewEncoder(w).Encode(map[string]any{"mirror": ms})
	})

	ln, where, ts, err := listener(ctx, *listen, *tsHost, *tsDir)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	// Mesh: this broker can reach peer brokers over the tailnet (through its own
	// tsnet node, or — local mode — the host's Tailscale), so an agent talks only
	// to its LOCAL broker and we relay to any machine. /mesh/peers lists the
	// fabric; /mesh/proxy forwards any request (HTTP + WS) to a named peer.
	meshRouter := mesh.New(ts, displayName)
	mux.HandleFunc("/mesh/peers", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(map[string]any{"peers": meshRouter.Peers(r.Context())})
	})
	mux.HandleFunc("/mesh/proxy", func(w http.ResponseWriter, r *http.Request) {
		meshRouter.Proxy(w, r)
	})

	// Argus Lab mirror: the hub machine (the Mac by default) keeps a permanent
	// copy of every peer's lab store, so records outlive cluster jobs.
	if labMirrorEnabled() {
		go labMirrorLoop(ctx)
	}
	// Automation is a Mac-hub responsibility, but it is independent of whether
	// the optional offline mirror was disabled with UT_LAB_MIRROR=0.
	if runtime.GOOS == "darwin" {
		go labUnattendedLoop(ctx)
	}

	srv := &http.Server{Handler: mux}
	// Disable HTTP/2: over the tsnet TLS listener the server would otherwise
	// negotiate h2, whose flow control BUFFERS flushed chunks — so a live feed
	// (/stream behind `ut tail`) arrives in batches instead of line-by-line. An
	// empty non-nil TLSNextProto turns h2 off; everything here is h1-friendly
	// (WebSocket already needs an h1 upgrade).
	srv.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	// Optional ADDITIONAL listener (e.g. the host's tailnet IP) so remote tailnet
	// clients — the Android app — can reach an otherwise loopback-bound broker,
	// WITHOUT exposing it on the LAN (bind a specific tailnet IP, never 0.0.0.0)
	// and WITHOUT disturbing the primary listener the local app/forward-hub use.
	// Best-effort: a bind failure here (e.g. Tailscale not up yet) is logged, not fatal.
	if *extraListen != "" && *extraListen != *listen {
		if l2, e := net.Listen("tcp", *extraListen); e == nil {
			log.Printf("also serving on http://%s", *extraListen)
			go func() { _ = srv.Serve(l2) }()
		} else {
			log.Printf("warn: extra-listen %s failed (primary listener unaffected): %v", *extraListen, e)
		}
	}
	// ALWAYS serve on loopback too, so a CLI/agent running ON THIS HOST can reach
	// its local broker (and relay out through the mesh). In tsnet mode the primary
	// listener is the tailnet interface only — without this, the `ut` mesh client
	// on a cluster compute node couldn't talk to its own broker.
	if loopback := "127.0.0.1:" + portOf(*listen); loopback != *listen && loopback != *extraListen {
		if l3, e := net.Listen("tcp", loopback); e == nil {
			log.Printf("also serving on http://%s (local mesh client)", loopback)
			go func() { _ = srv.Serve(l3) }()
		} else {
			log.Printf("warn: loopback listener %s failed: %v", loopback, e)
		}
	}
	log.Printf("universal_tmux broker → %s  (tmux -L %s, fallback session %q)", where, *tmuxSock, *session)
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// portOf returns the port of a host:port (or the string itself if it has no host).
func portOf(hostport string) string {
	if _, p, err := net.SplitHostPort(hostport); err == nil && p != "" {
		return p
	}
	return strings.TrimPrefix(hostport, ":")
}

// fsResult writes {"ok":true} or a 400 with {"error":...} for an /fs mutation.
func prErrorJSON(e *gitsvc.PRError) []byte {
	b, _ := json.Marshal(e)
	return b
}

func prActionResult(w http.ResponseWriter, e *gitsvc.PRError) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json")
	if e != nil {
		_, _ = w.Write(prErrorJSON(e))
		return
	}
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func fsResult(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json")
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

// listener returns a local TCP listener, or a tailnet (tsnet) listener when
// tsHost is set — the rootless, no-TUN inbound path for owned/cluster nodes.
// The returned *tsnet.Server (nil in local mode) lets the mesh dial peer
// brokers over the tailnet.
func listener(ctx context.Context, listen, tsHost, tsDir string) (net.Listener, string, *tsnet.Server, error) {
	if tsHost == "" {
		ln, err := net.Listen("tcp", listen)
		return ln, "http://" + listen, nil, err
	}
	port := "8722"
	if _, p, err := net.SplitHostPort(listen); err == nil && p != "" {
		port = p
	}
	s := &tsnet.Server{Hostname: tsHost, Logf: log.Printf}
	if tsDir != "" {
		s.Dir = tsDir
	}
	if k := os.Getenv("TS_AUTHKEY"); k != "" {
		s.AuthKey = k
	}
	if err := s.Start(); err != nil {
		return nil, "", nil, err
	}
	status, err := s.Up(ctx)
	if err != nil {
		return nil, "", nil, err
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, "", nil, err
	}
	ln, err := s.Listen("tcp", ":"+port)
	if err != nil {
		return nil, "", nil, err
	}
	// Real *.ts.net certificate (requires Tailscale HTTPS enabled on the tailnet).
	// A valid chain is what macOS ATS demands for a remote host — no client hacks.
	ln = tls.NewListener(ln, &tls.Config{GetCertificate: lc.GetCertificate})
	name := tsHost
	if status != nil && status.Self != nil && status.Self.DNSName != "" {
		name = strings.TrimSuffix(status.Self.DNSName, ".")
	}
	return ln, "https://" + name + ":" + port + "  (tailnet, TLS)", s, nil
}
