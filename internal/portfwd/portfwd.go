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
}

// ListeningPorts returns the host's listening TCP ports (platform-specific).
func ListeningPorts() []PortInfo { return listeningPorts() }

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
