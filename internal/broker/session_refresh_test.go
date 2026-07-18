package broker

import (
	"sort"
	"sync"
	"testing"

	"universal-tmux/internal/session"
)

type tieredRefreshProvider struct {
	warmProvider
	inventory []session.Info
	states    map[string]string
	mu        sync.Mutex
	detected  []string
}

func (p *tieredRefreshProvider) List() []session.Info {
	return append([]session.Info(nil), p.inventory...)
}

func (p *tieredRefreshProvider) ListInventory() []session.Info {
	return append([]session.Info(nil), p.inventory...)
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
