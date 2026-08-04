package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"testing"
)

func TestParseForwardStart(t *testing.T) {
	machine, remote, local, label, err := parseForwardStart([]string{
		"@babel-p9-16", "5800", "--local", "15800", "--label=gym dashboard",
	})
	if err != nil {
		t.Fatal(err)
	}
	if machine != "babel-p9-16" || remote != 5800 || local != 15800 || label != "gym dashboard" {
		t.Fatalf("parsed = %q, %d, %d, %q", machine, remote, local, label)
	}

	machine, remote, local, label, err = parseForwardStart([]string{"babel-p9-16", "8600"})
	if err != nil {
		t.Fatal(err)
	}
	if machine != "babel-p9-16" || remote != 8600 || local != 8600 || label != "" {
		t.Fatalf("defaults = %q, %d, %d, %q", machine, remote, local, label)
	}

	for _, args := range [][]string{
		{"@host"},
		{"@host", "0"},
		{"@host", "65536"},
		{"@host", "abc"},
		{"@host", "5800", "--local", "0"},
		{"@host", "5800", "--mystery"},
	} {
		if _, _, _, _, err := parseForwardStart(args); err == nil {
			t.Fatalf("parseForwardStart(%q) unexpectedly succeeded", args)
		}
	}
}

func TestCmdForwardLifecycle(t *testing.T) {
	requests := make(chan struct {
		method string
		query  url.Values
	}, 3)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/forwards", func(w http.ResponseWriter, r *http.Request) {
		requests <- struct {
			method string
			query  url.Values
		}{r.Method, r.URL.Query()}
		w.Header().Set("Content-Type", "application/json")
		switch r.Method {
		case http.MethodPost:
			_ = json.NewEncoder(w).Encode(cliForward{
				ID: "a1b2c3d4", BrokerHost: "ut-babel-p9-16.example.ts.net",
				BrokerName: "babel-p9-16", RemotePort: 5800, LocalPort: 15800, Label: "gym",
			})
		case http.MethodDelete:
			_, _ = w.Write([]byte(`{"ok":true}`))
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"forwards": []cliForward{{
				ID: "a1b2c3d4", BrokerHost: "ut-babel-p9-16.example.ts.net",
				BrokerName: "babel-p9-16", RemotePort: 5800, LocalPort: 15800, Label: "gym",
			}}})
		}
	})
	server := &http.Server{Handler: mux}
	go func() { _ = server.Serve(ln) }()
	t.Cleanup(func() { _ = server.Close() })
	t.Setenv("UT_PORT", strconv.Itoa(ln.Addr().(*net.TCPAddr).Port))

	if code := cmdForward([]string{"@babel-p9-16", "5800", "--local", "15800", "--label", "gym"}); code != 0 {
		t.Fatalf("start exit = %d", code)
	}
	req := <-requests
	if req.method != http.MethodPost || req.query.Get("machine") != "babel-p9-16" ||
		req.query.Get("remotePort") != "5800" || req.query.Get("localPort") != "15800" ||
		req.query.Get("label") != "gym" || req.query.Get("reuse") != "1" {
		t.Fatalf("start request = %s %v", req.method, req.query)
	}

	if code := cmdForward([]string{"ls"}); code != 0 {
		t.Fatalf("list exit = %d", code)
	}
	req = <-requests
	if req.method != http.MethodGet {
		t.Fatalf("list method = %s", req.method)
	}

	if code := cmdForward([]string{"stop", "a1b2c3d4"}); code != 0 {
		t.Fatalf("stop exit = %d", code)
	}
	req = <-requests
	if req.method != http.MethodDelete || req.query.Get("id") != "a1b2c3d4" {
		t.Fatalf("stop request = %s %v", req.method, req.query)
	}
}
