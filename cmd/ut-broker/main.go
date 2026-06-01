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
	"universal-tmux/internal/portfwd"
	webassets "universal-tmux/web"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:8722", "local host:port (the port is reused on the tailnet when --tsnet-host is set)")
	session := flag.String("session", "ut-demo", "default session to warm + attach when none is requested")
	tmuxSock := flag.String("tmux-socket", "ut", "dedicated tmux server socket (-L); isolates our sessions from any other tmux")
	webDir := flag.String("web", "", "serve web assets from this dir instead of the embedded copy (dev)")
	tsHost := flag.String("tsnet-host", "", "join the tailnet under this hostname and listen there instead of locally")
	tsDir := flag.String("tsnet-dir", "", "tsnet state dir (default: tsnet's own under $HOME)")
	name := flag.String("name", "", "display name reported to clients via /whoami (default: hostname)")
	shell := flag.String("shell", "", "shell to host for new sessions (Windows ConPTY only; default cmd.exe)")
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
	mux.HandleFunc("/control", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		q := r.URL.Query()
		var err error
		switch q.Get("action") {
		case "create":
			err = mgr.Create(q.Get("session"), q.Get("dir"))
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

	ln, where, err := listener(ctx, *listen, *tsHost, *tsDir)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	srv := &http.Server{Handler: mux}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	log.Printf("universal_tmux broker → %s  (tmux -L %s, default session %q)", where, *tmuxSock, *session)
	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
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
func listener(ctx context.Context, listen, tsHost, tsDir string) (net.Listener, string, error) {
	if tsHost == "" {
		ln, err := net.Listen("tcp", listen)
		return ln, "http://" + listen, err
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
		return nil, "", err
	}
	status, err := s.Up(ctx)
	if err != nil {
		return nil, "", err
	}
	lc, err := s.LocalClient()
	if err != nil {
		return nil, "", err
	}
	ln, err := s.Listen("tcp", ":"+port)
	if err != nil {
		return nil, "", err
	}
	// Real *.ts.net certificate (requires Tailscale HTTPS enabled on the tailnet).
	// A valid chain is what macOS ATS demands for a remote host — no client hacks.
	ln = tls.NewListener(ln, &tls.Config{GetCertificate: lc.GetCertificate})
	name := tsHost
	if status != nil && status.Self != nil && status.Self.DNSName != "" {
		name = strings.TrimSuffix(status.Self.DNSName, ".")
	}
	return ln, "https://" + name + ":" + port + "  (tailnet, TLS)", nil
}
