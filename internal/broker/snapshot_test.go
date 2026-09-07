package broker

import (
	"bytes"
	"context"
	"testing"
	"time"
	"universal-tmux/internal/session"
)

type snapshotSession struct {
	recordingInputSession
	requests chan uint64
}

func (s *snapshotSession) RequestSnapshot(id uint64) error { s.requests <- id; return nil }

func TestSnapshotAndLiveFramesHaveOneOrderedWriter(t *testing.T) {
	s := &snapshotSession{recordingInputSession: recordingInputSession{out: make(chan session.Output, 20)}, requests: make(chan uint64, 4)}
	h := newSessionHub(s)
	defer close(s.out)
	_, cancel := context.WithCancel(context.Background())
	defer cancel()
	a := &subscriber{ch: make(chan []byte, 20), done: make(chan struct{}), cancel: cancel}
	b := &subscriber{ch: make(chan []byte, 20), done: make(chan struct{}), cancel: cancel, primed: true}
	h.mu.Lock()
	h.subs[a] = struct{}{}
	h.subs[b] = struct{}{}
	h.mu.Unlock()
	if err := h.requestSnapshot(a); err != nil {
		t.Fatal(err)
	}
	id := <-s.requests
	if err := h.requestSnapshot(a); err != nil {
		t.Fatal(err)
	}
	if len(s.requests) != 0 {
		t.Fatal("duplicate snapshot request was not coalesced")
	}
	large := bytes.Repeat([]byte("snapshot"), maxFramePayload/8+100)
	s.out <- session.Output{Pane: "%0", Data: []byte("before")}
	s.out <- session.Output{Pane: "%0", Data: large, Cols: 80, Rows: 24, SnapshotID: id}
	s.out <- session.Output{Pane: "%0", Data: []byte("after")}
	read := func(sub *subscriber, n int) []byte {
		var data []byte
		for i := 0; i < n; i++ {
			select {
			case frame := <-sub.ch:
				op, _, payload, _ := decodeFrame(frame)
				if op == opOutput {
					data = append(data, payload...)
				}
			case <-time.After(time.Second):
				t.Fatal("missing ordered frame")
			}
		}
		return data
	}
	// A gets the atomic size + multi-frame snapshot, then continuation. B only
	// gets original live bytes; another viewer's snapshot never overwrites it.
	if got := read(a, 4); !bytes.Equal(got, append(append([]byte{}, large...), []byte("after")...)) {
		t.Fatal("snapshot interleaved with live output")
	}
	if got := read(b, 2); string(got) != "beforeafter" {
		t.Fatalf("other viewer received snapshot: %q", got)
	}
}
