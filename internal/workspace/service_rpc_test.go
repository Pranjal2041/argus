package workspace

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServiceRPCIsTransientSingleDeliveryAndFenced(t *testing.T) {
	s := testStore(t)
	if _, err := s.Enable(); err != nil {
		t.Fatal(err)
	}
	lease, err := s.Claim("usage", "fixture-worker", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.RegisterRoutes(mux)
	server := httptest.NewServer(mux)
	defer server.Close()
	post := func(path string, body any) (int, []byte) {
		encoded, _ := json.Marshal(body)
		response, err := http.Post(server.URL+path, "application/json", bytes.NewReader(encoded))
		if err != nil {
			t.Error(err)
			return 0, nil
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(response.Body)
		return response.StatusCode, data
	}
	result := make(chan []byte, 1)
	go func() {
		_, data := post("/workspace/service/usage", map[string]string{"action": "save", "credential": "rpc-only-fixture-secret"})
		result <- data
	}()
	var call struct {
		ID   string          `json:"id"`
		Body json.RawMessage `json:"body"`
	}
	deadline := time.Now().Add(time.Second)
	for call.ID == "" && time.Now().Before(deadline) {
		status, data := post("/workspace/service/usage/take", lease)
		if status != 200 {
			t.Fatalf("take status %d", status)
		}
		_ = json.Unmarshal(data, &call)
		if call.ID == "" {
			time.Sleep(time.Millisecond)
		}
	}
	if call.ID == "" || !bytes.Contains(call.Body, []byte("rpc-only-fixture-secret")) {
		t.Fatal("request not delivered")
	}
	_, again := post("/workspace/service/usage/take", lease)
	if bytes.Contains(again, []byte(call.ID)) {
		t.Fatal("request delivered twice")
	}
	stale := lease
	stale.Fence++
	status, _ := post("/workspace/service/usage/reply", map[string]any{"id": call.ID, "lease": stale, "body": map[string]bool{"ok": true}})
	if status != 409 {
		t.Fatalf("unowned reply accepted: %d", status)
	}
	status, _ = post("/workspace/service/usage/reply", map[string]any{"id": call.ID, "lease": lease, "body": map[string]bool{"ok": true}})
	if status != 200 {
		t.Fatalf("reply: %d", status)
	}
	select {
	case data := <-result:
		if string(data) != `{"ok":true}` {
			t.Fatalf("unexpected result: %s", data)
		}
	case <-time.After(time.Second):
		t.Fatal("reply not received")
	}
	snapshot, _ := s.Snapshot("")
	if len(snapshot.Records) != 0 || snapshot.Cursor != 0 {
		t.Fatal("private call entered shared records")
	}
	files, _ := filepath.Glob(filepath.Join(s.root, "*"))
	for _, file := range files {
		data, _ := os.ReadFile(file)
		if bytes.Contains(data, []byte("rpc-only-fixture-secret")) {
			t.Fatal("credential was persisted")
		}
	}
}

func TestServiceRPCCancellationDropsRequestAndWorkerMustBeLocal(t *testing.T) {
	s := testStore(t)
	_, _ = s.Enable()
	lease, _ := s.Claim("usage", "fixture-worker", time.Minute)
	mux := http.NewServeMux()
	s.RegisterRoutes(mux)
	body, _ := json.Marshal(lease)
	remote := httptest.NewRequest(http.MethodPost, "/workspace/service/usage/take", bytes.NewReader(body))
	remote.RemoteAddr = "192.0.2.1:1234"
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, remote)
	if response.Code != 403 {
		t.Fatal("remote worker accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	request := httptest.NewRequest(http.MethodPost, "/workspace/service/usage", bytes.NewBufferString(`{"action":"state"}`)).WithContext(ctx)
	done := make(chan struct{})
	go func() { mux.ServeHTTP(httptest.NewRecorder(), request); close(done) }()
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancelled call retained")
	}
	local := httptest.NewRequest(http.MethodPost, "/workspace/service/usage/take", bytes.NewReader(body))
	local.RemoteAddr = "127.0.0.1:1234"
	response = httptest.NewRecorder()
	mux.ServeHTTP(response, local)
	if response.Code != 200 || bytes.Contains(response.Body.Bytes(), []byte(`"id"`)) {
		t.Fatal("cancelled call still available")
	}
}
