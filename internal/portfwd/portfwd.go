// Package portfwd lets a tailnet client reach a TCP port on the broker's OWN
// host (localhost), and lists the host's listening ports. The transport is the
// broker's existing tsnet/HTTP listener (same as /ws): a WebSocket carrying raw
// bytes, wrapped as a net.Conn and io.Copy'd to localhost:port. localhost-only
// target so the broker never becomes an open proxy.
package portfwd

import (
	"context"
	"io"
	"net"
	"strconv"
	"time"

	"github.com/coder/websocket"
)

// PortInfo is one listening TCP port on the broker's host.
type PortInfo struct {
	Port    int    `json:"port"`
	Address string `json:"address"`
	Process string `json:"process"`
	PID     int    `json:"pid"`
	Web     bool   `json:"web,omitempty"` // set by ProbeWeb: the port answered an HTTP request
}

// ListeningPorts returns the host's listening TCP ports (platform-specific).
func ListeningPorts() []PortInfo { return listeningPorts() }

// ProbeWeb marks which ports actually speak HTTP, by opening each loopback port
// and checking whether it answers "HTTP/…". This is the deterministic signal for
// "is this a browsable web service" (vs guessing from the process name) — a plain
// listening port might be a database, an app's IPC socket, etc. Concurrent with a
// short per-port timeout so scanning ~dozens of ports stays sub-second.
func ProbeWeb(ports []PortInfo) []PortInfo {
	type res struct {
		i   int
		web bool
	}
	ch := make(chan res, len(ports))
	sem := make(chan struct{}, 24) // cap concurrency
	for i, p := range ports {
		go func(i, port int) {
			sem <- struct{}{}
			defer func() { <-sem }()
			ch <- res{i, speaksHTTP(port)}
		}(i, p.Port)
	}
	for range ports {
		r := <-ch
		ports[r.i].Web = r.web
	}
	return ports
}

// speaksHTTP opens 127.0.0.1:port, sends a minimal GET, and reports whether the
// reply begins with "HTTP/". Loopback only; ~400ms budget.
func speaksHTTP(port int) bool {
	d := net.Dialer{Timeout: 350 * time.Millisecond}
	conn, err := d.Dial("tcp", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		conn, err = d.Dial("tcp", "[::1]:"+strconv.Itoa(port))
		if err != nil {
			return false
		}
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(400 * time.Millisecond))
	_, _ = conn.Write([]byte("GET / HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	buf := make([]byte, 16)
	n, _ := io.ReadFull(conn, buf)
	return n >= 5 && string(buf[:5]) == "HTTP/"
}

// ValidPort reports whether s is a usable TCP port number.
func ValidPort(s string) bool {
	n, err := strconv.Atoi(s)
	return err == nil && n > 0 && n < 65536
}

// dialLoopback connects to a port on THIS host's loopback, trying IPv4 then IPv6:
// a dashboard may bind only `::1` (e.g. when its `localhost` resolved to IPv6), and
// a plain 127.0.0.1 dial would miss it. Stays loopback-only so the broker never
// becomes an open proxy. (A service bound to a non-loopback interface like the
// node's internal IP is intentionally not reachable.)
func dialLoopback(port string) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", port), 10*time.Second)
	if err == nil {
		return c, nil
	}
	if c6, err6 := net.DialTimeout("tcp", net.JoinHostPort("::1", port), 10*time.Second); err6 == nil {
		return c6, nil
	}
	return nil, err
}

// Forward bridges an accepted WebSocket to the loopback port on this host: bytes
// flow both ways until either side closes. The WS is wrapped as a net.Conn so
// io.Copy handles the byte stream and half-close cleanly.
func Forward(ctx context.Context, c *websocket.Conn, port string) {
	target, err := dialLoopback(port)
	if err != nil {
		_ = c.Close(websocket.StatusInternalError, "dial failed")
		return
	}
	defer target.Close()

	nc := websocket.NetConn(ctx, c, websocket.MessageBinary)
	defer nc.Close()

	// Bidirectional copy. When either direction ends, the deferred closes above
	// unblock the other goroutine; the buffered channel keeps it from leaking.
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(target, nc); done <- struct{}{} }()
	go func() { _, _ = io.Copy(nc, target); done <- struct{}{} }()
	<-done
}
