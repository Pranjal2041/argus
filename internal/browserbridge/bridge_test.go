package browserbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"testing"
	"time"
)

func TestRegisterStatusAndRelay(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/rpc" || req.Method != http.MethodPost {
			t.Fatalf("provider request = %s %s", req.Method, req.URL.Path)
		}
		if req.ContentLength <= 0 {
			t.Fatalf("relay must send a concrete Content-Length, got %d", req.ContentLength)
		}
		body, _ := io.ReadAll(req.Body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(append([]byte(`{"relayed":`), append(body, '}')...))
	}))
	defer provider.Close()
	providerURL, _ := url.Parse(provider.URL)
	port, _ := strconv.Atoi(providerURL.Port())

	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)
	registry := New("pranjala-mac")
	registry.now = func() time.Time { return now }
	mux := http.NewServeMux()
	registry.RegisterRoutes(mux)

	registration, _ := json.Marshal(Registration{Port: port, Version: 1, PID: 42, Provider: "Argus"})
	req := httptest.NewRequest(http.MethodPost, "/browser/provider", bytes.NewReader(registration))
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, req)
	if recorder.Code != http.StatusOK {
		t.Fatalf("register status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	recorder = httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/browser/status", nil))
	var status map[string]any
	_ = json.Unmarshal(recorder.Body.Bytes(), &status)
	if status["available"] != true || status["browser_host"] != "pranjala-mac" || status["version"] != float64(1) {
		t.Fatalf("unexpected status: %#v", status)
	}

	recorder = httptest.NewRecorder()
	mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/browser/rpc", bytes.NewBufferString(`{"method":"tabs.list"}`)))
	if recorder.Code != http.StatusOK || recorder.Body.String() != `{"relayed":{"method":"tabs.list"}}` {
		t.Fatalf("relay status = %d, body = %q", recorder.Code, recorder.Body.String())
	}
}

func TestRegistrationExpires(t *testing.T) {
	now := time.Date(2026, 8, 16, 12, 0, 0, 0, time.UTC)
	registry := New("mac")
	registry.now = func() time.Time { return now }
	registry.registered = Registration{Port: 1234, Version: 1}
	registry.lastSeen = now

	if _, _, available := registry.active(); !available {
		t.Fatal("fresh provider should be available")
	}
	now = now.Add(defaultStaleAfter + time.Millisecond)
	if _, _, available := registry.active(); available {
		t.Fatal("stale provider should be unavailable")
	}
}
