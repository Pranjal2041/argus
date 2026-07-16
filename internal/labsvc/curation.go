package labsvc

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// MaxStopReasonRunes keeps the human lifecycle note useful in compact Lab
// surfaces while still leaving ample room for an honest explanation.
const MaxStopReasonRunes = 1000

// Hide appends a human "hide" event next to the target event, which removes
// the target from agent-facing reads and default hub views. Nothing is ever
// deleted: the bytes stay, and the hide itself is a recorded event
// (LAB-DESIGN.md rule 3). The target may live on the set itself or on any of
// its runs; Hide finds it.
func (s *Store) Hide(set, target string) error {
	dir, err := s.findEventDir(set, target)
	if err != nil {
		return err
	}
	_, err = s.Append(dir, Event{Author: "human", Kind: "hide",
		Data: map[string]any{"target": target}})
	return err
}

// findEventDir locates the directory whose events/ contains the given id.
func (s *Store) findEventDir(set, id string) (string, error) {
	if _, err := os.Stat(filepath.Join(s.SetDir(set), "events", id+".json")); err == nil {
		return s.SetDir(set), nil
	}
	runs, _ := s.Runs(set)
	for _, r := range runs {
		if _, err := os.Stat(filepath.Join(s.RunDir(set, r), "events", id+".json")); err == nil {
			return s.RunDir(set, r), nil
		}
	}
	return "", fmt.Errorf("no event %s in set %s", id, set)
}

// HumanNote appends a human-authored note at any scope. This is the write
// path behind the hub's notes editor and `ut lab hnote`; only human surfaces
// call it.
func (s *Store) HumanNote(scope, project, set, run, text string) error {
	var dir string
	switch scope {
	case "global":
		dir = s.NotesDir("global")
	case "project":
		if project == "" {
			return fmt.Errorf("project scope needs a project name")
		}
		dir = s.NotesDir("project", project)
	case "machine":
		dir = s.NotesDir("machine", Hostname())
	case "set":
		if set == "" {
			return fmt.Errorf("set scope needs a set id")
		}
		dir = s.SetDir(set)
	case "run":
		if set == "" || run == "" {
			return fmt.Errorf("run scope needs a set id and a run id")
		}
		dir = s.RunDir(set, run)
	default:
		return fmt.Errorf("unknown scope %q", scope)
	}
	if scope == "set" || scope == "run" {
		if _, err := os.Stat(dir); err != nil {
			return fmt.Errorf("no such %s", scope)
		}
	}
	_, err := s.Append(dir, Event{Author: "human", Kind: "hnote", Text: text})
	return err
}

// NoteInfo is one note from a scope-level notes directory (global, this
// machine, or a project), labeled for the hub's Notes view.
type NoteInfo struct {
	Scope   string `json:"scope"`             // global | machine | project
	Project string `json:"project,omitempty"` // set when scope is "project"
	ID      string `json:"id"`
	Time    string `json:"time"`
	Author  string `json:"author"`
	Text    string `json:"text"`
	Hidden  bool   `json:"hidden"`
}

// ListNotes returns every note in the store's scope-level notes directories
// (global, this machine, each known project) in event order. Hidden notes are
// included and flagged rather than dropped: the human sees what they hid,
// agents never see them at all (their reads use agentView).
func (s *Store) ListNotes() ([]NoteInfo, error) {
	type src struct{ scope, project, dir string }
	srcs := []src{
		{"global", "", s.NotesDir("global")},
		{"machine", "", s.NotesDir("machine", Hostname())},
	}
	metas, _ := s.Sets()
	seen := map[string]bool{}
	for _, m := range metas {
		if m.Project != "" && !seen[m.Project] {
			seen[m.Project] = true
			srcs = append(srcs, src{"project", m.Project, s.NotesDir("project", m.Project)})
		}
	}
	out := []NoteInfo{}
	for _, sc := range srcs {
		evs, err := s.Events(sc.dir, false)
		if err != nil {
			return nil, err
		}
		hidden := map[string]bool{}
		for _, e := range evs {
			if e.Kind == "hide" {
				if t, ok := e.Data["target"].(string); ok {
					hidden[t] = true
				}
			}
		}
		for _, e := range evs {
			if e.Kind != "note" && e.Kind != "hnote" {
				continue
			}
			out = append(out, NoteInfo{Scope: sc.scope, Project: sc.project,
				ID: e.ID, Time: e.Time, Author: e.Author, Text: e.Text, Hidden: hidden[e.ID]})
		}
	}
	return out, nil
}

// HideNote hides a note living in a scope-level notes directory (set/run
// events go through Hide). Same rule as everywhere: nothing is deleted, the
// hide itself is a recorded event.
func (s *Store) HideNote(scope, project, target string) error {
	var dir string
	switch scope {
	case "global":
		dir = s.NotesDir("global")
	case "machine":
		dir = s.NotesDir("machine", Hostname())
	case "project":
		if project == "" {
			return fmt.Errorf("project scope needs a project name")
		}
		dir = s.NotesDir("project", project)
	default:
		return fmt.Errorf("unknown note scope %q", scope)
	}
	if _, err := os.Stat(filepath.Join(dir, "events", target+".json")); err != nil {
		return fmt.Errorf("no note %s in %s notes", target, scope)
	}
	_, err := s.Append(dir, Event{Author: "human", Kind: "hide",
		Data: map[string]any{"target": target}})
	return err
}

// SetArchived flips the archived flag on a set or (when run is non-empty) on
// one run. Archiving is human view-state: a recorded, reversible event, agents
// are unaffected, and nothing is deleted. The latest archive event wins.
func (s *Store) SetArchived(set, run string, archived bool) error {
	dir := s.SetDir(set)
	kind := "set"
	if run != "" {
		dir = s.RunDir(set, run)
		kind = "run"
	}
	if _, err := os.Stat(dir); err != nil {
		return fmt.Errorf("no such %s", kind)
	}
	_, err := s.Append(dir, Event{Author: "human", Kind: "archive",
		Data: map[string]any{"archived": archived}})
	return err
}

// MarkRunStopped records that a human has verified an orphaned run is no
// longer executing. It deliberately does not signal a process and does not
// fabricate a machine-authored run-end: the required reason makes the manual
// lifecycle correction explicit and auditable. A later real run-end remains
// authoritative when it arrives.
func (s *Store) MarkRunStopped(set, run, reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return fmt.Errorf("a reason is required")
	}
	if utf8.RuneCountInString(reason) > MaxStopReasonRunes {
		return fmt.Errorf("reason is too long (maximum %d characters)", MaxStopReasonRunes)
	}
	if run == "" {
		return fmt.Errorf("a run is required")
	}
	dir := s.RunDir(set, run)
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return fmt.Errorf("no such run")
	}
	events, err := s.Events(dir, false)
	if err != nil {
		return err
	}
	started := false
	terminal := ""
	for _, event := range events {
		switch event.Kind {
		case "run-start":
			started = true
			terminal = ""
		case "run-end", "run-stop":
			terminal = event.Kind
		}
	}
	if !started {
		return fmt.Errorf("run has no recorded start")
	}
	switch terminal {
	case "run-end":
		return fmt.Errorf("run has already ended")
	case "run-stop":
		return fmt.Errorf("run is already marked stopped")
	}
	_, err = s.Append(dir, Event{Author: "human", Kind: "run-stop", Text: reason})
	return err
}
