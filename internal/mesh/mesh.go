// Package mesh turns a broker into a fabric router: it discovers peer brokers
// on the tailnet and relays requests (HTTP and WebSocket) to them, so an agent
// talks ONLY to its local broker and reaches any machine by name. The local
// broker is always reachable (loopback) and is itself a tailnet node — via its
// own tsnet server, or, in local mode, the host's Tailscale — so this works
// even on a cluster compute node whose shell has no tailnet interface.
package mesh

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"tailscale.com/tsnet"
)

const brokerPort = "8722"

// Peer is a reachable broker on the fabric.
type Peer struct {
	Name   string `json:"name"`   // display name from /whoami
	Host   string `json:"host"`   // tailnet host:port-less address to reach it
	Scheme string `json:"scheme"` // http | https
	Os     string `json:"os"`     // runtime.GOOS — lets a client pick the Mac as sync host

	// A TLS broker remains named by Host (HTTP Host, SNI, and certificate), but
	// can be dialed by its authoritative tailnet IP when MagicDNS is stale.
	// These routing details remain process-local and are not serialized.
	dialHost      string
	tlsServerName string
}

// Mesh routes to peer brokers. ts is nil in local mode (use the host network).
type Mesh struct {
	ts     *tsnet.Server
	self   string
	client *http.Client // dials tailnet peers (over tsnet, or host net)
	dial   func(context.Context, string, string) (net.Conn, error)
}

func New(ts *tsnet.Server, selfName string) *Mesh {
	dial := (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	if ts != nil {
		dial = ts.Dial
	}
	transport := peerTransport(dial, "", "")
	return &Mesh{
		ts: ts, self: selfName, dial: dial,
		client: &http.Client{Transport: transport, Timeout: 0},
	}
}

func peerTransport(dial func(context.Context, string, string) (net.Conn, error), dialHost, tlsServerName string) *http.Transport {
	transport := &http.Transport{
		// Force HTTP/1.1: an h2 connection windows/buffers the response body, so a
		// live feed (/stream behind `ut tail`) would arrive in batches instead of
		// as each line is produced. HTTP/1.1 chunked streams promptly.
		ForceAttemptHTTP2: false,
		TLSNextProto:      map[string]func(string, *tls.Conn) http.RoundTripper{},
	}
	transport.DialContext = dial
	if dialHost != "" {
		transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
			_, port, err := net.SplitHostPort(address)
			if err != nil {
				return nil, err
			}
			return dial(ctx, network, net.JoinHostPort(dialHost, port))
		}
	}
	if tlsServerName != "" {
		transport.TLSClientConfig = &tls.Config{ServerName: tlsServerName, MinVersion: tls.VersionTLS12}
	}
	return transport
}

func (m *Mesh) routedClient(dialHost, tlsServerName string) *http.Client {
	if dialHost == "" {
		return m.client
	}
	return &http.Client{Transport: peerTransport(m.dial, dialHost, tlsServerName), Timeout: 0}
}

// candidate is a tailnet device we'll probe for a broker.
type candidate struct {
	dns string   // FQDN (works with the peer's *.ts.net TLS cert)
	ips []string // tailnet IPs (for http brokers bound to their IP)
}

