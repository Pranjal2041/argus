package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// The mesh CLI. `ut-broker <verb> ...` (wrapped by the `ut` script) talks to the
// LOCAL broker on loopback and relays to any machine via /mesh/proxy, so an
// agent reaches the whole fabric by name. `ut help` is the agent's manual.

var meshVerbs = map[string]bool{
	"ls": true, "exec": true, "run": true, "sh": true, "spawn": true,
	"tail": true, "send": true, "cp": true, "help": true, "--help": true, "-h": true,
}

func isMeshVerb(s string) bool { return meshVerbs[s] }

func localPort() string {
	if p := os.Getenv("UT_PORT"); p != "" {
		return p
	}
	return "8722"
}

func localBase() string { return "http://127.0.0.1:" + localPort() }

// runClient dispatches a mesh subcommand. Returns the process exit code.
func runClient(args []string) int {
	verb, rest := args[0], args[1:]
	switch verb {
	case "help", "--help", "-h":
		fmt.Print(helpText)
		return 0
	case "ls":
		return cmdLs()
	case "exec", "run":
		return cmdExec(rest)
	case "sh":
		return cmdSh(rest)
	case "spawn":
		return cmdSpawn(rest)
	case "send":
		return cmdSend(rest)
	case "tail":
		return cmdTail(rest)
	case "cp":
		return cmdCp(rest)
	default:
		fmt.Fprintf(os.Stderr, "ut: unknown command %q (try `ut help`)\n", verb)
		return 2
	}
}

// --- target parsing: "@host", "host", or "host:shell" -----------------------

func parseTarget(tok string) (host, shell string) {
	tok = strings.TrimPrefix(tok, "@")
	if i := strings.LastIndex(tok, ":"); i >= 0 {
		return tok[:i], tok[i+1:]
	}
	return tok, ""
}

// --- HTTP helpers -----------------------------------------------------------

// peerURL builds a request that the LOCAL broker relays to `host`'s broker at
// `path`. host=="" or self → talk to the local broker directly.
func peerURL(host, path string, q url.Values) string {
	if host == "" || isSelf(host) {
		u := localBase() + path
		if len(q) > 0 {
			u += "?" + q.Encode()
		}
		return u
	}
	mq := url.Values{"_mhost": {host}, "_mpath": {path}}
	for k, vs := range q {
		for _, v := range vs {
			mq.Add(k, v)
		}
	}
	return localBase() + "/mesh/proxy?" + mq.Encode()
}

var selfNames map[string]bool

func isSelf(host string) bool {
	if selfNames == nil {
		selfNames = map[string]bool{}
		if b, _, err := httpGet(localBase()+"/whoami", 4*time.Second); err == nil {
			var who struct{ Name string }
			if json.Unmarshal(b, &who) == nil && who.Name != "" {
				selfNames[strings.ToLower(who.Name)] = true
				if i := strings.Index(strings.ToLower(who.Name), "."); i > 0 {
					selfNames[strings.ToLower(who.Name)[:i]] = true
				}
			}
		}
	}
	return selfNames[strings.ToLower(host)]
}

func httpGet(u string, timeout time.Duration) ([]byte, int, error) {
	c := &http.Client{Timeout: timeout}
	resp, err := c.Get(u)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b, resp.StatusCode, nil
}

