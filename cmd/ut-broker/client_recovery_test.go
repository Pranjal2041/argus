package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"testing"
)

func TestCmdRecoveryTransferRelaysExactManifestBetweenArbitraryPeers(t *testing.T) {
	manifest := []byte(`{"schemaVersion":1,"id":"snapshot"}`)
	type request struct {
		method string
		host   string
		path   string
		query  url.Values
		body   []byte
	}
	requests := make(chan request, 2)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/whoami", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"name": "hub"})
	})
	mux.HandleFunc("/mesh/proxy", func(w http.ResponseWriter, r *http.Request) {
		body := new(bytes.Buffer)
		_, _ = body.ReadFrom(r.Body)
		requests <- request{
			method: r.Method, host: r.URL.Query().Get("_mhost"), path: r.URL.Query().Get("_mpath"),
			query: r.URL.Query(), body: body.Bytes(),
		}
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodGet {
			_, _ = w.Write(manifest)
		} else {
			_, _ = w.Write([]byte(`{"ok":true}`))
		}
	})
	server := &http.Server{Handler: mux}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	t.Setenv("UT_PORT", strconv.Itoa(listener.Addr().(*net.TCPAddr).Port))
	selfNames = nil

	code := cmdRecovery([]string{
		"transfer", "--source", "source-a", "--target", "destination-b",
		"--snapshot", "snapshot", "--tmux-socket", "custom",
	})
	if code != 0 {
		t.Fatalf("transfer exit = %d", code)
	}
	read := <-requests
	write := <-requests
	if read.method != http.MethodGet || read.host != "source-a" || read.path != "/recovery/snapshot" ||
		read.query.Get("id") != "snapshot" || read.query.Get("socket") != "custom" {
		t.Fatalf("source request = %#v", read)
	}
	if write.method != http.MethodPost || write.host != "destination-b" || write.path != "/recovery/snapshot" ||
		write.query.Get("socket") != "custom" || !bytes.Equal(write.body, manifest) {
		t.Fatalf("target request = %#v", write)
	}
}
