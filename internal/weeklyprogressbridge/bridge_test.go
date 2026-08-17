package weeklyprogressbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func registerTestProvider(t *testing.T, registry *Registry, provider *httptest.Server) *http.ServeMux {
	t.Helper()
	providerURL, err := url.Parse(provider.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(providerURL.Port())
	mux := http.NewServeMux()
	registry.RegisterRoutes(mux)
	body, _ := json.Marshal(Registration{Port: port, Version: 1, PID: 42, Provider: "Argus"})
	req := httptest.NewRequest(http.MethodPost, "/weekly-progress/provider", bytes.NewReader(body))
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("register status = %d, body = %s", res.Code, res.Body.String())
	}
	return mux
}

func TestRelayPreservesPathQueryAndBinaryResponse(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/asset/generation/deck" || req.URL.Query().Get("download") != "1" {
			t.Fatalf("provider request = %s", req.URL.String())
		}
		if got := req.Header.Get("Range"); got != "bytes=4-7" {
			t.Fatalf("Range = %q", got)
		}
		w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.presentationml.presentation")
		w.Header().Set("Content-Range", "bytes 4-7/12")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write([]byte{4, 5, 6, 7})
	}))
	defer provider.Close()

	registry := New("main-mac")
	mux := registerTestProvider(t, registry, provider)
	req := httptest.NewRequest(http.MethodGet, "/weekly-progress/asset/generation/deck?download=1", nil)
	req.Header.Set("Range", "bytes=4-7")
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, req)
	if res.Code != http.StatusPartialContent {
		t.Fatalf("status = %d, body = %s", res.Code, res.Body.String())
	}
	data, _ := io.ReadAll(res.Result().Body)
	if !bytes.Equal(data, []byte{4, 5, 6, 7}) {
		t.Fatalf("body = %v", data)
	}
	if !strings.Contains(res.Header().Get("Content-Type"), "presentationml.presentation") {
		t.Fatalf("Content-Type = %q", res.Header().Get("Content-Type"))
	}
}

func TestStatusTurnsUnavailableAfterHeartbeatExpires(t *testing.T) {
	now := time.Date(2026, 8, 17, 12, 0, 0, 0, time.UTC)
	provider := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer provider.Close()
	registry := New("main-mac")
	registry.now = func() time.Time { return now }
	mux := registerTestProvider(t, registry, provider)

	status := func() map[string]any {
		res := httptest.NewRecorder()
		mux.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/weekly-progress/status", nil))
		var value map[string]any
		_ = json.Unmarshal(res.Body.Bytes(), &value)
		return value
	}
	if status()["available"] != true {
		t.Fatal("fresh provider should be available")
	}
	now = now.Add(defaultStaleAfter + time.Second)
	if status()["available"] != false {
		t.Fatal("stale provider should be unavailable")
	}
}

func TestRelayRejectsOversizedCommand(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("oversized request reached provider")
	}))
	defer provider.Close()
	registry := New("main-mac")
	mux := registerTestProvider(t, registry, provider)

	res := httptest.NewRecorder()
	mux.ServeHTTP(res, httptest.NewRequest(
		http.MethodPost,
		"/weekly-progress/generate",
		bytes.NewReader(make([]byte, maxCommandBytes+1)),
	))
	if res.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d", res.Code)
	}
}
