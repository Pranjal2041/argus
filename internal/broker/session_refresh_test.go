package broker

import (
	"context"
	"errors"
	"sort"
	"sync"
	"testing"

	"universal-tmux/internal/session"
)

type tieredRefreshProvider struct {
	warmProvider
	inventory    []session.Info
	inventoryErr error
	states       map[string]string
	mu           sync.Mutex
	detected     []string
}

func (p *tieredRefreshProvider) List() []session.Info {
	return append([]session.Info(nil), p.inventory...)
}

func (p *tieredRefreshProvider) ListInventory(ctx context.Context) ([]session.Info, error) {
	if _, ok := ctx.Deadline(); !ok {
		panic("inventory must have a deadline")
	}
	return append([]session.Info(nil), p.inventory...), p.inventoryErr
}

func TestInventoryFailureRetainsSessionsAndLaterRefreshRecovers(t *testing.T) {
	p := &tieredRefreshProvider{inventoryErr: errors.New("backend lookup timed out")}
	m := &Manager{
		prov: p, hidden: map[string]bool{}, history: map[string]*SessionHistory{},
		sessCache: []session.Info{{Name: "existing", ID: "$1", State: "working"}},
	}
	m.refreshSessions(false)
	if got := m.Sessions(); len(got) != 1 || got[0].Name != "existing" || got[0].State != "working" {
		t.Fatalf("failed lookup erased existing sessions: %#v", got)
	}
	p.inventoryErr = nil
	p.inventory = []session.Info{{Name: "existing", ID: "$1"}, {Name: "restored", ID: "$2"}}
	m.refreshSessions(false)
	if got := m.Sessions(); len(got) != 2 || got[1].Name != "restored" {
		t.Fatalf("successful retry did not publish restored session: %#v", got)
	}
	p.inventory = nil
	m.refreshSessions(false)
	if got := m.Sessions(); len(got) != 0 {
		t.Fatalf("successful empty inventory retained deleted sessions: %#v", got)
	}
}

func (p *tieredRefreshProvider) DetectState(name string) string {
	p.mu.Lock()
	p.detected = append(p.detected, name)
	p.mu.Unlock()
	return p.states[name]
}

func (p *tieredRefreshProvider) takeDetected() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := append([]string(nil), p.detected...)
	p.detected = nil
	sort.Strings(out)
	return out
}

func TestTieredRefreshClassifiesForegroundAndPreservesBackgroundState(t *testing.T) {
	p := &tieredRefreshProvider{
		inventory: []session.Info{
			{Name: "visible", ID: "$1"},
			{Name: "hidden", ID: "$2"},
			{Name: "agent", ID: "$3", Agent: true},
		},
		states: map[string]string{"visible": "working", "hidden": "idle", "agent": "idle"},
	}
	m := &Manager{
		prov:    p,
		hidden:  map[string]bool{"hidden": true},
		history: map[string]*SessionHistory{},
		sessCache: []session.Info{
			{Name: "visible", ID: "$1", State: "idle"},
			{Name: "hidden", ID: "$2", State: "waiting"},
			{Name: "agent", ID: "$3", Agent: true, State: "working"},
		},
	}

	m.refreshSessions(false)
	if got := p.takeDetected(); len(got) != 1 || got[0] != "visible" {
		t.Fatalf("foreground detected %v, want [visible]", got)
	}
	byName := map[string]string{}
	for _, info := range m.Sessions() {
		byName[info.Name] = info.State
	}
	if byName["visible"] != "working" || byName["hidden"] != "waiting" || byName["agent"] != "working" {
		t.Fatalf("foreground states = %v; background states were not preserved", byName)
	}

	m.refreshSessions(true)
	if got := p.takeDetected(); len(got) != 3 || got[0] != "agent" || got[1] != "hidden" || got[2] != "visible" {
		t.Fatalf("background detected %v, want [agent hidden visible]", got)
	}
}
