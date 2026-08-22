package main

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseBrowserCommands(t *testing.T) {
	method, params, _, err := parseBrowserCommand([]string{"open", "https://example.com", "--visible", "--width", "1280"})
	if err != nil || method != "tabs.open" || params["url"] != "https://example.com" || params["visible"] != true || params["width"] != 1280 {
		t.Fatalf("open = %q %#v %v", method, params, err)
	}

	method, params, _, err = parseBrowserCommand([]string{"click", "abc", "120.5", "44"})
	if err != nil || method != "page.click" || params["native"] != nil || params["x"] != 120.5 || params["y"] != float64(44) {
		t.Fatalf("click = %q %#v %v", method, params, err)
	}

	method, params, _, err = parseBrowserCommand([]string{"type", "abc", "--ref", "e7", "hello", "world"})
	if err != nil || method != "page.type" || params["ref"] != "e7" || params["text"] != "hello world" || params["native"] != nil {
		t.Fatalf("type = %q %#v %v", method, params, err)
	}

	method, params, path, err := parseBrowserCommand([]string{"screenshot", "abc", "--full-page", "-o", "page.png"})
	if err != nil || method != "page.screenshot" || params["full_page"] != true || path != "page.png" {
		t.Fatalf("screenshot = %q %#v %q %v", method, params, path, err)
	}
}

func TestParseBrowserUploadReadsCallingMachineFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "diagram.svg")
	content := []byte(`<svg xmlns="http://www.w3.org/2000/svg"><text>Argus</text></svg>`)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}

	method, params, _, err := parseBrowserCommand([]string{"upload", "abc", "--ref", "e9", path})
	if err != nil || method != "page.upload" || params["tab_id"] != "abc" || params["ref"] != "e9" {
		t.Fatalf("upload = %q %#v %v", method, params, err)
	}
	files, ok := params["files"].([]map[string]any)
	if !ok || len(files) != 1 {
		t.Fatalf("upload files = %#v", params["files"])
	}
	if files[0]["name"] != "diagram.svg" || !strings.HasPrefix(files[0]["mime_type"].(string), "image/svg+xml") {
		t.Fatalf("upload metadata = %#v", files[0])
	}
	decoded, err := base64.StdEncoding.DecodeString(files[0]["data_base64"].(string))
	if err != nil || string(decoded) != string(content) {
		t.Fatalf("upload content = %q, %v", decoded, err)
	}
	if _, leakedPath := files[0]["path"]; leakedPath {
		t.Fatal("browser RPC must not expose the calling machine's path")
	}
}

func TestParseBrowserUploadRejectsNonFile(t *testing.T) {
	if _, _, _, err := parseBrowserCommand([]string{"upload", "abc", t.TempDir()}); err == nil {
		t.Fatal("uploading a directory unexpectedly succeeded")
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

func TestParseBrowserCredentialCommands(t *testing.T) {
	method, params, _, err := parseBrowserCommand([]string{
		"credentials", "request", "Research Gmail", "--tab", "abc",
	})
	if err != nil || method != "credentials.request" || params["credential"] != "Research Gmail" || params["tab_id"] != "abc" {
		t.Fatalf("credential request = %q %#v %v", method, params, err)
	}

	method, params, _, err = parseBrowserCommand([]string{
		"credentials", "fill", "abc", "Research Gmail", "--grant", "opaque-token",
		"--username-ref", "e7", "--password-at", "120", "240",
	})
	if err != nil || method != "credentials.fill" || params["grant"] != "opaque-token" {
		t.Fatalf("credential fill = %q %#v %v", method, params, err)
	}
	targets, ok := params["targets"].(map[string]any)
	if !ok || targets["username"].(map[string]any)["ref"] != "e7" ||
		targets["password"].(map[string]any)["x"] != float64(120) {
		t.Fatalf("credential targets = %#v", params["targets"])
	}
}

func TestParseBrowserCredentialFillRequiresGrantAndTarget(t *testing.T) {
	for _, args := range [][]string{
		{"credentials", "fill", "abc", "Research Gmail", "--password-ref", "e8"},
		{"credentials", "fill", "abc", "Research Gmail", "--grant", "token"},
		{"credentials", "fill", "abc", "Research Gmail", "--grant", "token", "--password-at", "bad", "2"},
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
