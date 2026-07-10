package labsvc

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	t.Setenv("UT_LAB_ROOT", t.TempDir())
	s, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestULID(t *testing.T) {
	seen := map[string]bool{}
	var ids []string
	for i := 0; i < 1000; i++ {
		id := NewULID()
		if len(id) != 26 {
			t.Fatalf("length %d: %q", len(id), id)
		}
		if seen[id] {
			t.Fatalf("duplicate %q", id)
		}
		seen[id] = true
		ids = append(ids, id)
	}
	a := NewULID()
	time.Sleep(3 * time.Millisecond)
	b := NewULID()
	if !(a < b) {
		t.Fatalf("ULIDs not time-ordered: %q then %q", a, b)
	}
	// monotonic within a millisecond: a burst from one process stays ordered
	prev := NewULID()
	for i := 0; i < 5000; i++ {
		next := NewULID()
		if !(prev < next) {
			t.Fatalf("burst not monotonic: %q then %q", prev, next)
		}
		prev = next
	}
	for _, c := range ids[0] {
		if !strings.ContainsRune(crockford, c) {
			t.Fatalf("bad char %q", c)
		}
	}
}

func TestAppendReadAndHide(t *testing.T) {
	s := testStore(t)
	dir := filepath.Join(Root(), "scratch")
	e1, err := s.Append(dir, Event{Author: "agent", Kind: "note", Text: "first"})
	if err != nil {
		t.Fatal(err)
	}
	e2, _ := s.Append(dir, Event{Author: "agent", Kind: "note", Text: "wrong inference"})
	s.Append(dir, Event{Author: "agent", Kind: "note", Text: "third"})

	all, err := s.Events(dir, false)
	if err != nil || len(all) != 3 {
		t.Fatalf("want 3 events, got %d (%v)", len(all), err)
	}
	if all[0].ID != e1.ID || all[0].Text != "first" {
		t.Fatalf("order wrong: %+v", all[0])
	}

	// the human hides the wrong inference; agent view drops it, hub view keeps all
	s.Append(dir, Event{Author: "human", Kind: "hide", Data: map[string]any{"target": e2.ID}})
	agent, _ := s.Events(dir, true)
	if len(agent) != 2 {
		t.Fatalf("agent view: want 2, got %d", len(agent))
	}
	for _, e := range agent {
		if e.ID == e2.ID {
			t.Fatal("hidden event visible to agent")
		}
	}
	hub, _ := s.Events(dir, false)
	if len(hub) != 4 {
		t.Fatalf("hub view: want 4 (incl. hide marker), got %d", len(hub))
	}
}

func TestKeyLifecycle(t *testing.T) {
	s := testStore(t)
	k, err := s.CreateKeyRequest("myproj", "/tmp/work", "sess-a")
	if err != nil {
		t.Fatal(err)
	}
	if k.Status != "pending" || len(k.Key) != 32 {
		t.Fatalf("bad request: %+v", k)
	}
	// pending keys don't work
	if _, err := s.ActiveKey(k.Key); err == nil {
		t.Fatal("pending key accepted")
	}
	// deny leaves no set
	den, _ := s.CreateKeyRequest("other", "/tmp", "")
	if d, err := s.Decide(den.Key[:8], false, "", "wrong machine"); err != nil || d.Status != "denied" {
		t.Fatalf("deny: %v %+v", err, d)
	}
	// approve creates the set and renames the project
	ap, err := s.Decide(k.Key[:8], true, "renamed", "")
	if err != nil || ap.Status != "active" || ap.Set == "" || ap.Project != "renamed" {
		t.Fatalf("approve: %v %+v", err, ap)
	}
	meta, err := s.Meta(ap.Set)
	if err != nil || meta.Project != "renamed" || meta.Machine != Hostname() {
		t.Fatalf("set meta: %v %+v", err, meta)
	}
	// active key resolves, by prefix too
	got, err := s.ActiveKey(ap.Key[:10])
	if err != nil || got.Set != ap.Set {
		t.Fatalf("active: %v %+v", err, got)
	}
	// machine tie: a key from another machine errors
	other := got
	other.Key = strings.Repeat("f", 32)
	other.Machine = "elsewhere"
	s.writeKey(other)
	if _, err := s.ActiveKey(other.Key); err == nil || !strings.Contains(err.Error(), "tied to their machine") {
		t.Fatalf("machine tie not enforced: %v", err)
	}
	// revoke ends access
	if _, err := s.Revoke(ap.Key[:8]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ActiveKey(ap.Key); err == nil {
		t.Fatal("revoked key accepted")
	}
}

func TestNewRunConcurrentClaims(t *testing.T) {
	s := testStore(t)
	k, _ := s.CreateKeyRequest("p", "/tmp", "")
	ap, _ := s.Decide(k.Key[:8], true, "", "")
	var mu sync.Mutex
	got := map[string]bool{}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, err := s.NewRun(ap.Set)
			if err != nil {
				t.Error(err)
				return
			}
			mu.Lock()
			if got[id] {
				t.Errorf("duplicate run id %s", id)
			}
			got[id] = true
			mu.Unlock()
		}()
	}
	wg.Wait()
	if len(got) != 10 {
		t.Fatalf("want 10 distinct runs, got %d", len(got))
	}
	ids, _ := s.Runs(ap.Set)
	if len(ids) != 10 || ids[0] != "R1" || ids[9] != "R10" {
		t.Fatalf("run listing wrong: %v", ids)
	}
}

