package broker

import (
	"bytes"
	"testing"
	"time"

	"universal-tmux/internal/session"
)

type viewerQuerySession struct{ recordingInputSession }

func (*viewerQuerySession) QueryOwnership() session.QueryOwnership { return session.ViewerQueries }

func querySubscriber(interactive bool) *subscriber {
	return &subscriber{ch: make(chan []byte, 32), done: make(chan struct{}), cancel: func() {}, primed: true, interactive: interactive}
}

func readQueryFrame(t *testing.T, s *subscriber) []byte {
	t.Helper()
	select {
	case frame := <-s.ch:
		op, _, b, ok := decodeFrame(frame)
		if !ok || op != opOutput {
			t.Fatalf("unexpected frame: %x", frame)
		}
		return b
	case <-time.After(time.Second):
		t.Fatal("missing output frame")
		return nil
	}
}

func TestTerminalQueryOwnershipAcrossViewersAndReconnect(t *testing.T) {
	for _, viewerOwned := range []bool{false, true} {
		t.Run(map[bool]string{false: "backend", true: "viewer"}[viewerOwned], func(t *testing.T) {
			raw := &recordingInputSession{out: make(chan session.Output, 10)}
			var backend session.Session = raw
			if viewerOwned {
				backend = &viewerQuerySession{*raw}
			}
			h := newSessionHub(backend)
			defer close(raw.out)
			a, b, observer := querySubscriber(true), querySubscriber(true), querySubscriber(false)
			h.mu.Lock()
			h.subs[a], h.subs[b], h.subs[observer] = struct{}{}, struct{}{}, struct{}{}
			h.mu.Unlock()
			query := "\x1b[6n\x1b]11;?\a\x1b[?u"
			raw.out <- session.Output{Pane: "%0", Data: []byte("screen" + query)}
			x, y := readQueryFrame(t, a), readQueryFrame(t, b)
			if got := string(readQueryFrame(t, observer)); got != "screen" {
				t.Fatalf("observer got query: %q", got)
			}
			if viewerOwned {
				if bytes.Count(append(x, y...), []byte("\x1b[6n")) != 1 {
					t.Fatalf("expected exactly one responder: %q / %q", x, y)
				}
			} else if string(x) != "screen" || string(y) != "screen" {
				t.Fatalf("backend-owned query leaked: %q / %q", x, y)
			}
			// Remove the current owner. The next query goes to the surviving
			// interactive client, never the read-only observer.
			h.mu.Lock()
			owner := h.replyViewer
			if owner == nil {
				owner = a
			}
			delete(h.subs, owner)
			h.mu.Unlock()
			survivor := a
			if owner == a {
				survivor = b
			}
			raw.out <- session.Output{Pane: "%0", Data: []byte("next" + query)}
			want := "next"
			if viewerOwned {
				want += query
			}
			if got := string(readQueryFrame(t, survivor)); got != want {
				t.Fatalf("failover: %q, want %q", got, want)
			}
			if got := string(readQueryFrame(t, observer)); got != "next" {
				t.Fatalf("observer elected: %q", got)
			}
		})
	}
}

func TestSnapshotQueriesArePassiveAndDoNotConsumeLiveParser(t *testing.T) {
	for _, viewerOwned := range []bool{false, true} {
		t.Run(map[bool]string{false: "backend", true: "viewer"}[viewerOwned], func(t *testing.T) {
			raw := &recordingInputSession{out: make(chan session.Output, 10)}
			var backend session.Session = raw
			if viewerOwned {
				backend = &viewerQuerySession{*raw}
			}
			h := newSessionHub(backend)
			defer close(raw.out)
			s := querySubscriber(true)
			h.mu.Lock()
			h.subs[s] = struct{}{}
			s.snapshotID = 42
			h.mu.Unlock()
			control := func(want byte) {
				t.Helper()
				select {
				case frame := <-s.ch:
					op, pane, data, ok := decodeFrame(frame)
					if !ok || op != want || pane != "%0" || len(data) != 0 {
						t.Fatalf("snapshot control %d: %x", want, frame)
					}
				case <-time.After(time.Second):
					t.Fatal("missing snapshot control")
				}
			}
			raw.out <- session.Output{Pane: "%0", Data: []byte("live\x1b[")}
			if got := string(readQueryFrame(t, s)); got != "live" {
				t.Fatalf("live prefix: %q", got)
			}
			raw.out <- session.Output{Pane: "%0", SnapshotID: 42, Data: []byte("capture\x1b[6n\x1b]10;?\a\x1b[")}
			control(opSnapshotBegin)
			if got := string(readQueryFrame(t, s)); got != "capture" {
				t.Fatalf("replay query leaked: %q", got)
			}
			control(opSnapshotEnd)
			raw.out <- session.Output{Pane: "%0", Data: []byte("6nend")}
			want := "end"
			if viewerOwned {
				want = "\x1b[6nend"
			}
			if got := string(readQueryFrame(t, s)); got != want {
				t.Fatalf("snapshot contaminated live query: %q", got)
			}
		})
	}
}

func TestRawBackendWithoutInteractiveViewerDoesNotEmitQueries(t *testing.T) {
	raw := &viewerQuerySession{recordingInputSession{out: make(chan session.Output, 4)}}
	h := newSessionHub(raw)
	defer close(raw.out)
	observer := querySubscriber(false)
	h.mu.Lock()
	h.subs[observer] = struct{}{}
	h.mu.Unlock()
	raw.out <- session.Output{Pane: "%0", Data: []byte("display\x1b[6n")}
	if got := string(readQueryFrame(t, observer)); got != "display" {
		t.Fatalf("read-only viewer got query: %q", got)
	}
}

func TestQueryOwnerStaysStableWhenViewersJoinAndPanesInterleave(t *testing.T) {
	raw := &viewerQuerySession{recordingInputSession{out: make(chan session.Output, 10)}}
	h := newSessionHub(raw)
	defer close(raw.out)
	owner, unprimed := querySubscriber(true), querySubscriber(true)
	unprimed.primed = false
	h.mu.Lock()
	h.subs[owner], h.subs[unprimed] = struct{}{}, struct{}{}
	h.mu.Unlock()
	raw.out <- session.Output{Pane: "%0", Data: []byte("one\x1b[")}
	if got := string(readQueryFrame(t, owner)); got != "one" {
		t.Fatal(got)
	}
	joined := querySubscriber(true)
	h.mu.Lock()
	h.subs[joined] = struct{}{}
	h.mu.Unlock()
	// A different pane's display must not complete the first pane's CSI.
	raw.out <- session.Output{Pane: "%1", Data: []byte("6nother\x1b[c")}
	if got := string(readQueryFrame(t, owner)); got != "6nother\x1b[c" {
		t.Fatalf("owner changed or panes mixed: %q", got)
	}
	if got := string(readQueryFrame(t, joined)); got != "6nother" {
		t.Fatalf("new viewer answered: %q", got)
	}
	raw.out <- session.Output{Pane: "%0", Data: []byte("6nend")}
	if got := string(readQueryFrame(t, owner)); got != "\x1b[6nend" {
		t.Fatalf("partial query lost owner: %q", got)
	}
	if got := string(readQueryFrame(t, joined)); got != "end" {
		t.Fatalf("new viewer got query tail: %q", got)
	}
	if len(unprimed.ch) != 0 {
		t.Fatal("unprimed viewer received output")
	}
}
