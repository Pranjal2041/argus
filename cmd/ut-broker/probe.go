package main

import (
	"encoding/json"
	"io"
	"net/http"
	"time"
)

// A live HTTP port is not proof of the requested broker. All launch paths use
// the service handshake and backend socket, not a process name or stale PID.
func localBrokerMatches(base, socket string) bool {
	client := &http.Client{Timeout: 2 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Get(base + "/whoami")
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false
	}
	var identity struct {
		Service string `json:"service"`
		Socket  string `json:"socket"`
	}
	return json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&identity) == nil &&
		identity.Service == "universal-tmux-broker" && identity.Socket == socket
}
