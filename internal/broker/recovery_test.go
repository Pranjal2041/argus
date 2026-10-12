package broker

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"

	"universal-tmux/internal/session"
)

type recoverySession struct {
	recordingInputSession
	mode       atomic.Int32 // 0: silent, 1: healthy, 2: submission error, 3: blocked, 4: invalid reply
	closes     atomic.Int32
	requests   chan uint64
	detached   chan struct{}
	closeOnce  sync.Once
	persistent bool
}

func newRecoverySession(persistent bool) *recoverySession {
	return &recoverySession{
		recordingInputSession: recordingInputSession{out: make(chan session.Output, 32)},
		requests:              make(chan uint64, 32), detached: make(chan struct{}), persistent: persistent,
	}
}

func (s *recoverySession) RequestSnapshot(id uint64) error {
	s.requests <- id
	switch s.mode.Load() {
	case 1:
		s.out <- session.Output{Pane: "%0", SnapshotID: id, Cols: 80, Rows: 24, Data: []byte("recovered")}
	case 2:
		return errors.New("snapshot submission failed")
	case 3:
		<-s.detached
		return errors.New("attachment detached")
	case 4:
		s.out <- session.Output{Pane: "%0", SnapshotID: id}
	}
	return nil
}

func (s *recoverySession) Close() {
	s.closes.Add(1)
	s.closeOnce.Do(func() {
		close(s.detached)
		if !s.persistent {
			close(s.out)
		}
	})
}

type recoveryProvider struct {
	warmProvider
	first, replacement *recoverySession
	dials, kills       atomic.Int32
}

func (p *recoveryProvider) Dial(context.Context, string) (session.Session, error) {
	if p.dials.Add(1) == 1 {
		return p.first, nil
	}
	p.replacement.mode.Store(1)
	return p.replacement, nil
}

func (p *recoveryProvider) Kill(string) error { p.kills.Add(1); return nil }

func recoverySubscriber(h *sessionHub) (*subscriber, context.Context) {
	ctx, cancel := context.WithCancel(context.Background())
	s := &subscriber{ch: make(chan []byte, 32), done: make(chan struct{}), cancel: cancel}
	h.mu.Lock()
	h.subs[s] = struct{}{}
	h.mu.Unlock()
	return s, ctx
}

func awaitRecovery(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("attachment did not finish retiring")
	}
}

func readRecoverySnapshot(t *testing.T, s *subscriber) string {
	t.Helper()
	var data string
	for {
		select {
		case frame := <-s.ch:
			op, _, payload, ok := decodeFrame(frame)
			if !ok {
				t.Fatal("invalid frame")
			}
			if op == opOutput {
				data += string(payload)
			}
			if op == opSnapshotEnd {
				return data
			}
		case <-time.After(2 * time.Second):
			t.Fatal("replacement did not deliver a snapshot")
		}
	}
}

func TestSnapshotTimeoutReplacesAttachmentWithoutRestartingSession(t *testing.T) {
	for _, persistent := range []bool{false, true} {
		name := "fresh-control-stream"
		if persistent {
			name = "persistent-shared-stream"
		}
		t.Run(name, func(t *testing.T) {
			first, replacement := newRecoverySession(persistent), newRecoverySession(persistent)
			if persistent {
				replacement = first // ConPTY-style ownership: Close leaves Output open.
			}
			p := &recoveryProvider{warmProvider: warmProvider{exists: true}, first: first, replacement: replacement}
			m := &Manager{ctx: context.Background(), prov: p, hubs: make(map[string]*sessionHub)}
			h, err := m.hub("shell")
			if err != nil {
				t.Fatal(err)
			}
			defer h.close()
			h.snapshotWait = 20 * time.Millisecond
			s, ctx := recoverySubscriber(h)
			_, peerCtx := recoverySubscriber(h)
			if err := h.requestSnapshot(s); err != nil {
				t.Fatal(err)
			}
			oldID := <-first.requests
			// A viewer disconnecting before the watchdog must not mask failure.
			s.cancel()
			h.mu.Lock()
			delete(h.subs, s)
			h.mu.Unlock()
			awaitRecovery(t, h.dead)
			awaitRecovery(t, ctx.Done())
			awaitRecovery(t, peerCtx.Done())
			if first.closes.Load() != 1 {
				t.Fatalf("detach calls = %d, want 1", first.closes.Load())
			}
			if err := h.requestSnapshot(s); err == nil {
				t.Fatal("retired attachment accepted another request")
			}
			if persistent {
				first.out <- session.Output{Pane: "%0", SnapshotID: oldID, Data: []byte("stale snapshot")}
			}
			// Concurrent reconnects must all converge on exactly one replacement.
			results := make(chan *sessionHub, 12)
			var group sync.WaitGroup
			for range cap(results) {
				group.Go(func() {
					next, err := m.hub("shell")
					if err != nil {
						t.Error(err)
					}
					results <- next
				})
			}
			group.Wait()
			close(results)
			next := <-results
			if next == nil || next == h {
				t.Fatal("reconnected to the failed attachment")
			}
			defer next.close()
			for got := range results {
				if got != next {
					t.Fatal("concurrent reconnects created competing readers")
				}
			}
			fresh, _ := recoverySubscriber(next)
			if err := next.requestSnapshot(fresh); err != nil {
				t.Fatal(err)
			}
			newID := <-replacement.requests
			if newID == oldID {
				t.Fatal("snapshot ID reused across attachments")
			}
			if got := readRecoverySnapshot(t, fresh); got != "recovered" {
				t.Fatalf("late snapshot contaminated recovery: %q", got)
			}
			replacement.out <- session.Output{Pane: "%0", Data: []byte("live continuation")}
			if got := string(readQueryFrame(t, fresh)); got != "live continuation" {
				t.Fatalf("live stream not recovered: %q", got)
			}
			if p.dials.Load() != 2 || p.kills.Load() != 0 || p.createCalls != 0 {
				t.Fatalf("recovery lifecycle: dials=%d kills=%d creates=%d", p.dials.Load(), p.kills.Load(), p.createCalls)
			}
		})
	}
}

