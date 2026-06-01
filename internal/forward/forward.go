// Package forward is the port-hub agent: it binds local TCP ports on THIS host
// and tunnels each connection to a remote broker's /forward endpoint over the
// tailnet, so a remote app's localhost port becomes reachable as a local port
// here (e.g. a web app on remote-host:7000 -> http://localhost:7001 on the Mac).
package forward

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Forward is one active local-port -> remote-broker tunnel. Exported fields are
// what /forwards returns; the listener/cancel are internal.
type Forward struct {
	ID         string `json:"id"`
	BrokerHost string `json:"brokerHost"`
	BrokerName string `json:"brokerName"`
	Scheme     string `json:"scheme"`
	RemotePort int    `json:"remotePort"`
	LocalPort  int    `json:"localPort"`
	Label      string `json:"label"`

	listener net.Listener
	cancel   context.CancelFunc
}

// Manager owns the set of active forwards on this host.
type Manager struct {
	mu    sync.Mutex
	fwds  map[string]*Forward
	httpc *http.Client
}

func NewManager() *Manager {
	return &Manager{
		fwds: make(map[string]*Forward),
		// Dials remote brokers over the host's own network (the Tailscale app
		// routes the tailnet). TLS verification is skipped — the tailnet
		// (WireGuard) is the trust boundary, same as the rest of the broker.
		httpc: &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}},
	}
}

func newID() string {
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Start binds a local port (preferred if free, else the next free one) and
// forwards it to brokerHost:8722/forward?port=remotePort.
func (m *Manager) Start(brokerHost, brokerName, scheme string, remotePort, preferredLocal int, label string) (*Forward, error) {
	ln, localPort, err := listenLocal(preferredLocal)
	if err != nil {
		return nil, err
	}
	if scheme == "" {
		scheme = "https"
	}
	ctx, cancel := context.WithCancel(context.Background())
	f := &Forward{
		ID: newID(), BrokerHost: brokerHost, BrokerName: brokerName, Scheme: scheme,
		RemotePort: remotePort, LocalPort: localPort, Label: label, listener: ln, cancel: cancel,
	}
	m.mu.Lock()
	m.fwds[f.ID] = f
	m.mu.Unlock()
	go m.accept(ctx, f)
	return f, nil
}

// listenLocal binds 127.0.0.1:preferred, walking forward to the next free port
// if it's taken (the 7000->7001 auto-bump).
func listenLocal(preferred int) (net.Listener, int, error) {
	if preferred <= 0 || preferred >= 65536 {
		preferred = 7000
	}
	var firstErr error
	for p := preferred; p < preferred+50 && p < 65536; p++ {
		ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(p)))
		if err == nil {
			return ln, p, nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return nil, 0, firstErr
}

func (m *Manager) accept(ctx context.Context, f *Forward) {
	for {
		conn, err := f.listener.Accept()
		if err != nil {
			return // listener closed (Stop)
		}
		go m.handle(ctx, f, conn)
	}
}

func (m *Manager) handle(ctx context.Context, f *Forward, local net.Conn) {
	defer local.Close()
	wsScheme := "wss"
	if f.Scheme == "http" {
		wsScheme = "ws"
	}
	url := fmt.Sprintf("%s://%s:8722/forward?port=%d", wsScheme, f.BrokerHost, f.RemotePort)
	dctx, dcancel := context.WithTimeout(ctx, 15*time.Second)
	c, _, err := websocket.Dial(dctx, url, &websocket.DialOptions{HTTPClient: m.httpc})
	dcancel()
	if err != nil {
		return
	}
	defer c.CloseNow()
	nc := websocket.NetConn(ctx, c, websocket.MessageBinary)
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(nc, local); done <- struct{}{} }()
	go func() { _, _ = io.Copy(local, nc); done <- struct{}{} }()
	<-done
}

func (m *Manager) Stop(id string) bool {
	m.mu.Lock()
	f := m.fwds[id]
	delete(m.fwds, id)
	m.mu.Unlock()
	if f == nil {
		return false
	}
	f.cancel()
	_ = f.listener.Close()
	return true
}

func (m *Manager) List() []*Forward {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Forward, 0, len(m.fwds))
	for _, f := range m.fwds {
		out = append(out, f)
	}
	return out
}
