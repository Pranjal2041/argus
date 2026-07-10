package main

// The `ut lab` CLI (LAB-DESIGN.md): the protocol layer agents use to run and
// report experiments. The CLI operates on the local store directly — the
// one-file-per-event format makes concurrent writers safe, so no broker
// round-trip is needed for writes; the broker's /lab routes exist for the hub
// and the phone. Agent verbs can only append; edit and delete do not exist.

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"universal-tmux/internal/labsvc"
)

func cmdLab(args []string) int {
	if len(args) == 0 {
		fmt.Print(labHelp)
		return 2
	}
	verb, rest := args[0], args[1:]
	st, err := labsvc.Open()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	switch verb {
	case "login":
		return labLogin(st, rest)
	case "keys":
		return labKeys(st)
	case "approve":
		return labDecide(st, rest, true)
	case "deny":
		return labDecide(st, rest, false)
	case "revoke":
		return labRevoke(st, rest)
	case "brief":
		return labBrief(st, rest)
	case "show":
		return labShow(st, rest)
	case "run":
		return labRun(st, rest)
	case "proposals":
		return labProposals(st)
	case "grant":
		return labDecideRun(st, rest, true)
	case "reject":
		return labDecideRun(st, rest, false)
	case "policy":
		return labPolicy(st, rest)
	case "hide":
		return labHide(st, rest)
	case "archive":
		return labArchive(st, rest, true)
	case "unarchive":
		return labArchive(st, rest, false)
	case "note":
		return labNote(st, rest, "agent")
	case "hnote":
		return labNote(st, rest, "human")
	case "diff":
		return labDiff(st, rest)
	case "init":
		return labInit(st)
	case "help", "--help", "-h":
		fmt.Print(labHelp)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "ut lab: unknown command %q (try `ut lab help`)\n", verb)
		return 2
	}
}

// --- flag helpers (manual parsing, matching the rest of the mesh CLI) -------

// takeFlag removes "--name value" pairs from args and returns the values.
func takeFlag(args *[]string, name string) []string {
	var vals []string
	out := (*args)[:0]
	i := 0
	for i < len(*args) {
		a := (*args)[i]
		if a == "--" { // everything after -- is the command, leave it alone
			out = append(out, (*args)[i:]...)
			break
		}
		if a == name && i+1 < len(*args) {
			vals = append(vals, (*args)[i+1])
			i += 2
			continue
		}
		out = append(out, a)
		i++
	}
	*args = out
	return vals
}

func oneFlag(args *[]string, name string) string {
	vs := takeFlag(args, name)
	if len(vs) == 0 {
		return ""
	}
	return vs[len(vs)-1]
}

// --- login / keys / approve / deny / revoke ---------------------------------

func labLogin(st *labsvc.Store, args []string) int {
	project := oneFlag(&args, "--project")
	cwd, _ := os.Getwd()
	if project == "" {
		project = filepath.Base(cwd)
	}
	k, err := st.CreateKeyRequest(project, cwd, tmuxSessionName())
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Printf("key request filed (project %q, machine %s).\n", k.Project, k.Machine)
	fmt.Printf("your key: %s\n", k.Key)
	fmt.Printf("export it now so every ut lab command finds it:\n")
	fmt.Printf("  export UT_LAB_KEY=%s\n", k.Key)
	fmt.Printf("the key is inert until the human approves it: ut lab approve %s\n", k.Key[:8])
	return 0
}

func labKeys(st *labsvc.Store) int {
	ks, err := st.Keys()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if len(ks) == 0 {
		fmt.Println("no keys.")
		return 0
	}
	for _, k := range ks {
		set := k.Set
		if set == "" {
			set = "-"
		}
		fmt.Printf("%-8s  %-8s  %-10s  %-14s  %s  %s\n",
			k.Key[:8], k.Status, set, k.Project, k.Machine, k.Cwd)
	}
	return 0
}

