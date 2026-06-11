package tmux

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"universal-tmux/internal/session"
)

const defaultExecTimeout = 120 * time.Second

// Exec runs a command on this host. Two modes:
//   - one-shot (req.Session == ""): a fresh `sh -c` process, captured via pipes.
//   - in-session: the command runs INSIDE the named tmux session's live shell,
//     so env / cwd / activated venv persist across calls. Output is captured
//     deterministically — NOT by scraping the terminal — by redirecting to temp
//     files on this host (the broker runs here) and polling for a done-file.
func (p *Provider) Exec(req session.ExecRequest) session.ExecResult {
	timeout := time.Duration(req.TimeoutSec) * time.Second
	if timeout <= 0 {
		timeout = defaultExecTimeout
	}
	if req.Session == "" {
		return execOneShot(req.Cmd, req.Dir, timeout)
	}
	return execInSession(p.socket, req.Session, req.Cmd, timeout)
}

// execOneShot runs the command as a fresh process in the broker's environment.
func execOneShot(cmd, dir string, timeout time.Duration) session.ExecResult {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c := exec.CommandContext(ctx, "sh", "-c", cmd)
	if dir != "" {
		c.Dir = dir
	}
	var so, se bytes.Buffer
	c.Stdout = &so
	c.Stderr = &se
	err := c.Run()
	res := session.ExecResult{Stdout: so.String(), Stderr: se.String()}
	if ctx.Err() == context.DeadlineExceeded {
		res.TimedOut = true
		res.Exit = 124
		return res
	}
	res.Exit = exitCode(err)
	return res
}

// execInSession runs cmd inside the session's live shell and captures its output.
//
// The user's command is written to a temp SCRIPT file (so arbitrary content —
// quotes, newlines — is safe), then the session shell is told to SOURCE it with
// output redirected to temp files and the exit code to a done-file:
//
//	{ . SCRIPT ; } >OUT 2>ERR ; printf %s "$?" >DONE
//
// Sourcing (`.`) runs in the CURRENT shell, so `cd`/`export`/`conda activate`
// inside the command persist into the session — the whole point of a stateful
// shell. The `{ }` group (not a subshell) keeps that true while still capturing
// the group's output. The broker then polls for DONE locally and reads the raw
// bytes — no terminal scrape, no ANSI, no wrap reflow.
func execInSession(socket, name, cmd string, timeout time.Duration) session.ExecResult {
	if !HasSession(socket, name) {
		return session.ExecResult{Error: fmt.Sprintf("no such session %q", name), Exit: -1}
	}
	id := execID()
	base := fmt.Sprintf("%s/.ut-exec-%s", os.TempDir(), id)
	script, out, errf, done := base+".sh", base+".out", base+".err", base+".done"
	defer func() {
		for _, f := range []string{script, out, errf, done} {
			_ = os.Remove(f)
		}
	}()

	if err := os.WriteFile(script, []byte(cmd+"\n"), 0o600); err != nil {
		return session.ExecResult{Error: "write script: " + err.Error(), Exit: -1}
	}

	// One line, fixed format (the variable part is the script path, not the
	// user's command), submitted with Enter.
	line := fmt.Sprintf("{ . %s ; } >%s 2>%s ; printf %%s \"$?\" >%s", script, out, errf, done)
	if err := exec.Command("tmux", tmuxArgs(socket, "send-keys", "-t", name, "-l", line)...).Run(); err != nil {
		return session.ExecResult{Error: "send-keys: " + err.Error(), Exit: -1}
	}
	if err := exec.Command("tmux", tmuxArgs(socket, "send-keys", "-t", name, "Enter")...).Run(); err != nil {
		return session.ExecResult{Error: "send-keys Enter: " + err.Error(), Exit: -1}
	}

	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(done); err == nil {
			break
		}
		if time.Now().After(deadline) {
			so, _ := os.ReadFile(out)
			se, _ := os.ReadFile(errf)
			return session.ExecResult{Stdout: string(so), Stderr: string(se), TimedOut: true, Exit: 124}
		}
		time.Sleep(40 * time.Millisecond)
	}
	so, _ := os.ReadFile(out)
	se, _ := os.ReadFile(errf)
	rc, _ := strconv.Atoi(strings.TrimSpace(string(mustRead(done))))
	return session.ExecResult{Stdout: string(so), Stderr: string(se), Exit: rc}
}

// SendText types text into a session's shell (and optionally Enter), returning
// immediately without capturing output — for firing a long job or interactive
// input. -l sends the bytes literally.
func (p *Provider) SendText(name, text string, enter bool) error {
	if !HasSession(p.socket, name) {
		return fmt.Errorf("no such session %q", name)
	}
	if text != "" {
		if err := exec.Command("tmux", tmuxArgs(p.socket, "send-keys", "-t", name, "-l", text)...).Run(); err != nil {
			return err
		}
	}
	if enter {
		return exec.Command("tmux", tmuxArgs(p.socket, "send-keys", "-t", name, "Enter")...).Run()
	}
	return nil
}

func mustRead(p string) []byte { b, _ := os.ReadFile(p); return b }

// exitCode extracts the process exit code from a CombinedOutput/Run error.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode()
	}
	return 1
}

// execID is a unique-enough token for temp file names (time-based; exec calls on
// one host are not concurrent enough to collide at nanosecond resolution).
func execID() string {
	return strconv.FormatInt(time.Now().UnixNano(), 36)
}
