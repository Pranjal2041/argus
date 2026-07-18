package labsvc

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
)

// Policy returns a set's approval policy: "all" (every run needs approval),
// "full-only" (only runs declared full need it), or "none". The value is the
// latest human "policy" event on the set, and the default is full-only, the
// conservative middle (LAB-DESIGN.md, Proposals and approvals).
func (s *Store) Policy(set string) string {
	evs, _ := s.Events(s.SetDir(set), false)
	p := "full-only"
	for _, e := range evs {
		if e.Kind == "policy" {
			if v, ok := e.Data["policy"].(string); ok && v != "" {
				p = v
			}
		}
	}
	return p
}

// ValidPolicy names the accepted policy values.
func ValidPolicy(p string) bool { return p == "all" || p == "full-only" || p == "none" }

// SetPolicy appends a human policy event (latest wins).
func (s *Store) SetPolicy(set, policy string) error {
	_, err := s.Append(s.SetDir(set), Event{Author: "human", Kind: "policy",
		Text: "policy set to " + policy, Data: map[string]any{"policy": policy}})
	return err
}

// Proposal is a gated run waiting for the human. It lives as a "proposal"
// event on the claimed run; the decision is a later "decision" event.
type Proposal struct {
	Set     string   `json:"set"`
	Run     string   `json:"run"`
	Project string   `json:"project"`
	Machine string   `json:"machine"`
	Intent  string   `json:"intent"`
	Tier    string   `json:"tier,omitempty"`
	Group   string   `json:"group,omitempty"`
	Argv    []string `json:"argv,omitempty"`
	Cwd     string   `json:"cwd,omitempty"`
	Created string   `json:"created"`
}

// PendingProposals scans every set on this store for proposals that have no
// decision and were not launched yet.
func (s *Store) PendingProposals() ([]Proposal, error) {
	sets, err := s.Sets()
	if err != nil {
		return nil, err
	}
	var out []Proposal
	for _, m := range sets {
		runs, _ := s.Runs(m.ID)
		for _, r := range runs {
			evs, _ := s.Events(s.RunDir(m.ID, r), false)
			var prop *Event
			decided, launched := false, false
			for i := range evs {
				switch evs[i].Kind {
				case "proposal":
					prop = &evs[i]
				case "decision":
					decided = true
				case "run-start":
					launched = true
				}
			}
			if prop == nil || decided || launched {
				continue
			}
			p := Proposal{Set: m.ID, Run: r, Project: m.Project, Machine: m.Machine,
				Intent: prop.Text, Created: prop.Time}
			// The set machine is only its key-request origin. A proposal may be
			// filed from any node mounting the store, so prefer its run envelope.
			if v, ok := prop.Data["machine"].(string); ok && v != "" {
				p.Machine = v
			}
			if v, ok := prop.Data["tier"].(string); ok {
				p.Tier = v
			}
			if v, ok := prop.Data["group"].(string); ok {
				p.Group = v
			}
			if vs, ok := prop.Data["argv"].([]any); ok {
				for _, v := range vs {
					if sv, ok := v.(string); ok {
						p.Argv = append(p.Argv, sv)
					}
				}
			}
			if v, ok := prop.Data["cwd"].(string); ok {
				p.Cwd = v
			}
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created < out[j].Created })
	return out, nil
}

// RunDecision reports whether a run's proposal has been decided, and how.
func (s *Store) RunDecision(set, run string) (decided, approved bool, note string) {
	evs, _ := s.Events(s.RunDir(set, run), false)
	for _, e := range evs {
		if e.Kind == "decision" {
			decided = true
			if v, ok := e.Data["approve"].(bool); ok {
				approved = v
			}
			note = e.Text
		}
	}
	return
}

// DecideRun records the human's decision on a proposal.
func (s *Store) DecideRun(set, run string, approve bool, note string) error {
	runDir := s.RunDir(set, run)
	if _, err := os.Stat(runDir); err != nil {
		return err
	}
	events, err := s.Events(runDir, false)
	if err != nil {
		return err
	}
	proposed := false
	for _, event := range events {
		switch event.Kind {
		case "proposal":
			proposed = true
		case "decision":
			return errors.New("run proposal already has a decision")
		case "run-start":
			return errors.New("run has already started")
		}
	}
	if !proposed {
		return fmt.Errorf("run %s has no proposal", run)
	}
	_, err = s.Append(runDir, Event{Author: "human", Kind: "decision",
		Text: note, Data: map[string]any{"approve": approve}})
	return err
}

// BindHash ties an approval to exactly what was approved: the base commit,
// the uncommitted patch, and the params files. The launch step recomputes it
// via CurrentBind and refuses to start on a mismatch (LAB-DESIGN.md).
func BindHash(baseSha string, patch []byte, paramShas []string) string {
	h := sha256.New()
	h.Write([]byte(baseSha + "\n"))
	h.Write(patch)
	h.Write([]byte("\n"))
	sorted := append([]string(nil), paramShas...)
	sort.Strings(sorted)
	h.Write([]byte(strings.Join(sorted, "\n")))
	return hex.EncodeToString(h.Sum(nil))
}

// CurrentBind computes the bind hash from the working tree as it is right
// now: the current commit, the current uncommitted patch, and the params
// files re-hashed. Used at proposal time and again at launch time.
func CurrentBind(cwd string, paramPaths []string) (string, error) {
	base := ""
	var patch []byte
	if shaB, err := gitRO(cwd, "rev-parse", "HEAD"); err == nil {
		base = strings.TrimSpace(string(shaB))
		patch, _ = gitRO(cwd, "diff", "--binary", "HEAD")
	}
	var shas []string
	for _, p := range paramPaths {
		s, err := Sha256File(p)
		if err != nil {
			return "", err
		}
		shas = append(shas, s)
	}
	return BindHash(base, patch, shas), nil
}