func labDecide(st *labsvc.Store, args []string, approve bool) int {
	project := oneFlag(&args, "--project")
	note := oneFlag(&args, "--note")
	policy := oneFlag(&args, "--policy")
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ut lab approve|deny <key-prefix> [--project name] [--policy all|full-only|none] [--note text]")
		return 2
	}
	if policy != "" && !labsvc.ValidPolicy(policy) {
		fmt.Fprintf(os.Stderr, "ut lab: policy must be all, full-only, or none, got %q\n", policy)
		return 2
	}
	k, err := st.Decide(args[0], approve, project, note)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if approve {
		if policy != "" {
			if err := st.SetPolicy(k.Set, policy); err != nil {
				fmt.Fprintf(os.Stderr, "ut lab: set policy: %v\n", err)
				return 1
			}
		}
		fmt.Printf("approved: key %s is active, set %s, project %q, policy %s\n",
			k.Key[:8], k.Set, k.Project, st.Policy(k.Set))
	} else {
		fmt.Printf("denied: key %s\n", k.Key[:8])
	}
	return 0
}

// labPolicy prints or changes a set's approval policy (human verb).
func labPolicy(st *labsvc.Store, args []string) int {
	switch len(args) {
	case 1:
		fmt.Println(st.Policy(args[0]))
		return 0
	case 2:
		if !labsvc.ValidPolicy(args[1]) {
			fmt.Fprintf(os.Stderr, "ut lab: policy must be all, full-only, or none, got %q\n", args[1])
			return 2
		}
		if err := st.SetPolicy(args[0], args[1]); err != nil {
			fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
			return 1
		}
		fmt.Printf("policy of %s is now %s\n", args[0], args[1])
		return 0
	default:
		fmt.Fprintln(os.Stderr, "usage: ut lab policy <set> [all|full-only|none]")
		return 2
	}
}

// labProposals lists every gated run on this store still waiting for the
// human (human verb; the hub reads the same data over /lab/proposals).
func labProposals(st *labsvc.Store) int {
	ps, err := st.PendingProposals()
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if len(ps) == 0 {
		fmt.Println("no pending proposals.")
		return 0
	}
	for _, p := range ps {
		fmt.Printf("%-10s %-5s %-14s %s\n", p.Set, p.Run, p.Project, p.Intent)
		fmt.Printf("           %v\n", p.Argv)
		fmt.Printf("           grant: ut lab grant %s %s   reject: ut lab reject %s %s --note why\n",
			p.Set, p.Run, p.Set, p.Run)
	}
	return 0
}

// labHide (human verb) hides an event from agent-facing reads and default
// hub views. Nothing is deleted; the hide itself is recorded.
func labHide(st *labsvc.Store, args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ut lab hide <set> <event-id>")
		return 2
	}
	if err := st.Hide(args[0], args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Printf("hidden: %s (the bytes stay; agents no longer see it)\n", args[1])
	return 0
}

func labDecideRun(st *labsvc.Store, args []string, approve bool) int {
	note := oneFlag(&args, "--note")
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ut lab grant|reject <set> <run> [--note text]")
		return 2
	}
	if err := st.DecideRun(args[0], args[1], approve, note); err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if approve {
		fmt.Printf("granted: %s %s (the waiting run launches, or the agent resumes with --proposal %s)\n", args[0], args[1], args[1])
	} else {
		fmt.Printf("rejected: %s %s\n", args[0], args[1])
	}
	return 0
}

func labRevoke(st *labsvc.Store, args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ut lab revoke <key-prefix>")
		return 2
	}
	k, err := st.Revoke(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Printf("revoked: key %s (set %s keeps its records)\n", k.Key[:8], k.Set)
	return 0
}

// --- brief / show ------------------------------------------------------------

