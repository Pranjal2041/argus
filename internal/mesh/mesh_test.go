package mesh

import (
	"context"
	"errors"
	"net"
	"reflect"
	"testing"
)

func TestProbeAttemptsUseIPForRoutingButKeepTLSIdentity(t *testing.T) {
	c := candidate{
		dns: "ut-babel-p9-16.example.ts.net",
		ips: []string{"100.71.56.4", "fd7a:115c:a1e0::1"},
	}
	want := []probeAttempt{
		{host: c.dns, scheme: "https", dialHost: "100.71.56.4", tlsServerName: c.dns},
		{host: "100.71.56.4", scheme: "http"},
		{host: c.dns, scheme: "https", dialHost: "fd7a:115c:a1e0::1", tlsServerName: c.dns},
		{host: "fd7a:115c:a1e0::1", scheme: "http"},
	}
	if got := probeAttempts(c); !reflect.DeepEqual(got, want) {
		t.Fatalf("probeAttempts() = %#v, want %#v", got, want)
	}
	for _, a := range probeAttempts(c) {
		if a.scheme == "http" && a.host == c.dns {
			t.Fatalf("plain HTTP must not target a known peer DNS name: %#v", a)
		}
	}
}

func TestProbeAttemptsRetainLegacyFallbackWithoutIPs(t *testing.T) {
	dns := "old-peer.example.ts.net"
	want := []probeAttempt{
		{host: dns, scheme: "https"},
		{host: dns, scheme: "http"},
	}
	if got := probeAttempts(candidate{dns: dns}); !reflect.DeepEqual(got, want) {
		t.Fatalf("probeAttempts() = %#v, want %#v", got, want)
	}
}

func TestPeerTransportOverridesOnlySocketDestination(t *testing.T) {
	var dialed string
	dial := func(_ context.Context, _, address string) (net.Conn, error) {
		dialed = address
		return nil, errors.New("stop after observing address")
	}
	tr := peerTransport(dial, "100.71.56.4", "ut-babel-p9-16.example.ts.net")
	_, _ = tr.DialContext(context.Background(), "tcp", "ut-babel-p9-16.example.ts.net:8722")

	if dialed != "100.71.56.4:8722" {
		t.Fatalf("dialed %q, want authoritative peer IP", dialed)
	}
	if tr.TLSClientConfig == nil || tr.TLSClientConfig.ServerName != "ut-babel-p9-16.example.ts.net" {
		t.Fatalf("TLS server name = %#v", tr.TLSClientConfig)
	}
}
