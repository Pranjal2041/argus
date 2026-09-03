package mesh

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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

func TestPeerJSONCarriesStableIdentityAndRoutingMetadata(t *testing.T) {
	peer := Peer{
		Name: "cluster", Host: "ut-cluster.example.ts.net", Scheme: "https", Os: "linux",
		TailnetName: "ut-cluster.example.ts.net", Address: "100.71.56.4",
		BrokerHost: "cluster.internal", Socket: "ut",
	}
	b, err := json.Marshal(peer)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{
		"tailnetName": "ut-cluster.example.ts.net",
		"address":     "100.71.56.4",
		"brokerHost":  "cluster.internal",
		"socket":      "ut",
	} {
		if got[key] != want {
			t.Fatalf("%s = %#v, want %q; JSON=%s", key, got[key], want, b)
		}
	}
}

func TestResolveAcceptsEveryAdvertisedIdentityAcrossTransports(t *testing.T) {
	peers := []Peer{
		{
			Name: "pranjala-win", Host: "100.69.229.6", Scheme: "http", Os: "windows",
			TailnetName: "pranjala-win.example.ts.net", BrokerHost: "DESKTOP-EFJI6J4", Socket: "ut",
		},
		{
			Name: "babel-t5-24", Host: "ut-babel-t5-24.example.ts.net", Scheme: "https", Os: "linux",
			TailnetName: "ut-babel-t5-24.example.ts.net", Address: "100.122.79.99",
			BrokerHost: "babel-t5-24", Socket: "ut",
		},
	}
	m := &Mesh{
		self: "local", peerTTL: time.Minute, peerTimeout: time.Second,
		discoverPeers: func(context.Context) []Peer { return peers },
	}

	tests := []struct {
		query string
		want  string
	}{
		// Native HTTP: stable tailnet identity and transport address differ.
		{"pranjala-win.example.ts.net", "pranjala-win"},
		{"100.69.229.6", "pranjala-win"},
		{"DESKTOP-EFJI6J4", "pranjala-win"},
		// TLS: DNS identity remains the URL host while the authoritative socket
		// address is carried separately.
		{"ut-babel-t5-24.example.ts.net", "babel-t5-24"},
		{"100.122.79.99", "babel-t5-24"},
		{"babel-t5-24", "babel-t5-24"},
	}
	for _, test := range tests {
		t.Run(test.query, func(t *testing.T) {
			got, ok := m.Resolve(context.Background(), test.query)
			if !ok || got.Name != test.want {
				t.Fatalf("Resolve(%q) = %#v, %v; want peer %q", test.query, got, ok, test.want)
			}
		})
	}
}

func TestPeersCoalescesConcurrentCallersAndCachesResult(t *testing.T) {
	var scans atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	m := &Mesh{
		peerTTL:     time.Minute,
		peerTimeout: time.Second,
		discoverPeers: func(ctx context.Context) []Peer {
			if scans.Add(1) == 1 {
				close(started)
			}
			select {
			case <-release:
				return []Peer{{Name: "shared"}}
			case <-ctx.Done():
				return nil
			}
		},
	}

	const callers = 24
	results := make([][]Peer, callers)
	var wg sync.WaitGroup
	wg.Add(callers)
	for i := range results {
		i := i
		go func() {
			defer wg.Done()
			results[i] = m.Peers(context.Background())
		}()
	}
	<-started
	time.Sleep(20 * time.Millisecond)
	if got := scans.Load(); got != 1 {
		t.Fatalf("physical scans while one is in flight = %d, want 1", got)
	}
	close(release)
	wg.Wait()

	for i, got := range results {
		if len(got) != 1 || got[0].Name != "shared" {
			t.Fatalf("caller %d got %#v", i, got)
		}
	}
	if got := m.Peers(context.Background()); len(got) != 1 || scans.Load() != 1 {
		t.Fatalf("cached call got %#v after %d scans", got, scans.Load())
	}
}

func TestPeersCallerCancellationDoesNotForkPhysicalScan(t *testing.T) {
	var scans atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	m := &Mesh{
		peerTTL:     time.Minute,
		peerTimeout: time.Second,
		discoverPeers: func(ctx context.Context) []Peer {
			if scans.Add(1) == 1 {
				close(started)
			}
			select {
			case <-release:
				return []Peer{{Name: "eventual"}}
			case <-ctx.Done():
				return nil
			}
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if got := m.Peers(ctx); got != nil {
		t.Fatalf("cancelled caller got %#v, want nil", got)
	}
	<-started

	result := make(chan []Peer, 1)
	go func() { result <- m.Peers(context.Background()) }()
	time.Sleep(20 * time.Millisecond)
	if got := scans.Load(); got != 1 {
		t.Fatalf("second caller forked scan; physical scans = %d", got)
	}
	close(release)
	if got := <-result; len(got) != 1 || got[0].Name != "eventual" {
		t.Fatalf("second caller got %#v", got)
	}
}

func TestPeersPhysicalScanHasIndependentHardDeadline(t *testing.T) {
	var scans atomic.Int32
	m := &Mesh{
		peerTTL:     time.Nanosecond,
		peerTimeout: 25 * time.Millisecond,
		discoverPeers: func(ctx context.Context) []Peer {
			scans.Add(1)
			<-ctx.Done()
			return nil
		},
	}

	started := time.Now()
	if got := m.Peers(context.Background()); got != nil {
		t.Fatalf("timed-out scan got %#v", got)
	}
	if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
		t.Fatalf("physical scan outlived its hard deadline: %v", elapsed)
	}
	if got := scans.Load(); got != 1 {
		t.Fatalf("physical scans = %d, want 1", got)
	}
}
