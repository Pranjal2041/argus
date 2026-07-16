package labsvc

import (
	"fmt"
	"time"
)

// RunSummary is the one-line view of a run used by the brief and the hub.
type RunSummary struct {
	ID         string `json:"id"`
	Group      string `json:"group,omitempty"`
	Tier       string `json:"tier,omitempty"`
	Status     string `json:"status"`
	Started    string `json:"started,omitempty"`
	StoppedAt  string `json:"stoppedAt,omitempty"`
	StopReason string `json:"stopReason,omitempty"`
	Latest     string `json:"latest,omitempty"`
	LatestAt   string `json:"latestAt,omitempty"`
	ExitCode   int    `json:"exitCode"`
	Archived   bool   `json:"archived,omitempty"`
}

// BriefData is everything `ut lab brief` prints and everything the hub needs
// for a set overview: the applicable human notes in scope order, the set's
// own events, and one summary per run. It is assembled fresh from the store
// on every call; there is no cached state to go stale.
type BriefData struct {
	Set       SetMeta      `json:"set"`
	Policy    string       `json:"policy"`
	Notes     []Event      `json:"notes,omitempty"`
	SetEvents []Event      `json:"setEvents,omitempty"`
	Runs      []RunSummary `json:"runs,omitempty"`
	Archived  bool         `json:"archived,omitempty"`
}

// Brief assembles the agent-facing view of a set. agentView drops hidden
// content; the hub passes false to see everything.
func (s *Store) Brief(set string, agentView bool) (BriefData, error) {
	meta, err := s.Meta(set)
	if err != nil {
		return BriefData{}, err
	}
	b := BriefData{Set: meta, Policy: s.Policy(set)}
	for _, dir := range []string{
		s.NotesDir("global"),
		s.NotesDir("project", meta.Project),
		s.NotesDir("machine", meta.Machine),
	} {
		evs, _ := s.Events(dir, agentView)
		b.Notes = append(b.Notes, evs...)
	}
	b.SetEvents, _ = s.Events(s.SetDir(set), agentView)
	// the latest human archive event decides the set's view-state
	for _, e := range b.SetEvents {
		if e.Kind == "archive" {
			if v, ok := e.Data["archived"].(bool); ok {
				b.Archived = v
			}
		}
	}
	runs, _ := s.Runs(set)
	for _, r := range runs {
		sum, _, err := s.RunSummary(set, r, agentView)
		if err == nil {
			b.Runs = append(b.Runs, sum)
		}
	}
	return b, nil
}

// RunSummary folds a run's events into its one-line summary and also returns
// the events for callers that want the detail.
func (s *Store) RunSummary(set, run string, agentView bool) (RunSummary, []Event, error) {
	evs, err := s.Events(s.RunDir(set, run), agentView)
	if err != nil {
		return RunSummary{}, nil, err
	}
	sum := RunSummary{ID: run, Status: "recorded", ExitCode: -1}
	var proposed, decided, approved, started bool
	terminal := ""
	for _, e := range evs {
		switch e.Kind {
		case "proposal":
			proposed = true
			if v, ok := e.Data["tier"].(string); ok {
				sum.Tier = v
			}
			if v, ok := e.Data["group"].(string); ok {
				sum.Group = v
			}
		case "decision":
			decided = true
			if v, ok := e.Data["approve"].(bool); ok {
				approved = v
			}
		case "run-start":
			started = true
			terminal = ""
			sum.ExitCode = -1
			sum.StoppedAt = ""
			sum.StopReason = ""
			sum.Started = e.Time
			if v, ok := e.Data["tier"].(string); ok {
				sum.Tier = v
			}
			if v, ok := e.Data["group"].(string); ok {
				sum.Group = v
			}
		case "run-end":
			terminal = "run-end"
			sum.StoppedAt = ""
			sum.StopReason = ""
			if v, ok := e.Data["exit"].(float64); ok {
				sum.ExitCode = int(v)
			}
		case "run-stop":
			terminal = "run-stop"
			sum.ExitCode = -1
			sum.StoppedAt = e.Time
			sum.StopReason = e.Text
		case "result", "note":
			if e.Text != "" {
				sum.Latest = e.Text
				sum.LatestAt = e.Time
			}
		case "archive":
			if v, ok := e.Data["archived"].(bool); ok {
				sum.Archived = v
			}
		}
	}
	switch {
	case terminal == "run-end" && sum.ExitCode == 0:
		sum.Status = "done"
	case terminal == "run-end":
		sum.Status = fmt.Sprintf("failed (exit %d)", sum.ExitCode)
	case terminal == "run-stop":
		sum.Status = "stopped"
	case started:
		sum.Status = "running"
		if t, err := time.Parse(time.RFC3339, sum.Started); err == nil {
			d := time.Since(t).Round(time.Minute)
			h, m := int(d.Hours()), int(d.Minutes())%60
			label := fmt.Sprintf("%dm", m)
			if h > 0 {
				label = fmt.Sprintf("%dh %02dm", h, m)
			}
			sum.Status = "running (" + label + ")"
		}
	case decided && approved:
		sum.Status = "approved (launch with --proposal " + run + ")"
	case decided:
		sum.Status = "denied"
	case proposed:
		sum.Status = "proposed (awaiting approval)"
	}
	return sum, evs, nil
}