func httpPost(u string, body []byte, timeout time.Duration) ([]byte, int, error) {
	c := &http.Client{Timeout: timeout}
	resp, err := c.Post(u, "application/octet-stream", bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b, resp.StatusCode, nil
}

// --- ls ---------------------------------------------------------------------

func cmdLs() int {
	type machine struct {
		name, host string
	}
	machines := []machine{}
	// self
	if b, _, err := httpGet(localBase()+"/whoami", 4*time.Second); err == nil {
		var who struct{ Name string }
		if json.Unmarshal(b, &who) == nil {
			machines = append(machines, machine{who.Name + " (this machine)", ""})
		}
	}
	// peers
	if b, _, err := httpGet(localBase()+"/mesh/peers", 15*time.Second); err == nil {
		var pr struct {
			Peers []struct{ Name, Host string }
		}
		if json.Unmarshal(b, &pr) == nil {
			sort.Slice(pr.Peers, func(i, j int) bool { return pr.Peers[i].Name < pr.Peers[j].Name })
			for _, p := range pr.Peers {
				machines = append(machines, machine{p.Name, p.Host})
			}
		}
	}
	for _, m := range machines {
		fmt.Printf("\033[1m%s\033[0m\n", m.name)
		host := m.host
		if strings.Contains(m.name, "this machine") {
			host = ""
		}
		b, _, err := httpGet(peerURL(meshHost(m.name, host), "/sessions", nil), 12*time.Second)
		if err != nil {
			fmt.Println("    (unreachable)")
			continue
		}
		var sr struct {
			Sessions []struct {
				Name, State, Path string
			}
		}
		_ = json.Unmarshal(b, &sr)
		if len(sr.Sessions) == 0 {
			fmt.Println("    (no sessions)")
		}
		for _, s := range sr.Sessions {
			st := s.State
			if st == "" {
				st = "idle"
			}
			fmt.Printf("    %-22s %-8s %s\n", s.Name, st, s.Path)
		}
	}
	return 0
}

// meshHost maps an ls machine to the host token used for relay ("" = self).
func meshHost(name, host string) string {
	if strings.Contains(name, "this machine") {
		return ""
	}
	return host
}

// --- exec / run -------------------------------------------------------------

func cmdExec(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ut exec <@machine|machine[:shell]> <command...>")
		return 2
	}
	host, shell := parseTarget(args[0])
	cmd := strings.Join(args[1:], " ")
	q := url.Values{}
	if shell != "" {
		q.Set("session", shell)
	}
	b, code, err := httpPost(peerURL(host, "/exec", q), []byte(cmd), 0)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut exec:", err)
		return 1
	}
	if code != 200 {
		fmt.Fprintf(os.Stderr, "ut exec: broker error: %s\n", strings.TrimSpace(string(b)))
		return 1
	}
	var res struct {
		Stdout, Stderr, Error string
		Exit                  int
		TimedOut              bool
	}
	if json.Unmarshal(b, &res) != nil {
		fmt.Fprintln(os.Stderr, "ut exec: bad response")
		return 1
	}
	if res.Error != "" {
		fmt.Fprintln(os.Stderr, "ut exec:", res.Error)
		return 1
	}
	fmt.Print(res.Stdout)
	fmt.Fprint(os.Stderr, res.Stderr)
	if res.TimedOut {
		fmt.Fprintln(os.Stderr, "ut exec: timed out")
	}
	return res.Exit
}

// --- sh: create or list persistent shells -----------------------------------

func cmdSh(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: ut sh <@machine> [shell-name]")
		return 2
	}
	host, _ := parseTarget(args[0])
	if len(args) >= 2 { // create (attach-or-create) a named shell
		name := args[1]
		q := url.Values{"action": {"create"}, "session": {name}}
		if _, code, err := httpPost(peerURL(host, "/control", q), nil, 15*time.Second); err != nil || code != 200 {
			fmt.Fprintf(os.Stderr, "ut sh: create failed (%v)\n", err)
			return 1
		}
		fmt.Printf("shell %q ready on %s — run in it with:  ut run %s:%s <command>\n", name, host, host, name)
		return 0
	}
	// list shells (= sessions) on the machine
	b, _, err := httpGet(peerURL(host, "/sessions", nil), 12*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut sh:", err)
		return 1
	}
	var sr struct {
		Sessions []struct{ Name, State, Path string }
	}
	_ = json.Unmarshal(b, &sr)
	for _, s := range sr.Sessions {
		fmt.Printf("%-22s %-8s %s\n", s.Name, s.State, s.Path)
	}
	return 0
}

// --- spawn: fire a long job into a fresh session ----------------------------

func cmdSpawn(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ut spawn <@machine[:name]> <command...>")
		return 2
	}
	host, name := parseTarget(args[0])
	if name == "" {
		name = "job-" + time.Now().Format("150405")
	}
	cmd := strings.Join(args[1:], " ")
	q := url.Values{"action": {"create"}, "session": {name}}
	if _, code, err := httpPost(peerURL(host, "/control", q), nil, 15*time.Second); err != nil || code != 200 {
		fmt.Fprintf(os.Stderr, "ut spawn: create failed (%v)\n", err)
		return 1
	}
	if _, code, err := httpPost(peerURL(host, "/send", url.Values{"session": {name}}), []byte(cmd), 15*time.Second); err != nil || code != 200 {
		fmt.Fprintf(os.Stderr, "ut spawn: send failed (%v)\n", err)
		return 1
	}
	fmt.Printf("spawned %q on %s — follow it with:  ut tail %s:%s\n", name, host, host, name)
	return 0
}

// --- send: type into a shell (no capture) -----------------------------------

func cmdSend(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: ut send <@machine:shell> <text...>")
		return 2
	}
	host, shell := parseTarget(args[0])
	if shell == "" {
		fmt.Fprintln(os.Stderr, "ut send: target must be machine:shell")
		return 2
	}
	text := strings.Join(args[1:], " ")
	if _, code, err := httpPost(peerURL(host, "/send", url.Values{"session": {shell}}), []byte(text), 15*time.Second); err != nil || code != 200 {
		fmt.Fprintf(os.Stderr, "ut send: failed (%v)\n", err)
		return 1
	}
	return 0
}

// --- tail: stream a session's live output -----------------------------------

