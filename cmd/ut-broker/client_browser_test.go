package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseBrowserCommands(t *testing.T) {
	method, params, _, err := parseBrowserCommand([]string{"open", "https://example.com", "--visible", "--width", "1280"})
	if err != nil || method != "tabs.open" || params["url"] != "https://example.com" || params["visible"] != true || params["width"] != 1280 {
		t.Fatalf("open = %q %#v %v", method, params, err)
	}

	method, params, _, err = parseBrowserCommand([]string{"click", "abc", "120.5", "44"})
	if err != nil || method != "page.click" || params["native"] != true || params["x"] != 120.5 || params["y"] != float64(44) {
		t.Fatalf("click = %q %#v %v", method, params, err)
	}

	method, params, _, err = parseBrowserCommand([]string{"type", "abc", "--ref", "e7", "hello", "world"})
	if err != nil || method != "page.type" || params["ref"] != "e7" || params["text"] != "hello world" || params["native"] != true {
		t.Fatalf("type = %q %#v %v", method, params, err)
	}

	method, params, path, err := parseBrowserCommand([]string{"screenshot", "abc", "--full-page", "-o", "page.png"})
	if err != nil || method != "page.screenshot" || params["full_page"] != true || path != "page.png" {
		t.Fatalf("screenshot = %q %#v %q %v", method, params, path, err)
	}
}

func TestParseBrowserCommandsRejectBadCoordinates(t *testing.T) {
	for _, args := range [][]string{
		{"click", "abc", "x", "1"},
		{"click", "abc", "-1", "2"},
		{"type", "abc", "--at", "1", "bad", "text"},
	} {
		if _, _, _, err := parseBrowserCommand(args); err == nil {
			t.Fatalf("parseBrowserCommand(%q) unexpectedly succeeded", args)
		}
	}
}

func TestBrowserProviderProbeReturnsWithoutWaitingForSlowPeer(t *testing.T) {
	releaseSlow := make(chan struct{})
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		<-releaseSlow
		_, _ = w.Write([]byte(`{"available":false}`))
	}))
	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"available":true,"browser_host":"mac","network_origin":"mac","provider":"Argus","version":1}`))
	}))
	defer slow.Close()
	defer fast.Close()

	started := time.Now()
	host, status, ok := probeBrowserTargets([]browserTarget{
		{host: "slow", url: slow.URL},
		{host: "mac", url: fast.URL},
	})
	close(releaseSlow)
	if !ok || host != "mac" || status.Provider != "Argus" {
		t.Fatalf("probe = host %q status %#v ok %v", host, status, ok)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Fatalf("healthy provider was delayed by slow peer: %s", elapsed)
	}
}
