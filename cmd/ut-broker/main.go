// Command ut-broker is the per-host universal_tmux broker. It owns one tmux
// server (a dedicated `-L` socket), lists its sessions, and serves each to
// xterm.js / native clients over a binary WebSocket — on a local TCP port
// (dev) or, with --tsnet-host, directly on the tailnet via embedded tsnet.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"

	"github.com/coder/websocket"
	"tailscale.com/tsnet"

	"universal-tmux/internal/broker"
	"universal-tmux/internal/forward"
	"universal-tmux/internal/fsvc"
	"universal-tmux/internal/jupyter"
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
	session := flag.String("session", "ut-demo", "default session to warm + attach when none is requested")
	tmuxSock := flag.String("tmux-socket", "ut", "dedicated tmux server socket (-L); isolates our sessions from any other tmux")
	webDir := flag.String("web", "", "serve web assets from this dir instead of the embedded copy (dev)")
	tsHost := flag.String("tsnet-host", "", "join the tailnet under this hostname and listen there instead of locally")
	tsDir := flag.String("tsnet-dir", "", "tsnet state dir (default: tsnet's own under $HOME)")
	name := flag.String("name", "", "display name reported to clients via /whoami (default: hostname)")
	shell := flag.String("shell", "", "shell to host for new sessions (Windows ConPTY only; default cmd.exe)")
	extraListen := flag.String("extra-listen", "", "additional best-effort host:port to ALSO serve the same mux on (e.g. this host's tailnet IP, so remote tailnet clients can reach a loopback-bound broker). A bind failure here is logged and ignored — it never stops the primary --listen.")
	flag.Parse()

	// Display name the client shows for this broker's device.
	displayName := *name
	if displayName == "" {
		if h, err := os.Hostname(); err == nil {
			displayName = h
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	mgr := broker.NewManager(ctx, makeProvider(*tmuxSock, *shell)) // makeProvider: tmux (Unix) or ConPTY (Windows)
	fwdMgr := forward.NewManager()                                 // port-hub agent (used when this broker is the local agent)
	jupyterMgr := jupyter.NewManager()                             // ensures a JupyterLab on this host for the notebook feature
	mgr.SetHistoryLimit(100000) // large scrollback for new sessions
	if *session != "" {
		if err := mgr.Ensure(*session); err != nil {
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
			"socket":  *tmuxSock,
		})
	})
	mux.HandleFunc("/sessions", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(map[string]any{"sessions": mgr.Sessions()})
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
			idleSec := sess.DefaultReapIdleSec // idle leash; ?idle=SEC overrides (0 = never reap)
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
		_ = json.NewEncoder(w).Encode(map[string]any{"ports": portfwd.ListeningPorts()})
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
	// File service: browse this host's filesystem (as the broker's user) and
	// stream file contents. /fs/home → starting points, /fs/list → a directory,
	// /fs/read → a file (Range + content-type, so large files and media stream).
	mux.HandleFunc("/fs/home", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		_ = json.NewEncoder(w).Encode(fsvc.Home())
	})
	mux.HandleFunc("/fs/list", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		res, err := fsvc.List(r.URL.Query().Get("path"))
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
	log.Printf("universal_tmux broker → %s  (tmux -L %s, default session %q)", where, *tmuxSock, *session)
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