func labBrief(st *labsvc.Store, args []string) int {
	keyFlag := oneFlag(&args, "--key")
	k, err := st.ActiveKey(keyFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	b, err := st.Brief(k.Set, true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Printf("set %s  project %q  machine %s  cwd %s\n", b.Set.ID, b.Set.Project, b.Set.Machine, b.Set.Cwd)
	switch b.Policy {
	case "all":
		fmt.Println("policy: every run needs the human's approval (file with --intent, wait for the grant)")
	case "full-only":
		fmt.Println("policy: full-only — declare every run with --tier full|quick; full runs need --intent and the human's approval")
	case "none":
		fmt.Println("policy: none — runs start immediately and everything is logged")
	}
	if len(b.Notes) > 0 {
		fmt.Println("\nhuman notes (treat these as ground truth):")
		for _, n := range b.Notes {
			fmt.Printf("  - %s\n", n.Text)
		}
	}
	if len(b.Runs) > 0 {
		fmt.Println("\nruns:")
		for _, r := range b.Runs {
			line := fmt.Sprintf("  %-5s %-22s", r.ID, r.Status)
			if r.Group != "" {
				line += " group=" + r.Group
			}
			if r.Tier != "" {
				line += " tier=" + r.Tier
			}
			if r.Latest != "" {
				line += "  | " + r.Latest
			}
			fmt.Println(line)
		}
	} else {
		fmt.Println("\nno runs yet. run experiments through `ut lab run` (see `ut lab help`).")
	}
	var notes []labsvc.Event
	for _, e := range b.SetEvents {
		if e.Kind == "note" || e.Kind == "hnote" {
			notes = append(notes, e)
		}
	}
	if len(notes) > 0 {
		fmt.Println("\nset notes:")
		for _, e := range notes {
			fmt.Printf("  [%s] %s\n", e.Author, e.Text)
		}
	}
	return 0
}

func labShow(st *labsvc.Store, args []string) int {
	keyFlag := oneFlag(&args, "--key")
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ut lab show <run-id>")
		return 2
	}
	k, err := st.ActiveKey(keyFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	sum, evs, err := st.RunSummary(k.Set, args[0], true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Printf("run %s  status %s\n", sum.ID, sum.Status)
	for _, e := range evs {
		fmt.Printf("\n[%s] %s %s\n", e.Author, e.Time, e.Kind)
		if e.Text != "" {
			fmt.Println(indent(e.Text, "  "))
		}
		for _, kd := range []string{"argv", "exit", "durationSec", "wandb", "drift", "snapshot", "params", "dataFiles"} {
			if v, ok := e.Data[kd]; ok {
				fmt.Printf("  %s: %v\n", kd, v)
			}
		}
	}
	fmt.Printf("\nfiles: %s\n", st.RunDir(k.Set, sum.ID))
	return 0
}

func indent(s, pre string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i := range lines {
		lines[i] = pre + lines[i]
	}
	return strings.Join(lines, "\n")
}

// --- run (the wrapper) --------------------------------------------------------

type fileRef struct {
	Path string `json:"path"`
	Sha  string `json:"sha256"`
}

const runUsage = "usage: ut lab run [--tier full|quick] [--group g] [--intent text] [--params file] [--data-files /abs/path,...] -- <command> [args...]\n" +
	"       ut lab run --proposal <run-id>        launch (or keep waiting for) a filed proposal"

func labRun(st *labsvc.Store, args []string) int {
	keyFlag := oneFlag(&args, "--key")
	tier := oneFlag(&args, "--tier")
	group := oneFlag(&args, "--group")
	intent := oneFlag(&args, "--intent")
	proposal := oneFlag(&args, "--proposal")
	params := takeFlag(&args, "--params")
	var dataFiles []string
	for _, v := range takeFlag(&args, "--data-files") {
		for _, p := range strings.Split(v, ",") {
			if p = strings.TrimSpace(p); p != "" {
				dataFiles = append(dataFiles, p)
			}
		}
	}
	// everything after -- is the command
	sawSep := false
	var cmdArgs []string
	for i, a := range args {
		if a == "--" {
			sawSep = true
			cmdArgs = args[i+1:]
			args = args[:i]
			break
		}
	}
	if len(args) > 0 {
		if !sawSep {
			// the usual miss: the command was given without the separator
			quoted := make([]string, len(args))
			for i, a := range args {
				if strings.ContainsAny(a, " \t;|&<>()$`\"'*?[]#~") {
					quoted[i] = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
				} else {
					quoted[i] = a
				}
			}
			fmt.Fprintf(os.Stderr, "ut lab run: missing the -- separator. Flags come first, then --, then your command.\nRe-run as:\n  ut lab run <your flags> -- %s\n", strings.Join(quoted, " "))
		} else {
			fmt.Fprintf(os.Stderr, "ut lab run: unknown arguments before --: %v\n", args)
		}
		return 2
	}
	k, err := st.ActiveKey(keyFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if proposal != "" {
		if len(cmdArgs) > 0 {
			fmt.Fprintln(os.Stderr, "ut lab run: --proposal launches the recorded command; do not pass a new one")
			return 2
		}
		return labResumeProposal(st, k, proposal)
	}
	if len(cmdArgs) == 0 {
		fmt.Fprintln(os.Stderr, runUsage)
		return 2
	}
	if tier != "" && tier != "full" && tier != "quick" {
		fmt.Fprintf(os.Stderr, "ut lab run: --tier must be full or quick, got %q\n", tier)
		return 2
	}

	// the human's per-set policy decides which runs need approval
	policy := st.Policy(k.Set)
	if policy == "full-only" && tier == "" {
		fmt.Fprintf(os.Stderr, "ut lab run: this set's policy is full-only, so --tier full|quick is required (declare what this run is)\n")
		return 2
	}
	gate := policy == "all" || (policy == "full-only" && tier == "full")
	if gate && intent == "" {
		fmt.Fprintln(os.Stderr, "ut lab run: this run needs the human's approval, so --intent <one line: what is this experiment for> is required")
		return 2
	}

	prep, code := prepareRun(st, k, tier, group, params, dataFiles, cmdArgs)
	if prep == nil {
		return code
	}
	if !gate {
		if _, err := st.Append(prep.rd, labsvc.Event{Author: "machine", Kind: "run-start", Data: prep.envelope}); err != nil {
			fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
			return 1
		}
		fmt.Fprintf(os.Stderr, "lab: run %s started in set %s (log + snapshot in %s)\n", prep.runID, k.Set, prep.rd)
		return executeRun(st, prep.runID, prep.rd, prep.cwd, cmdArgs, prep.dataRefs)
	}

	// gated: file the proposal and wait for the human
	if _, err := st.Append(prep.rd, labsvc.Event{Author: "machine", Kind: "proposal",
		Text: intent, Data: prep.envelope}); err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "lab: proposal %s filed in set %s. waiting up to %s for approval.\n",
		prep.runID, k.Set, waitWindow())
	fmt.Fprintf(os.Stderr, "lab: the human grants it with: ut lab grant %s %s   (or from the hub)\n", k.Set, prep.runID)
	decided, approved, note := waitForDecision(st, k.Set, prep.runID, waitWindow())
	switch {
	case !decided:
		fmt.Fprintf(os.Stderr, "lab: no decision within %s. the proposal stays pending; launch later with: ut lab run --proposal %s\n",
			waitWindow(), prep.runID)
		return 75 // EX_TEMPFAIL: nothing ran
	case !approved:
		fmt.Fprintf(os.Stderr, "lab: proposal %s was rejected%s\n", prep.runID, noteSuffix(note))
		return 1
	}
	return launchApproved(st, k, prep.runID)
}

// runPrep is everything captured before a run starts or a proposal is filed.
type runPrep struct {
	runID, rd, cwd string
	envelope       map[string]any
	dataRefs       []fileRef
}

// prepareRun claims a run directory and captures the full provenance
// envelope: code snapshot, params, data hashes, environment, and the bind
// hash an approval will be tied to. On error it prints and returns nil with
// the exit code.
func prepareRun(st *labsvc.Store, k labsvc.Key, tier, group string, params, dataFiles, cmdArgs []string) (*runPrep, int) {
	// data files must be declared by full absolute path (LAB-DESIGN.md)
	var dataRefs []fileRef
	for _, p := range dataFiles {
		if !filepath.IsAbs(p) {
			fmt.Fprintf(os.Stderr, "ut lab run: --data-files requires full absolute paths, got %q\n", p)
			return nil, 2
		}
		sha, err := labsvc.Sha256File(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ut lab run: data file %s: %v\n", p, err)
			return nil, 2
		}
		dataRefs = append(dataRefs, fileRef{Path: p, Sha: sha})
	}

	cwd, _ := os.Getwd()
	runID, err := st.NewRun(k.Set)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return nil, 1
	}
	rd := st.RunDir(k.Set, runID)
	filesDir := filepath.Join(rd, "files")
	os.MkdirAll(filesDir, 0o755)

	snap, err := labsvc.CaptureSnapshot(cwd, filepath.Join(rd, "snapshot"), labsvc.DefaultCaps)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: snapshot: %v\n", err)
		return nil, 1
	}
	var paramRefs []fileRef
	var paramPaths []string
	for _, p := range params {
		sha, err := labsvc.Sha256File(p)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ut lab run: params file %s: %v\n", p, err)
			return nil, 2
		}
		dst := filepath.Join(filesDir, filepath.Base(p))
		if b, err := os.ReadFile(p); err == nil {
			os.WriteFile(dst, b, 0o644)
		}
		abs, _ := filepath.Abs(p)
		paramRefs = append(paramRefs, fileRef{Path: abs, Sha: sha})
		paramPaths = append(paramPaths, abs)
	}
	envFacts := labsvc.CaptureEnv(cwd, filepath.Join(filesDir, "env.txt"))
	bind, err := labsvc.CurrentBind(cwd, paramPaths)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return nil, 1
	}

	envelope := map[string]any{
		"argv": cmdArgs, "cwd": cwd,
		"machine": labsvc.Hostname(), "tier": tier, "group": group,
		"snapshot": snap, "params": paramRefs, "dataFiles": dataRefs, "env": envFacts,
		"bind": bind,
	}
	if s := tmuxSessionName(); s != "" {
		envelope["tmuxSession"] = s // advisory metadata only (LAB-DESIGN.md)
	}
	return &runPrep{runID: runID, rd: rd, cwd: cwd, envelope: envelope, dataRefs: dataRefs}, 0
}

