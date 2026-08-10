package broker

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"universal-tmux/internal/session"
)

type recordingInputSession struct {
	input chan []byte
	out   chan session.Output
}

func (s *recordingInputSession) Output() <-chan session.Output { return s.out }
func (s *recordingInputSession) SendKeys(_ string, data []byte) error {
	copyOfData := append([]byte(nil), data...)
	s.input <- copyOfData
	return nil
}
func (s *recordingInputSession) Resize(int, int) error { return nil }
func (s *recordingInputSession) Size() (int, int)      { return 0, 0 }
func (s *recordingInputSession) Snapshot() []byte      { return nil }
func (s *recordingInputSession) Pane() string          { return "%0" }
func (s *recordingInputSession) Close()                {}

func TestSessionHubAcceptsLegacyLargeInputMessage(t *testing.T) {
	backend := &recordingInputSession{
		input: make(chan []byte, 1),
		out:   make(chan session.Output),
	}
	hub := &sessionHub{
		tm:   backend,
		subs: make(map[*subscriber]struct{}),
		dead: make(chan struct{}),
	}
	serveResult := make(chan error, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			serveResult <- err
			return
		}
		defer conn.CloseNow()
		serveResult <- hub.serve(r.Context(), conn)
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()

	want := make([]byte, 128*1024+137)
	for i := range want {
		want[i] = byte(i % 251)
	}
	if err := conn.Write(ctx, websocket.MessageBinary, encodeFrame(opInput, "%0", want)); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-backend.input:
		if !bytes.Equal(got, want) {
			t.Fatal("large input changed while crossing the WebSocket boundary")
		}
	case <-ctx.Done():
		t.Fatal("large input never reached the session backend")
	}
	conn.CloseNow()
	select {
	case <-serveResult:
	case <-ctx.Done():
		t.Fatal("session WebSocket did not stop after the client closed")
	}
}
