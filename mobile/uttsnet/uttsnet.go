// Package uttsnet is the gomobile-bound tsnet core for the Android client. The
// phone joins the tailnet as its OWN node (no Tailscale app required), enumerates
// peers to auto-discover brokers, and carries each session's WebSocket over tsnet.
//
// On Android the stdlib's netlink-based interface enumeration is sandboxed
// ("netlinkrib: permission denied"), so we register a netlink-free getter backed
// by github.com/wlynxg/anet BEFORE starting tsnet. Build with
// -ldflags=-checklinkname=0 (anet uses go:linkname into the net package).
package uttsnet

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/wlynxg/anet"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
)

// Output receives events from a session; implemented on the Kotlin side.
type Output interface {
	OnOutput(b []byte)
	OnClosed(reason string)
}

var registerOnce sync.Once

func registerInterfaceGetter() {
	registerOnce.Do(func() {
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			ifs, err := anet.Interfaces()
			if err != nil {
				return nil, err
			}
			out := make([]netmon.Interface, 0, len(ifs))
			for i := range ifs {
				addrs, _ := anet.InterfaceAddrsByInterface(&ifs[i])
				out = append(out, netmon.Interface{Interface: &ifs[i], AltAddrs: addrs})
			}
			return out, nil
		})
	})
}

// Engine is an embedded tsnet node.
type Engine struct {
	stateDir string
	hostname string
	authKey  string

	srv     *tsnet.Server
	probeHC *http.Client
	wsHC    *http.Client
}

// New creates an engine. androidApi is Build.VERSION.SDK_INT (lets the
// netlink-free interface enumeration pick the right path for the OS version).
func New(stateDir, hostname, authKey string, androidApi int) *Engine {
	if androidApi > 0 {
		anet.SetAndroidVersion(uint(androidApi))
	}
	return &Engine{stateDir: stateDir, hostname: hostname, authKey: authKey}
}