// executeRun runs the job, teeing output to the capped log and the W&B
// scanner, then records the end: exit code, duration, W&B runs, and whether
// any declared data file changed while the run was going.
func executeRun(st *labsvc.Store, runID, rd, cwd string, cmdArgs []string, dataRefs []fileRef) int {
	logw, err := labsvc.NewCappedLogWriter(filepath.Join(rd, "log.txt"), 50<<20)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	var wandb labsvc.WandbScanner
	sink := io.MultiWriter(logw, &wandb)
	child := exec.Command(cmdArgs[0], cmdArgs[1:]...)
	child.Dir = cwd
	child.Stdin = os.Stdin
	child.Stdout = io.MultiWriter(os.Stdout, sink)
	child.Stderr = io.MultiWriter(os.Stderr, sink)
	start := time.Now()
	runErr := child.Run()
	dur := time.Since(start)
	logw.Close()

	exitCode := 0
	if runErr != nil {
		exitCode = 1
		if ee, ok := runErr.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		}
	}

	var drift []string
	for _, ref := range dataRefs {
		sha, err := labsvc.Sha256File(ref.Path)
		if err != nil || sha != ref.Sha {
			drift = append(drift, ref.Path)
		}
	}
	endData := map[string]any{
		"exit": exitCode, "durationSec": int64(dur.Seconds()),
		"tail": logw.Preview(),
	}
	if runs := wandb.Runs(); len(runs) > 0 {
		endData["wandb"] = runs
	}
	if len(drift) > 0 {
		endData["drift"] = drift
	}
	st.Append(rd, labsvc.Event{Author: "machine", Kind: "run-end", Data: endData})
	if len(drift) > 0 {
		st.Append(rd, labsvc.Event{Author: "machine", Kind: "data-drift",
			Text: "declared data files changed while the run was going: " + strings.Join(drift, ", ")})
	}
	fmt.Fprintf(os.Stderr, "lab: run %s finished, exit %d, %s. append results with: ut lab note --run %s <text>\n",
		runID, exitCode, dur.Round(time.Second), runID)
	return exitCode
}