func cmdTail(args []string) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "usage: ut tail <@machine:session>")
		return 2
	}
	host, sessName := parseTarget(args[0])
	if sessName == "" {
		fmt.Fprintln(os.Stderr, "ut tail: target must be machine:session")
		return 2
	}
	// Plain HTTP streaming feed (snapshot + live output), relayed through the
	// mesh's HTTP proxy — no WebSocket double-hop. Streams until Ctrl-C / EOF.
	u := peerURL(host, "/stream", url.Values{"session": {sessName}})
	resp, err := (&http.Client{Timeout: 0}).Get(u)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut tail:", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		fmt.Fprintf(os.Stderr, "ut tail: %s\n", strings.TrimSpace(string(b)))
		return 1
	}
	_, _ = io.Copy(os.Stdout, resp.Body)
	return 0
}

// --- cp: copy a file across machines ----------------------------------------

func cmdCp(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ut cp <src> <dst>   (either side may be machine:path)")
		return 2
	}
	srcHost, srcPath := splitFileArg(args[0])
	dstHost, dstPath := splitFileArg(args[1])
	// read src
	var data []byte
	if srcHost == "" && !strings.Contains(args[0], ":") {
		b, err := os.ReadFile(srcPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ut cp: read src:", err)
			return 1
		}
		data = b
	} else {
		b, code, err := httpGet(peerURL(srcHost, "/fs/read", url.Values{"path": {srcPath}}), 0)
		if err != nil || code != 200 {
			fmt.Fprintf(os.Stderr, "ut cp: read %s failed (%v)\n", args[0], err)
			return 1
		}
		data = b
	}
	// write dst
	if dstHost == "" && !strings.Contains(args[1], ":") {
		if err := os.WriteFile(dstPath, data, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "ut cp: write dst:", err)
			return 1
		}
	} else {
		if _, code, err := httpPost(peerURL(dstHost, "/fs/write", url.Values{"path": {dstPath}}), data, 0); err != nil || code != 200 {
			fmt.Fprintf(os.Stderr, "ut cp: write %s failed (%v)\n", args[1], err)
			return 1
		}
	}
	fmt.Printf("copied %d bytes\n", len(data))
	return 0
}

// splitFileArg parses "machine:/path" → ("machine","/path"); a bare path →
// ("","path"). A leading "/" or "./" or "~" means local (no machine).
func splitFileArg(a string) (host, path string) {
	if strings.HasPrefix(a, "/") || strings.HasPrefix(a, ".") || strings.HasPrefix(a, "~") {
		return "", a
	}
	if i := strings.Index(a, ":"); i > 0 {
		return strings.TrimPrefix(a[:i], "@"), a[i+1:]
	}
	return "", a
}

const helpText = `ut — one fabric across all your machines (Mac, cluster, Windows) over Tailscale.

An agent on any machine reaches every other machine BY NAME, with no SSH setup.
Files, shells, and commands work the same everywhere.

USAGE
  ut ls                                 list every machine and its sessions
  ut exec  @<machine> <command...>      run a one-shot command, print its output
  ut sh    @<machine> <name>            create a persistent shell (keeps cwd/env/venv)
  ut sh    @<machine>                   list a machine's shells
  ut run   @<machine>:<shell> <cmd...>  run a command INSIDE a shell (state persists)
  ut spawn @<machine>[:name] <cmd...>   start a long job in a session (returns its name)
  ut tail  @<machine>:<session>         stream a session's output (Ctrl-C to stop)
                                        — for a reliable snapshot of a remote job's
                                        recent output, prefer: ut run @m:<job> 'tail -n 40 log'
  ut send  @<machine>:<shell> <text...> type text into a shell (no output captured)
  ut cp    <src> <dst>                  copy a file; either side may be <machine>:<path>

ADDRESSING
  @<machine>          a target host, e.g. @babel-p9-16   (the leading @ is optional)
  <machine>:<shell>   a persistent shell on that machine
  <machine>:<path>    a file on that machine

EXAMPLES
  ut ls
  ut exec @babel-p9-16 'nvidia-smi --query-gpu=memory.used --format=csv'
  ut sh   @babel-p9-16 train          # make a shell
  ut run  @babel-p9-16:train 'cd ~/proj && source .venv/bin/activate'
  ut run  @babel-p9-16:train 'python eval.py --ckpt last'   # venv still active
  ut spawn @babel-p9-16:sweep 'python sweep.py'   ;   ut tail @babel-p9-16:sweep
  ut cp   ./config.yaml babel-p9-16:/home/me/proj/config.yaml

NOTES
  • exec/run return the command's real exit code, stdout on stdout, stderr on stderr —
    so it behaves like running locally.
  • A "shell" persists state (cwd, exports, activated venv) across run/send calls;
    one-shot exec runs a fresh process each time.
  • Run 'ut ls' first to see the exact machine names.
`
