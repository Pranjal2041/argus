package broker

import (
	"context"
	"testing"

	"universal-tmux/internal/session"
)

type warmProvider struct {
	exists      bool
	createCalls int
	dialCalls   int
}

func (p *warmProvider) List() []session.Info { return nil }
func (p *warmProvider) Create(string, string) error {
	p.createCalls++
	p.exists = true
	return nil
}
func (p *warmProvider) Kill(string) error                           { return nil }
func (p *warmProvider) Rename(string, string) error                 { return nil }
func (p *warmProvider) Has(string) bool                             { return p.exists }
func (p *warmProvider) SetHistoryLimit(int)                         {}
func (p *warmProvider) Exec(session.ExecRequest) session.ExecResult { return session.ExecResult{} }
func (p *warmProvider) SendText(string, string, bool) error         { return nil }
func (p *warmProvider) Spawn(string, string, string, int) error     { return nil }
func (p *warmProvider) ReapAgents() []string                        { return nil }
func (p *warmProvider) Dial(context.Context, string) (session.Session, error) {
	p.dialCalls++
	out := make(chan session.Output)
	close(out)
	return &warmSession{out: out}, nil
}

type warmSession struct {
	out <-chan session.Output
}

func (s *warmSession) Output() <-chan session.Output { return s.out }
func (s *warmSession) SendKeys(string, []byte) error { return nil }
func (s *warmSession) Resize(int, int) error         { return nil }
func (s *warmSession) Size() (int, int)              { return 0, 0 }
func (s *warmSession) Snapshot() []byte              { return nil }
func (s *warmSession) Pane() string                  { return "pane" }
func (s *warmSession) Close()                        {}

func TestWarmExistingDoesNotCreateMissingFallback(t *testing.T) {
	p := &warmProvider{}
	m := &Manager{ctx: context.Background(), prov: p, hubs: map[string]*sessionHub{}}

	if err := m.WarmExisting("universal_tmux"); err != nil {
		t.Fatalf("WarmExisting missing fallback: %v", err)
	}
	if p.exists || p.createCalls != 0 || p.dialCalls != 0 {
		t.Fatalf("missing fallback was mutated: exists=%v createCalls=%d dialCalls=%d", p.exists, p.createCalls, p.dialCalls)
	}
}

func TestWarmExistingAttachesExistingFallback(t *testing.T) {
	p := &warmProvider{exists: true}
	m := &Manager{ctx: context.Background(), prov: p, hubs: map[string]*sessionHub{}}

	if err := m.WarmExisting("universal_tmux"); err != nil {
		t.Fatalf("WarmExisting existing fallback: %v", err)
	}
	if p.createCalls != 0 || p.dialCalls != 1 {
		t.Fatalf("existing fallback calls: create=%d dial=%d, want create=0 dial=1", p.createCalls, p.dialCalls)
	}
}