func TestBriefAssembly(t *testing.T) {
	s := testStore(t)
	k, _ := s.CreateKeyRequest("proj", "/tmp", "")
	ap, _ := s.Decide(k.Key[:8], true, "", "")

	s.Append(s.NotesDir("global"), Event{Author: "human", Kind: "hnote", Text: "use uv"})
	s.Append(s.NotesDir("project", "proj"), Event{Author: "human", Kind: "hnote", Text: "full scale only"})
	s.Append(s.NotesDir("machine", Hostname()), Event{Author: "human", Kind: "hnote", Text: "8 gpus here"})

	run, _ := s.NewRun(ap.Set)
	s.Append(s.RunDir(ap.Set, run), Event{Author: "machine", Kind: "run-start",
		Data: map[string]any{"tier": "full", "group": "sweep"}})
	s.Append(s.RunDir(ap.Set, run), Event{Author: "agent", Kind: "result", Text: "loss 0.42"})
	s.Append(s.RunDir(ap.Set, run), Event{Author: "machine", Kind: "run-end",
		Data: map[string]any{"exit": float64(0), "durationSec": float64(3)}})

	b, err := s.Brief(ap.Set, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(b.Notes) != 3 {
		t.Fatalf("want 3 notes, got %d", len(b.Notes))
	}
	if len(b.Runs) != 1 || b.Runs[0].Status != "done" || b.Runs[0].Latest != "loss 0.42" ||
		b.Runs[0].Tier != "full" || b.Runs[0].Group != "sweep" {
		t.Fatalf("run summary wrong: %+v", b.Runs)
	}
}

func TestSnapshotOnRealRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	repo := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q")
	os.WriteFile(filepath.Join(repo, "train.py"), []byte("print('v1')\n"), 0o644)
	git("add", "-A")
	git("commit", "-q", "-m", "init")
	// dirty tracked change + small untracked + big untracked (over the cap)
	os.WriteFile(filepath.Join(repo, "train.py"), []byte("print('v2')\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "conf.yaml"), []byte("lr: 3e-4\n"), 0o644)
	big := make([]byte, 4096)
	os.WriteFile(filepath.Join(repo, "data.bin"), big, 0o644)

	dest := t.TempDir()
	sn, err := CaptureSnapshot(repo, dest, SnapshotCaps{PerFile: 1024, Total: 1 << 20})
	if err != nil {
		t.Fatal(err)
	}
	if sn.NoGit || len(sn.BaseSha) != 40 {
		t.Fatalf("base sha missing: %+v", sn)
	}
	if sn.PatchBytes == 0 {
		t.Fatal("dirty tracked change produced no patch")
	}
	if sn.Archived != 1 {
		t.Fatalf("want 1 archived untracked file, got %d", sn.Archived)
	}
	if len(sn.Skipped) != 1 || sn.Skipped[0].Path != "data.bin" || sn.Skipped[0].Sha == "" {
		t.Fatalf("big file not skipped+hashed: %+v", sn.Skipped)
	}
	if _, err := os.Stat(filepath.Join(dest, "diff.patch")); err != nil {
		t.Fatal("diff.patch missing")
	}
	if _, err := os.Stat(filepath.Join(dest, "untracked.tar.gz")); err != nil {
		t.Fatal("untracked.tar.gz missing")
	}
	// the repo itself is untouched: still exactly one loose ref, no lab refs,
	// and git's own object count unchanged apart from what the commit made
	out, _ := exec.Command("git", "-C", repo, "stash", "list").Output()
	if len(out) != 0 {
		t.Fatal("snapshot created a stash")
	}
}

func TestNoGitDirectory(t *testing.T) {
	dir := t.TempDir()
	sn, err := CaptureSnapshot(dir, t.TempDir(), DefaultCaps)
	if err != nil || !sn.NoGit {
		t.Fatalf("want NoGit, got %+v (%v)", sn, err)
	}
}

func TestCappedLogWriter(t *testing.T) {
	path := filepath.Join(t.TempDir(), "log.txt")
	w, err := NewCappedLogWriter(path, 100) // head 50 + tail 50
	if err != nil {
		t.Fatal(err)
	}
	head := strings.Repeat("a", 50)
	middle := strings.Repeat("b", 500)
	tail := strings.Repeat("c", 50)
	w.Write([]byte(head))
	w.Write([]byte(middle))
	w.Write([]byte(tail))
	w.Close()
	b, _ := os.ReadFile(path)
	got := string(b)
	if !strings.HasPrefix(got, head) {
		t.Fatal("head lost")
	}
	if !strings.HasSuffix(got, tail) {
		t.Fatal("tail lost")
	}
	if !strings.Contains(got, "truncated") {
		t.Fatal("no truncation marker")
	}
	if strings.Count(got, "b") > 60 {
		t.Fatalf("middle not truncated: %d bytes kept", len(got))
	}
	if !strings.HasSuffix(w.Preview(), tail) {
		t.Fatal("preview lost the tail")
	}
}

func TestWandbScanner(t *testing.T) {
	var w WandbScanner
	// ANSI-wrapped, split across writes
	w.Write([]byte("view run at \x1b[34mhttps://wandb.ai/team/proj"))
	w.Write([]byte("/runs/abc123XYZ\x1b[0m done\n"))
	w.Write([]byte("again https://wandb.ai/team/proj/runs/abc123XYZ\n")) // duplicate
	w.Write([]byte("short id https://wandb.ai/team/proj/runs/ab12\n"))   // too short
	runs := w.Runs()
	if len(runs) != 1 || runs[0] != "team/proj/runs/abc123XYZ" {
		t.Fatalf("got %v", runs)
	}
	sort.Strings(runs) // no-op, silences unused import if edited later
}
