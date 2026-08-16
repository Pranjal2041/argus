// Package browserbridge relays versioned browser-control requests from any ut
// broker to the Argus process running on the hub Mac. Argus owns WebKit and
// registers a short-lived loopback provider; the broker owns discovery and mesh
// reachability but deliberately knows nothing about browser semantics.
package browserbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const defaultStaleAfter = 15 * time.Second
const maxRPCRequestBytes = 1 << 20

// Registration is refreshed by Argus while its browser provider is alive.
// Port always identifies a loopback-only HTTP listener in the Argus process.
type Registration struct {
	Port     int    `json:"port"`
	Version  int    `json:"version"`
	PID      int    `json:"pid,omitempty"`
	Provider string `json:"provider,omitempty"`
}

// Registry is safe for concurrent HTTP handlers.
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

// RegisterRoutes exposes the stable broker-side boundary. /browser/rpc is an
// opaque reverse relay: adding browser operations never requires a broker
// release as long as the protocol version remains compatible.
func (r *Registry) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/browser/provider", r.handleProvider)
	mux.HandleFunc("/browser/status", r.handleStatus)
	mux.HandleFunc("/browser/rpc", r.handleRPC)
}

func (r *Registry) handleProvider(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch req.Method {
	case http.MethodPost:
		defer req.Body.Close()
		var registration Registration
		if err := json.NewDecoder(io.LimitReader(req.Body, 64<<10)).Decode(&registration); err != nil {
			writeError(w, http.StatusBadRequest, "invalid browser provider registration")
			return
		}
		if registration.Port < 1 || registration.Port > 65535 || registration.Version < 1 {
			writeError(w, http.StatusBadRequest, "browser provider requires a valid port and version")
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
		"browser_host":   r.host,
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

func (r *Registry) handleRPC(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	registration, _, available := r.active()
	if !available {
		writeError(w, http.StatusServiceUnavailable, "Argus browser provider is not running")
		return
	}
	defer req.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(req.Body, maxRPCRequestBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "could not read browser request")
		return
	}
	if len(payload) > maxRPCRequestBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "browser request is too large")
		return
	}

	target := "http://127.0.0.1:" + strconv.Itoa(registration.Port) + "/rpc"
	upstream, err := http.NewRequestWithContext(req.Context(), http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	upstream.Header.Set("Content-Type", req.Header.Get("Content-Type"))
	response, err := r.client.Do(upstream)
	if err != nil {
		writeError(w, http.StatusBadGateway, "Argus browser provider stopped responding")
		return
	}
	defer response.Body.Close()
	for key, values := range response.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, response.Body)
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": message})
}
