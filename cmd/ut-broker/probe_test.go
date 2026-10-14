package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLocalBrokerProbeRequiresServiceAndSocketOwnership(t *testing.T) {
	for _, test := range []struct {
		name, body string
		status     int
		want       bool
	}{
		{"owned", `{"service":"universal-tmux-broker","socket":"second"}`, 200, true},
		{"wrong-socket", `{"service":"universal-tmux-broker","socket":"ut"}`, 200, false},
		{"unrelated-service", `{"service":"other","socket":"second"}`, 200, false},
		{"malformed", `not json`, 200, false},
		{"failed", `{"service":"universal-tmux-broker","socket":"second"}`, 503, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/whoami" {
					t.Errorf("unexpected path %s", r.URL.Path)
				}
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()
			if got := localBrokerMatches(server.URL, "second"); got != test.want {
				t.Fatalf("matched = %v", got)
			}
		})
	}
}