// Peers discovers OTHER brokers on the tailnet (self excluded — the CLI reaches
// the local broker directly). Each online tailnet device is probed for the
// broker /whoami handshake, concurrently with a short timeout.
func (m *Mesh) Peers(ctx context.Context) []Peer {
	cands := m.candidates(ctx)
	out := make([]Peer, 0, len(cands))
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, c := range cands {
		c := c
		wg.Add(1)
		go func() {
			defer wg.Done()
			if p, ok := m.probe(ctx, c); ok {
				mu.Lock()
				out = append(out, p)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return out
}

// matchesSelf reports whether a machine name refers to THIS broker.
func (m *Mesh) matchesSelf(name string) bool {
	s := strings.ToLower(m.self)
	short := s
	if i := strings.Index(s, "."); i > 0 {
		short = s[:i]
	}
	return name == s || name == short || name == strings.TrimPrefix(short, "ut-")
}

// Resolve matches a user-given machine name (e.g. "babel-p9-16",
// "ut-babel-p9-16", or a display name) to a broker — including THIS one (routed
// over loopback), so targeting your own machine always works without discovery.
func (m *Mesh) Resolve(ctx context.Context, name string) (Peer, bool) {
	name = strings.ToLower(strings.TrimSpace(name))
	if m.matchesSelf(name) {
		return Peer{Name: m.self, Host: "127.0.0.1", Scheme: "http"}, true
	}
	peers := m.Peers(ctx)
	// Exact, then prefix, then substring — on host or display name.
	for _, match := range []func(string, string) bool{
		func(a, b string) bool { return a == b },
		strings.HasPrefix,
		strings.Contains,
	} {
		for _, p := range peers {
			host := strings.ToLower(p.Host)
			short := host
			if i := strings.Index(host, "."); i > 0 {
				short = host[:i]
			}
			if match(short, name) || match(strings.TrimPrefix(short, "ut-"), name) ||
				match(strings.ToLower(p.Name), name) || match(host, name) {
				return p, true
			}
		}
	}
	return Peer{}, false
}

// candidates lists online tailnet devices to probe — via this broker's tsnet
// node when present, else the host's `tailscale status --json`.
func (m *Mesh) candidates(ctx context.Context) []candidate {
	if m.ts != nil {
		if lc, err := m.ts.LocalClient(); err == nil {
			if st, err := lc.Status(ctx); err == nil && st != nil {
				var cs []candidate
				for _, p := range st.Peer {
					if p == nil || !p.Online {
						continue
					}
					ips := make([]string, 0, len(p.TailscaleIPs))
					for _, ip := range p.TailscaleIPs {
						ips = append(ips, ip.String())
					}
					cs = append(cs, candidate{dns: strings.TrimSuffix(p.DNSName, "."), ips: ips})
				}
				return cs
			}
		}
	}
	return hostTailscalePeers(ctx)
}

// hostTailscalePeers reads the host Tailscale daemon (local mode, e.g. the Mac).
func hostTailscalePeers(ctx context.Context) []candidate {
	bin := "tailscale"
	for _, p := range []string{"/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"} {
		if _, err := exec.LookPath(p); err == nil {
			bin = p
			break
		}
	}
	out, err := exec.CommandContext(ctx, bin, "status", "--json").Output()
	if err != nil {
		return nil
	}
	var st struct {
		Self *struct {
			DNSName      string
			TailscaleIPs []string
		}
		Peer map[string]struct {
			DNSName      string
			TailscaleIPs []string
			Online       bool
		}
	}
	if json.Unmarshal(out, &st) != nil {
		return nil
	}
	var cs []candidate
	for _, p := range st.Peer {
		if !p.Online {
			continue
		}
		cs = append(cs, candidate{dns: strings.TrimSuffix(p.DNSName, "."), ips: p.TailscaleIPs})
	}
	return cs
}

type probeAttempt struct {
	host, scheme, dialHost, tlsServerName string
}

func probeAttempts(c candidate) []probeAttempt {
	var attempts []probeAttempt
	for _, ip := range c.ips {
		if c.dns != "" {
			// The URL retains the DNS name for Host/SNI and certificate validation;
			// only the socket destination bypasses name resolution.
			attempts = append(attempts, probeAttempt{c.dns, "https", ip, c.dns})
		}
		// Native host brokers (rather than tsnet TLS listeners) use HTTP by design.
		attempts = append(attempts, probeAttempt{ip, "http", "", ""})
	}
	if len(c.ips) == 0 && c.dns != "" {
		// Compatibility for old status payloads that omitted TailscaleIPs.
		attempts = append(attempts,
			probeAttempt{c.dns, "https", "", ""},
			probeAttempt{c.dns, "http", "", ""},
		)
	}
	return attempts
}

// probe confirms a device runs a broker via /whoami. TLS peers are dialed by
// the IP already present in tailnet status while retaining their DNS identity.
// This avoids stale system DNS without weakening certificate verification.
func (m *Mesh) probe(ctx context.Context, c candidate) (Peer, bool) {
	for _, a := range probeAttempts(c) {
		attemptCtx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
		url := a.scheme + "://" + net.JoinHostPort(a.host, brokerPort) + "/whoami"
		req, _ := http.NewRequestWithContext(attemptCtx, http.MethodGet, url, nil)
		client := m.routedClient(a.dialHost, a.tlsServerName)
		resp, err := client.Do(req)
		if err != nil {
			if a.dialHost != "" {
				client.CloseIdleConnections()
			}
			cancel()
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if a.dialHost != "" {
			client.CloseIdleConnections()
		}
		cancel()
		var who struct {
			Service string `json:"service"`
			Name    string `json:"name"`
			Os      string `json:"os"`
		}
		if json.Unmarshal(body, &who) == nil && who.Service == "universal-tmux-broker" {
			name := who.Name
			if name == "" {
				name = a.host
			}
			return Peer{
				Name: name, Host: a.host, Scheme: a.scheme, Os: who.Os,
				dialHost: a.dialHost, tlsServerName: a.tlsServerName,
			}, true
		}
	}
	return Peer{}, false
}

// Proxy forwards /mesh/proxy?host=<name>&path=<p>&... to peer <name>'s broker at
// <p>, carrying the remaining query, the method, body, and (for /ws etc.) the
// WebSocket upgrade. This is the single relay that makes every broker endpoint
// reachable remotely through the local broker.
func (m *Mesh) Proxy(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	// Underscore-prefixed so they never collide with a forwarded endpoint's own
	// params (notably /fs/* which also uses `path`).
	host := q.Get("_mhost")
	path := q.Get("_mpath")
	if host == "" || path == "" {
		http.Error(w, "mesh proxy: _mhost and _mpath required", http.StatusBadRequest)
		return
	}
	peer, ok := m.Resolve(r.Context(), host)
	if !ok {
		http.Error(w, "mesh: no such machine: "+host, http.StatusNotFound)
		return
	}
	q.Del("_mhost")
	q.Del("_mpath")
	target := peer.Scheme + "://" + net.JoinHostPort(peer.Host, brokerPort) + path
	if rest := q.Encode(); rest != "" {
		target += "?" + rest
	}
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		m.proxyWS(w, r, peer, target)
		return
	}
	m.proxyHTTP(w, r, peer, target)
}

func (m *Mesh) proxyHTTP(w http.ResponseWriter, r *http.Request, peer Peer, target string) {
	req, err := http.NewRequestWithContext(r.Context(), r.Method, target, r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	for k, vs := range r.Header {
		if k == "Host" {
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	client := m.routedClient(peer.dialHost, peer.tlsServerName)
	if peer.dialHost != "" {
		defer client.CloseIdleConnections()
	}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "mesh relay: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for k, vs := range resp.Header {
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	// Flush as bytes arrive so a streaming endpoint (/stream behind `ut tail`)
	// relays live rather than buffering to completion.
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 32*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

// proxyWS bridges a client WebSocket to the peer broker's WebSocket (used for
// remote session attach / tail), copying binary frames both ways.
func (m *Mesh) proxyWS(w http.ResponseWriter, r *http.Request, peer Peer, target string) {
	wsTarget := strings.Replace(target, "http", "ws", 1) // http→ws, https→wss
	upstreamClient := m.routedClient(peer.dialHost, peer.tlsServerName)
	if peer.dialHost != "" {
		defer upstreamClient.CloseIdleConnections()
	}
	upstream, _, err := websocket.Dial(r.Context(), wsTarget, &websocket.DialOptions{
		HTTPClient: upstreamClient,
	})
	if err != nil {
		http.Error(w, "mesh ws dial: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer upstream.CloseNow()
	client, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer client.CloseNow()
	// Terminal snapshots can exceed the library's default 32KB read limit, which
	// would silently kill the pump after the first big frame — disable it so the
	// stream keeps flowing.
	upstream.SetReadLimit(-1)
	client.SetReadLimit(-1)
	// NOT r.Context(): the http server cancels it once Accept hijacks the
	// connection, which would kill the pumps right after the first frame. Use a
	// request-independent context torn down when either side closes.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pump := func(src, dst *websocket.Conn) {
		for {
			typ, data, err := src.Read(ctx)
			if err != nil {
				return
			}
			if dst.Write(ctx, typ, data) != nil {
				return
			}
		}
	}
	done := make(chan struct{}, 2)
	go func() { pump(upstream, client); cancel(); done <- struct{}{} }()
	go func() { pump(client, upstream); cancel(); done <- struct{}{} }()
	<-done
}
