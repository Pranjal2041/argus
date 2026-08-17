// Package weeklyprogressbridge exposes the Weekly Progress service hosted by
// Argus through the Mac broker. The broker deliberately treats both metadata
// and assets as opaque HTTP: Argus remains the only owner of project semantics,
// generation state, and files on disk.
package weeklyprogressbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const defaultStaleAfter = 15 * time.Second
const maxCommandBytes = 2 << 20

type Registration struct {
	Port     int    `json:"port"`
	Version  int    `json:"version"`
	PID      int    `json:"pid,omitempty"`
	Provider string `json:"provider,omitempty"`
}

type Registry struct {
	mu         sync.RWMutex
	host       string
	registered Registration
	lastSeen   time.Time
	staleAfter time.Duration
	now        func() time.Time
	client     *http.Client
}

func New(host string) *Registry {
	return &Registry{
		host:       host,
		staleAfter: defaultStaleAfter,
		now:        time.Now,
		client:     &http.Client{},
	}
}

func (r *Registry) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/weekly-progress/provider", r.handleProvider)
	mux.HandleFunc("/weekly-progress/status", r.handleStatus)
	mux.HandleFunc("/weekly-progress/", r.handleRelay)
}

func (r *Registry) handleProvider(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch req.Method {
	case http.MethodPost:
		defer req.Body.Close()
		var registration Registration
		if err := json.NewDecoder(io.LimitReader(req.Body, 64<<10)).Decode(&registration); err != nil {
			writeError(w, http.StatusBadRequest, "invalid weekly progress provider registration")
			return
		}
		if registration.Port < 1 || registration.Port > 65535 || registration.Version < 1 {
			writeError(w, http.StatusBadRequest, "weekly progress provider requires a valid port and version")
			return
		}
		if registration.Provider == "" {
			registration.Provider = "Argus"
		}
		r.mu.Lock()
		r.registered = registration
		r.lastSeen = r.now()
		r.mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	case http.MethodDelete:
		r.mu.Lock()
		r.registered = Registration{}
		r.lastSeen = time.Time{}
		r.mu.Unlock()
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	default:
		w.Header().Set("Allow", "POST, DELETE")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (r *Registry) active() (Registration, time.Time, bool) {
	r.mu.RLock()
	registration, lastSeen := r.registered, r.lastSeen
	r.mu.RUnlock()
	available := registration.Port > 0 && !lastSeen.IsZero() && r.now().Sub(lastSeen) <= r.staleAfter
	return registration, lastSeen, available
}

func (r *Registry) handleStatus(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if req.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	registration, lastSeen, available := r.active()
	response := map[string]any{
		"available":      available,
		"progress_host":  r.host,
		"network_origin": r.host,
	}
	if available {
		response["version"] = registration.Version
		response["provider"] = registration.Provider
		response["pid"] = registration.PID
		response["last_seen"] = lastSeen.UTC().Format(time.RFC3339Nano)
	}
	_ = json.NewEncoder(w).Encode(response)
}

func (r *Registry) handleRelay(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet && req.Method != http.MethodHead && req.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, HEAD, POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	registration, _, available := r.active()
	if !available {
		writeError(w, http.StatusServiceUnavailable, "Argus weekly progress provider is not running")
		return
	}

	var body io.Reader
	if req.Method == http.MethodPost {
		defer req.Body.Close()
		payload, err := io.ReadAll(io.LimitReader(req.Body, maxCommandBytes+1))
		if err != nil {
			writeError(w, http.StatusBadRequest, "could not read weekly progress request")
			return
		}
		if len(payload) > maxCommandBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "weekly progress request is too large")
			return
		}
		body = bytes.NewReader(payload)
	}

	providerPath := strings.TrimPrefix(req.URL.Path, "/weekly-progress")
	if providerPath == "" || providerPath == "/" {
		providerPath = "/catalog"
	}
	target := "http://127.0.0.1:" + strconv.Itoa(registration.Port) + providerPath
	if req.URL.RawQuery != "" {
		target += "?" + req.URL.RawQuery
	}
	upstream, err := http.NewRequestWithContext(req.Context(), req.Method, target, body)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	for _, header := range []string{"Content-Type", "Accept", "Range", "If-None-Match", "If-Modified-Since"} {
		if value := req.Header.Get(header); value != "" {
			upstream.Header.Set(header, value)
		}
	}
	response, err := r.client.Do(upstream)
	if err != nil {
		writeError(w, http.StatusBadGateway, "Argus weekly progress provider stopped responding")
		return
	}
	defer response.Body.Close()
	for key, values := range response.Header {
		if strings.EqualFold(key, "Connection") || strings.EqualFold(key, "Transfer-Encoding") {
			continue
		}
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	if req.Method != http.MethodHead {
		_, _ = io.Copy(w, response.Body)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": message})
}
