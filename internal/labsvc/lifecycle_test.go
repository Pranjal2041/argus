package labsvc

import (
	"strings"
	"testing"
)

func TestMarkRunStoppedLifecycle(t *testing.T) {
	st := testStore(t)
	key, err := st.CreateKeyRequest("orphaned-job", t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	key, err = st.Decide(key.Key[:8], true, "", "")
	if err != nil {
		t.Fatal(err)
	}
	run, err := st.NewRun(key.Set)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Append(st.RunDir(key.Set, run), Event{
		Author: "machine", Kind: "run-start", Data: map[string]any{"tier": "full"},
	}); err != nil {
		t.Fatal(err)
	}

	reason := "The wrapper disappeared during a node reset; the remote job was checked and is no longer running."
	if err := st.MarkRunStopped(key.Set, run, "  "+reason+"  "); err != nil {
		t.Fatal(err)
	}
	summary, events, err := st.RunSummary(key.Set, run, false)
	if err != nil {
		t.Fatal(err)
	}
	if summary.Status != "stopped" || summary.ExitCode != -1 || summary.StopReason != reason || summary.StoppedAt == "" {
		t.Fatalf("manual stop was not folded honestly: %+v", summary)
	}
	last := events[len(events)-1]
	if last.Kind != "run-stop" || last.Author != "human" || last.Text != reason {
		t.Fatalf("wrong lifecycle event: %+v", last)
	}
	if err := st.SetArchived(key.Set, run, true); err != nil {
		t.Fatal(err)
	}
	summary, _, _ = st.RunSummary(key.Set, run, false)
	if summary.Status != "stopped" || !summary.Archived {
		t.Fatalf("archive view-state changed lifecycle: %+v", summary)
	}
	if err := st.MarkRunStopped(key.Set, run, "duplicate"); err == nil || !strings.Contains(err.Error(), "already") {
		t.Fatalf("duplicate stop should fail, got %v", err)
	}

	// If the original wrapper eventually reports a mechanical outcome, it is
	// stronger evidence and supersedes the human correction.
	if _, err := st.Append(st.RunDir(key.Set, run), Event{
		Author: "machine", Kind: "run-end", Data: map[string]any{"exit": float64(0)},
	}); err != nil {
		t.Fatal(err)
	}
	summary, _, _ = st.RunSummary(key.Set, run, false)
	if summary.Status != "done" || summary.ExitCode != 0 || summary.StopReason != "" || summary.StoppedAt != "" {
		t.Fatalf("real run-end did not supersede manual stop: %+v", summary)
	}
}

func TestMarkRunStoppedValidation(t *testing.T) {
	st := testStore(t)
	key, _ := st.CreateKeyRequest("validation", t.TempDir(), "")
	key, _ = st.Decide(key.Key[:8], true, "", "")
	run, _ := st.NewRun(key.Set)

	checks := []struct {
		name   string
		set    string
		run    string
		reason string
	}{
		{"empty reason", key.Set, run, "  "},
		{"missing run", key.Set, "R99", "verified stopped"},
		{"missing run id", key.Set, "", "verified stopped"},
		{"not started", key.Set, run, "verified stopped"},
		{"reason too long", key.Set, run, strings.Repeat("x", MaxStopReasonRunes+1)},
	}
	for _, check := range checks {
		t.Run(check.name, func(t *testing.T) {
			if err := st.MarkRunStopped(check.set, check.run, check.reason); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}

	ended, _ := st.NewRun(key.Set)
	st.Append(st.RunDir(key.Set, ended), Event{Author: "machine", Kind: "run-start"})
	st.Append(st.RunDir(key.Set, ended), Event{Author: "machine", Kind: "run-end", Data: map[string]any{"exit": float64(1)}})
	if err := st.MarkRunStopped(key.Set, ended, "verified stopped"); err == nil || !strings.Contains(err.Error(), "already ended") {
		t.Fatalf("ended run should reject manual stop, got %v", err)
	}
}