func TestSnapshotSubmissionFailureRetiresAttachment(t *testing.T) {
	for _, mode := range []int32{2, 3} {
		t.Run(map[int32]string{2: "error", 3: "blocked-write"}[mode], func(t *testing.T) {
			s := newRecoverySession(false)
			s.mode.Store(mode)
			h := newSessionHub(s)
			defer h.close()
			h.snapshotWait = 20 * time.Millisecond
			sub, ctx := recoverySubscriber(h)
			result := make(chan error, 1)
			go func() { result <- h.requestSnapshot(sub) }()
			awaitRecovery(t, h.dead)
			awaitRecovery(t, ctx.Done())
			select {
			case err := <-result:
				if err == nil {
					t.Fatal("submission failure was hidden")
				}
			case <-time.After(time.Second):
				t.Fatal("deadline did not unblock submission")
			}
		})
	}
}

func TestCompletedSnapshotCannotRetireHealthyAttachment(t *testing.T) {
	s := newRecoverySession(true)
	s.mode.Store(1)
	h := newSessionHub(s)
	defer h.close()
	sub, _ := recoverySubscriber(h)
	if err := h.requestSnapshot(sub); err != nil {
		t.Fatal(err)
	}
	id := <-s.requests
	readRecoverySnapshot(t, sub)
	h.snapshotExpired(id) // A timer callback already scheduled before Stop is harmless.
	select {
	case <-h.stop:
		t.Fatal("completed snapshot retired a healthy attachment")
	default:
	}
	h.mu.Lock()
	pending := len(h.snapshots)
	h.mu.Unlock()
	if pending != 0 {
		t.Fatalf("completed snapshot retained %d watchdogs", pending)
	}
}

func TestBackendEOFImmediatelyDisconnectsViewers(t *testing.T) {
	s := newRecoverySession(true)
	h := newSessionHub(s)
	sub, ctx := recoverySubscriber(h)
	if err := h.requestSnapshot(sub); err != nil {
		t.Fatal(err)
	}
	close(s.out)
	awaitRecovery(t, h.dead)
	awaitRecovery(t, ctx.Done())
}

func TestInvalidSnapshotRetiresAttachment(t *testing.T) {
	s := newRecoverySession(true)
	s.mode.Store(4)
	h := newSessionHub(s)
	defer h.close()
	sub, ctx := recoverySubscriber(h)
	if err := h.requestSnapshot(sub); err != nil {
		t.Fatal(err)
	}
	awaitRecovery(t, h.dead)
	awaitRecovery(t, ctx.Done())
}

func TestDisconnectedViewerSnapshotStillCompletesHealthCheck(t *testing.T) {
	s := newRecoverySession(true)
	h := newSessionHub(s)
	defer h.close()
	sub, _ := recoverySubscriber(h)
	if err := h.requestSnapshot(sub); err != nil {
		t.Fatal(err)
	}
	id := <-s.requests
	h.mu.Lock()
	delete(h.subs, sub)
	h.mu.Unlock()
	sub.cancel()
	peer, _ := recoverySubscriber(h)
	h.mu.Lock()
	peer.primed = true
	h.mu.Unlock()
	s.out <- session.Output{Pane: "%0", SnapshotID: id, Data: []byte("departed viewer's snapshot")}
	s.out <- session.Output{Pane: "%0", Data: []byte("still healthy")}
	if got := string(readQueryFrame(t, peer)); got != "still healthy" {
		t.Fatal(got)
	}
	h.snapshotExpired(id)
	select {
	case <-h.stop:
		t.Fatal("viewer departure caused a healthy backend to detach")
	default:
	}
}

func TestWebSocketReconnectReceivesSnapshotFromReplacement(t *testing.T) {
	p := &recoveryProvider{
		warmProvider: warmProvider{exists: true},
		first:        newRecoverySession(false), replacement: newRecoverySession(false),
	}
	m := &Manager{ctx: context.Background(), prov: p, hubs: make(map[string]*sessionHub)}
	h, err := m.hub("shell")
	if err != nil {
		t.Fatal(err)
	}
	h.snapshotWait = 20 * time.Millisecond
	defer m.dropHub("shell")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next, err := m.hub("shell")
		if err != nil {
			t.Error(err)
			return
		}
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		_ = next.serve(r.Context(), conn)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connect := func() *websocket.Conn {
		t.Helper()
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.CloseNow() })
		if err := conn.Write(ctx, websocket.MessageBinary, encodeFrame(opReqSnapshot, "", nil)); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	first := connect()
	if _, _, err := first.Read(ctx); err == nil || ctx.Err() != nil {
		t.Fatalf("failed attachment did not promptly disconnect its WebSocket: %v", err)
	}
	next := connect()
	var screen string
	for {
		_, frame, err := next.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		op, _, payload, ok := decodeFrame(frame)
		if !ok {
			t.Fatal("invalid replacement frame")
		}
		if op == opOutput {
			screen += string(payload)
		}
		if op == opSnapshotEnd {
			break
		}
	}
	if screen != "recovered" || p.dials.Load() != 2 || p.kills.Load() != 0 {
		t.Fatalf("WebSocket reconnect failed: screen=%q dials=%d kills=%d", screen, p.dials.Load(), p.kills.Load())
	}
}
