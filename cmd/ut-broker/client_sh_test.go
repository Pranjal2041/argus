package main

import (
	"net"
	"net/http"
	"net/url"
	"strconv"
	"testing"
)

func TestCmdShCreationKind(t *testing.T) {
	requests := make(chan url.Values, 2)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/control", func(w http.ResponseWriter, r *http.Request) {
		requests <- r.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	server := &http.Server{Handler: mux}
	go func() { _ = server.Serve(ln) }()
	t.Cleanup(func() { _ = server.Close() })
	t.Setenv("UT_PORT", strconv.Itoa(ln.Addr().(*net.TCPAddr).Port))

	oldSelf := selfNames
	selfNames = map[string]bool{"test-machine": true}
	t.Cleanup(func() { selfNames = oldSelf })

	if code := cmdSh([]string{"@test-machine", "agent-work"}); code != 0 {
		t.Fatalf("default ut sh exit = %d", code)
	}
	q := <-requests
	if q.Get("action") != "create" || q.Get("kind") != "agent-shell" || q.Get("session") != "agent-work" {
		t.Fatalf("default ut sh query = %v", q)
	}

	if code := cmdSh([]string{"--visible", "@test-machine", "human-work"}); code != 0 {
		t.Fatalf("visible ut sh exit = %d", code)
	}
	q = <-requests
	if q.Get("action") != "create" || q.Get("kind") != "" || q.Get("session") != "human-work" {
		t.Fatalf("visible ut sh query = %v", q)
	}
}

func TestExtractVisibleFlag(t *testing.T) {
	visible, rest, err := extractVisibleFlag([]string{"@host", "shell", "--visible"})
	if err != nil || !visible || len(rest) != 2 || rest[0] != "@host" || rest[1] != "shell" {
		t.Fatalf("extractVisibleFlag = %v, %v, %v", visible, rest, err)
	}
	if _, _, err := extractVisibleFlag([]string{"--visible", "--visible", "@host", "shell"}); err == nil {
		t.Fatal("duplicate --visible was accepted")
	}
	if _, _, err := extractVisibleFlag([]string{"--mystery", "@host", "shell"}); err == nil {
		t.Fatal("unknown option was accepted")
	}
}