// Start brings the node up and blocks until it has joined the tailnet (or errors).
func (e *Engine) Start() error {
	registerInterfaceGetter()
	// tailscale's logpolicy looks for a writable dir to persist its log state; on
	// Android the default candidates aren't writable (panic: "no safe place found
	// to store log state"), so point it (and the config dir) at our state dir.
	_ = os.MkdirAll(e.stateDir, 0o700)
	os.Setenv("TS_LOGS_DIR", e.stateDir)
	if os.Getenv("XDG_CONFIG_HOME") == "" {
		os.Setenv("XDG_CONFIG_HOME", e.stateDir)
	}
	srv := &tsnet.Server{
		Dir:      e.stateDir,
		Hostname: e.hostname,
		AuthKey:  e.authKey,
	}
	if err := srv.Start(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if _, err := srv.Up(ctx); err != nil {
		return err
	}
	e.srv = srv
	tlsCfg := &tls.Config{InsecureSkipVerify: true} // already inside the encrypted WireGuard tunnel
	e.probeHC = &http.Client{Timeout: 6 * time.Second, Transport: &http.Transport{DialContext: srv.Dial, TLSClientConfig: tlsCfg}}
	e.wsHC = &http.Client{Transport: &http.Transport{DialContext: srv.Dial, TLSClientConfig: tlsCfg}}
	return nil
}

type brokerJSON struct {
	Host   string `json:"host"`
	Scheme string `json:"scheme"`
	Name   string `json:"name"`
}

// Discover enumerates online tailnet peers, probes :8722/whoami on each, and
// returns a JSON array of brokers ([{"host","scheme","name"}, ...]).
func (e *Engine) Discover() string {
	if e.srv == nil {
		return "[]"
	}
	lc, err := e.srv.LocalClient()
	if err != nil {
		return "[]"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	st, err := lc.Status(ctx)
	if err != nil {
		return "[]"
	}
	var (
		mu    sync.Mutex
		wg    sync.WaitGroup
		found []brokerJSON
	)
	for _, p := range st.Peer {
		if !p.Online {
			continue
		}
		dns := strings.TrimSuffix(p.DNSName, ".")
		if dns == "" {
			continue
		}
		wg.Add(1)
		go func(dns string) {
			defer wg.Done()
			if b, ok := e.probe(dns); ok {
				mu.Lock()
				found = append(found, b)
				mu.Unlock()
			}
		}(dns)
	}
	wg.Wait()
	out, _ := json.Marshal(found)
	return string(out)
}

func (e *Engine) probe(dns string) (brokerJSON, bool) {
	for _, scheme := range []string{"https", "http"} {
		req, err := http.NewRequest("GET", scheme+"://"+dns+":8722/whoami", nil)
		if err != nil {
			continue
		}
		resp, err := e.probeHC.Do(req)
		if err != nil {
			continue
		}
		var v struct {
			Service string `json:"service"`
			Name    string `json:"name"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&v)
		resp.Body.Close()
		if v.Service == "universal-tmux-broker" {
			name := v.Name
			if name == "" {
				name = dns
			}
			return brokerJSON{Host: dns, Scheme: scheme, Name: name}, true
		}
	}
	return brokerJSON{}, false
}

// Session is a live binary WebSocket to a broker session, carried over tsnet.
type Session struct {
	c      *websocket.Conn
	cancel context.CancelFunc
}

// Dial opens a session's WebSocket; output frames are delivered to out.
func (e *Engine) Dial(host, scheme, session string, out Output) (*Session, error) {
	wsScheme := "wss"
	if scheme == "http" {
		wsScheme = "ws"
	}
	u := wsScheme + "://" + host + ":8722/ws?session=" + url.QueryEscape(session)
	ctx, cancel := context.WithCancel(context.Background())
	dialCtx, dialCancel := context.WithTimeout(ctx, 20*time.Second)
	defer dialCancel()
	c, _, err := websocket.Dial(dialCtx, u, &websocket.DialOptions{HTTPClient: e.wsHC})
	if err != nil {
		cancel()
		return nil, err
	}
	c.SetReadLimit(-1)
	s := &Session{c: c, cancel: cancel}
	go func() {
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				out.OnClosed(err.Error())
				return
			}
			out.OnOutput(data)
		}
	}()
	return s, nil
}

// Forward is a local-port -> remote-broker tunnel running ON THE PHONE: it binds
// 127.0.0.1:LocalPort and pipes each connection to the broker's /forward over
// tsnet, so a remote app (e.g. remote-host:7000) is reachable as http://localhost:N
// from the phone's browser.
type Forward struct {
	localPort int
	ln        net.Listener
	cancel    context.CancelFunc
}

func (f *Forward) LocalPort() int { return f.localPort }
func (f *Forward) Stop() {
	if f.cancel != nil {
		f.cancel()
	}
	if f.ln != nil {
		_ = f.ln.Close()
	}
}

// StartForward binds 127.0.0.1:preferred (walking up to +50 if busy) and tunnels
// every accepted connection to wss://host:8722/forward?port=remotePort over tsnet.
func (e *Engine) StartForward(host, scheme string, remotePort, preferred int) (*Forward, error) {
	ln, localPort, err := listenLocal(preferred)
	if err != nil {
		return nil, err
	}
	wsScheme := "wss"
	if scheme == "http" {
		wsScheme = "ws"
	}
	target := wsScheme + "://" + host + ":8722/forward?port=" + strconv.Itoa(remotePort)
	ctx, cancel := context.WithCancel(context.Background())
	f := &Forward{localPort: localPort, ln: ln, cancel: cancel}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return // listener closed (Stop)
			}
			go e.tunnel(ctx, target, conn)
		}
	}()
	return f, nil
}

func (e *Engine) tunnel(ctx context.Context, target string, local net.Conn) {
	defer local.Close()
	dctx, dcancel := context.WithTimeout(ctx, 15*time.Second)
	c, _, err := websocket.Dial(dctx, target, &websocket.DialOptions{HTTPClient: e.wsHC})
	dcancel()
	if err != nil {
		return
	}
	defer c.CloseNow()
	c.SetReadLimit(-1)
	nc := websocket.NetConn(ctx, c, websocket.MessageBinary)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(nc, local); done <- struct{}{} }()
	go func() { _, _ = io.Copy(local, nc); done <- struct{}{} }()
	<-done
}

func listenLocal(preferred int) (net.Listener, int, error) {
	if preferred <= 0 || preferred >= 65536 {
		preferred = 7000
	}
	var firstErr error
	for p := preferred; p < preferred+50 && p < 65536; p++ {
		ln, err := net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(p))
		if err == nil {
			return ln, p, nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return nil, 0, firstErr
}

// Send writes a binary frame to the session.
func (s *Session) Send(b []byte) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = s.c.Write(ctx, websocket.MessageBinary, b)
}

// Close ends the session.
func (s *Session) Close() {
	s.cancel()
	_ = s.c.Close(websocket.StatusNormalClosure, "")
}