// labResumeProposal picks up a filed proposal: keeps waiting if undecided,
// reports a rejection, or launches an approved one.
func labResumeProposal(st *labsvc.Store, k labsvc.Key, runID string) int {
	evs, err := st.Events(st.RunDir(k.Set, runID), true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	var hasProp, launched bool
	for _, e := range evs {
		switch e.Kind {
		case "proposal":
			hasProp = true
		case "run-start":
			launched = true
		}
	}
	if !hasProp {
		fmt.Fprintf(os.Stderr, "ut lab: run %s has no proposal\n", runID)
		return 1
	}
	if launched {
		fmt.Fprintf(os.Stderr, "ut lab: proposal %s was already launched (see `ut lab show %s`)\n", runID, runID)
		return 1
	}
	decided, approved, note := st.RunDecision(k.Set, runID)
	if !decided {
		fmt.Fprintf(os.Stderr, "lab: proposal %s still pending. waiting up to %s.\n", runID, waitWindow())
		decided, approved, note = waitForDecision(st, k.Set, runID, waitWindow())
	}
	switch {
	case !decided:
		fmt.Fprintf(os.Stderr, "lab: still no decision. try again later with: ut lab run --proposal %s\n", runID)
		return 75
	case !approved:
		fmt.Fprintf(os.Stderr, "lab: proposal %s was rejected%s\n", runID, noteSuffix(note))
		return 1
	}
	return launchApproved(st, k, runID)
}

// launchApproved verifies the approval still matches the working tree (the
// bind hash) and then launches the recorded command. On mismatch it refuses:
// the agent re-runs `ut lab run`, which files a fresh proposal.
func launchApproved(st *labsvc.Store, k labsvc.Key, runID string) int {
	rd := st.RunDir(k.Set, runID)
	evs, err := st.Events(rd, true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	var env map[string]any
	for _, e := range evs {
		if e.Kind == "proposal" {
			env = e.Data
		}
	}
	if env == nil {
		fmt.Fprintf(os.Stderr, "ut lab: run %s has no proposal envelope\n", runID)
		return 1
	}
	cwd, _ := env["cwd"].(string)
	bound, _ := env["bind"].(string)
	argv := toStrings(env["argv"])
	paramRefs := toFileRefs(env["params"])
	dataRefs := toFileRefs(env["dataFiles"])
	if len(argv) == 0 || cwd == "" {
		fmt.Fprintf(os.Stderr, "ut lab: proposal %s envelope is incomplete\n", runID)
		return 1
	}
	var paramPaths []string
	for _, r := range paramRefs {
		paramPaths = append(paramPaths, r.Path)
	}
	now, err := labsvc.CurrentBind(cwd, paramPaths)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	if now != bound {
		st.Append(rd, labsvc.Event{Author: "machine", Kind: "note",
			Text: "launch refused: code or params changed after approval"})
		fmt.Fprintf(os.Stderr, "lab: refusing to launch %s — the code or params changed after the approval. run `ut lab run` again to file a fresh proposal.\n", runID)
		return 1
	}
	st.Append(rd, labsvc.Event{Author: "machine", Kind: "run-start", Data: env})
	fmt.Fprintf(os.Stderr, "lab: approved run %s starting in set %s\n", runID, k.Set)
	return executeRun(st, runID, rd, cwd, argv, dataRefs)
}

func toStrings(v any) []string {
	var out []string
	if vs, ok := v.([]any); ok {
		for _, x := range vs {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
	} else if vs, ok := v.([]string); ok {
		out = vs
	}
	return out
}

func toFileRefs(v any) []fileRef {
	var out []fileRef
	switch vs := v.(type) {
	case []fileRef:
		return vs
	case []any:
		for _, x := range vs {
			if m, ok := x.(map[string]any); ok {
				r := fileRef{}
				r.Path, _ = m["path"].(string)
				r.Sha, _ = m["sha256"].(string)
				if r.Path != "" {
					out = append(out, r)
				}
			}
		}
	}
	return out
}

// waitWindow is how long a gated run waits for the human before exiting with
// the proposal id. UT_LAB_WAIT overrides it (used by tests).
func waitWindow() time.Duration {
	if v := os.Getenv("UT_LAB_WAIT"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return 10 * time.Minute
}

func waitForDecision(st *labsvc.Store, set, run string, window time.Duration) (decided, approved bool, note string) {
	deadline := time.Now().Add(window)
	for {
		d, a, n := st.RunDecision(set, run)
		if d {
			return true, a, n
		}
		if time.Now().After(deadline) {
			return false, false, ""
		}
		time.Sleep(2 * time.Second)
	}
}

func noteSuffix(note string) string {
	if note == "" {
		return ""
	}
	return ": " + note
}

func tmuxSessionName() string {
	if os.Getenv("TMUX") == "" {
		return ""
	}
	out, err := exec.Command("tmux", "display-message", "-p", "#S").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// --- note / hnote --------------------------------------------------------------

// labNote appends a note. Agent notes ("note") can target the set or one run.
// Human notes ("hnote", kept out of agent instructions) can also target the
// broad scopes: --scope global | project | machine.
func labNote(st *labsvc.Store, args []string, author string) int {
	keyFlag := oneFlag(&args, "--key")
	run := oneFlag(&args, "--run")
	scope := oneFlag(&args, "--scope")
	text := strings.TrimSpace(strings.Join(args, " "))
	if text == "" {
		fmt.Fprintf(os.Stderr, "usage: ut lab %s [--run R3] [--scope global|project|machine] <text>\n",
			map[string]string{"agent": "note", "human": "hnote"}[author])
		return 2
	}
	kind := "note"
	if author == "human" {
		kind = "hnote"
	} else if scope != "" {
		fmt.Fprintln(os.Stderr, "ut lab note: --scope is not an agent option; notes go to your own set or run")
		return 2
	}
	var dir string
	switch scope {
	case "global":
		dir = st.NotesDir("global")
	case "machine":
		dir = st.NotesDir("machine", labsvc.Hostname())
	case "project":
		k, err := st.ActiveKey(keyFlag)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ut lab: --scope project needs a key to name the project: %v\n", err)
			return 1
		}
		dir = st.NotesDir("project", k.Project)
	case "":
		k, err := st.ActiveKey(keyFlag)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
			return 1
		}
		if run != "" {
			dir = st.RunDir(k.Set, run)
			if _, err := os.Stat(dir); err != nil {
				fmt.Fprintf(os.Stderr, "ut lab: no run %s in set %s\n", run, k.Set)
				return 1
			}
		} else {
			dir = st.SetDir(k.Set)
		}
	default:
		fmt.Fprintf(os.Stderr, "ut lab: unknown scope %q\n", scope)
		return 2
	}
	kindForRun := kind
	if run != "" && author == "agent" {
		kindForRun = "result" // an agent note on a run is a result update
	}
	if _, err := st.Append(dir, labsvc.Event{Author: author, Kind: kindForRun, Text: text}); err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	fmt.Println("recorded.")
	return 0
}

// --- diff -----------------------------------------------------------------------

// labDiff answers "what is different between run R's recorded world and now":
// code, params, and declared data files. Environment drift shows through the
// recorded env facts.
func labDiff(st *labsvc.Store, args []string) int {
	keyFlag := oneFlag(&args, "--key")
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: ut lab diff <run-id>")
		return 2
	}
	k, err := st.ActiveKey(keyFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	_, evs, err := st.RunSummary(k.Set, args[0], true)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	var env map[string]any
	for _, e := range evs {
		if e.Kind == "run-start" {
			env = e.Data
			break
		}
	}
	if env == nil {
		fmt.Fprintln(os.Stderr, "ut lab: run has no recorded start envelope")
		return 1
	}
	cwd, _ := os.Getwd()
	if v, ok := env["cwd"].(string); ok && v != "" {
		cwd = v
	}
	fmt.Printf("run %s recorded vs now:\n", args[0])
	if snap, ok := env["snapshot"].(map[string]any); ok {
		then, _ := snap["baseSha"].(string)
		nowSha := "(no git)"
		if out, err := gitReadSha(cwd); err == nil {
			nowSha = out
		}
		if then == nowSha {
			fmt.Printf("  code base: unchanged (%s)\n", short(then))
		} else {
			fmt.Printf("  code base: %s then, %s now\n", short(then), short(nowSha))
		}
		if pb, ok := snap["patchBytes"].(float64); ok && pb > 0 {
			fmt.Printf("  the run also had %d bytes of uncommitted changes (snapshot/diff.patch)\n", int64(pb))
		}
	}
	compareRefs := func(label string, key string) {
		refs, ok := env[key].([]any)
		if !ok {
			return
		}
		for _, r := range refs {
			m, ok := r.(map[string]any)
			if !ok {
				continue
			}
			path, _ := m["path"].(string)
			then, _ := m["sha256"].(string)
			now, err := labsvc.Sha256File(path)
			switch {
			case err != nil:
				fmt.Printf("  %s %s: missing now\n", label, path)
			case now != then:
				fmt.Printf("  %s %s: CHANGED since the run\n", label, path)
			default:
				fmt.Printf("  %s %s: unchanged\n", label, path)
			}
		}
	}
	compareRefs("params", "params")
	compareRefs("data", "dataFiles")
	return 0
}

func gitReadSha(cwd string) (string, error) {
	out, err := exec.Command("git", "-C", cwd, "--no-optional-locks", "rev-parse", "HEAD").Output()
	return strings.TrimSpace(string(out)), err
}

func short(sha string) string {
	if len(sha) > 10 {
		return sha[:10]
	}
	return sha
}

// --- init -------------------------------------------------------------------------

// labArchive flips the archive view-state of a set or one run.
func labArchive(st *labsvc.Store, args []string, on bool) int {
	if len(args) < 1 || len(args) > 2 {
		fmt.Fprintln(os.Stderr, "usage: ut lab archive|unarchive <set> [run]")
		return 2
	}
	run := ""
	if len(args) == 2 {
		run = args[1]
	}
	if err := st.SetArchived(args[0], run, on); err != nil {
		fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
		return 1
	}
	return 0
}

const labInstruction = "This project uses Argus Lab. Run `ut lab brief` at the start of work and whenever unsure. Run every experiment through `ut lab run` and append results with `ut lab note` (see `ut lab help`).\n"

// labInit writes the one line agents need into the project instruction files.
// It appends to CLAUDE.md and AGENTS.md when they exist, creates AGENTS.md
// when neither does, and never duplicates the line.
func labInit(st *labsvc.Store) int {
	cwd, _ := os.Getwd()
	targets := []string{}
	for _, name := range []string{"CLAUDE.md", "AGENTS.md"} {
		if _, err := os.Stat(filepath.Join(cwd, name)); err == nil {
			targets = append(targets, name)
		}
	}
	if len(targets) == 0 {
		targets = []string{"AGENTS.md"}
	}
	for _, name := range targets {
		path := filepath.Join(cwd, name)
		b, _ := os.ReadFile(path)
		if strings.Contains(string(b), "ut lab brief") {
			fmt.Printf("%s already mentions ut lab, leaving it alone\n", name)
			continue
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			fmt.Fprintf(os.Stderr, "ut lab: %v\n", err)
			return 1
		}
		if len(b) > 0 && !strings.HasSuffix(string(b), "\n") {
			f.WriteString("\n")
		}
		f.WriteString("\n" + labInstruction)
		f.Close()
		fmt.Printf("added the lab instruction to %s\n", name)
	}
	return 0
}

const labHelp = `ut lab: run experiments through a recorded, human-approved protocol.

WHAT THIS IS
  A lab notebook the human can trust. Wrap your experiment command in
  "ut lab run" and the record is written for you: the exact code state
  (commit plus uncommitted diff), parameter files, environment, data-file
  fingerprints, the full log, and how the run ended. Records are
  append-only: nothing can be edited or deleted, and the human reads
  everything in the Argus app.

GETTING IN (once per project)
  1. ut lab login                requests access and prints your key
  2. export UT_LAB_KEY=<key>     every command below needs it
  3. wait for the human to approve the key. Until then every command
     errors. Once approved, "ut lab brief" prints your briefing.

START OF EVERY WORK SESSION
  ut lab brief                   the human's notes (treat them as ground
                                 truth), the runs so far, and anything
                                 waiting on you. Re-run it when unsure.

RUNNING AN EXPERIMENT
  ut lab run --tier quick --intent "does training start at all" \
      -- python train.py --lr 3e-4

  --tier quick|full     declare what this run is. quick means a cheap
                        sanity check or probe, full means a real
                        experiment. Required under the default policy.
  --intent "one line"   what the run is for. The human reads exactly this
                        line when deciding. Required for any gated run.
  --params conf.yaml    parameter file(s) to copy into the record
  --data-files /a,/b    input data as absolute paths. They are
                        fingerprinted, so later drift is detected.
  --group sweep1        tag related runs, for example one sweep

WHEN DOES A RUN NEED APPROVAL?
  The set's policy decides. The human sets it, you do not:
    full-only   quick runs start at once, full runs are gated  (default)
    all         every run is gated
    none        no run is gated
  A gated run files a proposal and waits up to 10 minutes for the human
  (set UT_LAB_WAIT=30m to wait longer). If approved, it launches by
  itself. If rejected, you get the human's note. If nobody decides in
  time, nothing has run, and you launch it later with
      ut lab run --proposal R5
  The command, parameters, and code state are locked when the proposal
  is filed. To change anything, file a new proposal.

AFTER A RUN
  ut lab note --run R3 "loss 0.42, lower lr converges slower"
                        report results here, not in the console log
  ut lab show R3        the full record of one run
  ut lab diff R3        what changed between R3's world and now
  ut lab note "text"    a note to the human that is not about one run

HUMAN SIDE (agents never need these)
  ut lab keys                    list keys and their sets
  ut lab approve <prefix> [--project name] [--policy all|full-only|none]
  ut lab deny <prefix> [--note why]      ut lab revoke <prefix>
  ut lab proposals               gated runs waiting for a decision
  ut lab grant <set> <run>       ut lab reject <set> <run> [--note why]
  ut lab policy <set> [all|full-only|none]
  ut lab hide <set> <event-id>   hide an event from agents, delete nothing
  ut lab archive <set> [run]     tuck a set or run out of the normal view
                                 (reversible: unarchive; agents unaffected)
  ut lab hnote [--scope global|project|machine] <text>   leave a note
  ut lab init                    add the one-line lab instruction to
                                 CLAUDE.md / AGENTS.md in this folder
`
