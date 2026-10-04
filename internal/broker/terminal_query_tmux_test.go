//go:build !windows

package broker

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"

	"universal-tmux/internal/tmux"
)

func TestRealMultiplexerAnswersOnceWhileViewersStayPassive(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux unavailable")
	}
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 unavailable")
	}
	// An isolated raw-mode application asks queries, drains their replies, then
	// waits at a prompt. No real shell/agent, trust state or user session is used.
	program := `import os, tty, select, time
tty.setraw(0)
os.write(1, b'READY')
while os.read(0, 1) != b'G': pass
os.write(1, b'\x1b[c\x1b[6n\x1b]11;?\x07\x1b[?u')
reply = b''
deadline = time.monotonic() + .4
while time.monotonic() < deadline:
    if select.select([0], [], [], .02)[0]: reply += os.read(0, 4096)
os.write(1, b'\r\nREPLIES:' + reply.hex().encode() + b':END\r\nConfirm action? [y/n]')
key = os.read(0, 1)
os.write(1, b'\r\nKEY:' + key.hex().encode() + b':END')
time.sleep(5)
`
	socket := fmt.Sprintf("argus-query-test-%d", time.Now().UnixNano())
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	command := fmt.Sprintf("%q -c 'import base64;exec(base64.b64decode(\"%s\"))'", python, base64.StdEncoding.EncodeToString([]byte(program)))
	if out, err := exec.Command("tmux", "-L", socket, "-f", "/dev/null", "new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24", command).CombinedOutput(); err != nil {
		t.Fatalf("fixture: %v: %s", err, out)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	c, err := tmux.Dial(ctx, socket, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	h := newSessionHub(c)
	a, b := querySubscriber(true), querySubscriber(true)
	h.mu.Lock()
	h.subs[a], h.subs[b] = struct{}{}, struct{}{}
	h.mu.Unlock()
	if err := c.Resize(80, 24); err != nil {
		t.Fatal(err)
	}
	// Synchronize on the ordered snapshot, after the fixture reached raw mode.
	for {
		out, _ := exec.Command("tmux", "-L", socket, "capture-pane", "-p", "-t", "fixture").Output()
		if strings.Contains(string(out), "READY") {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("fixture not ready")
		case <-time.After(10 * time.Millisecond):
		}
	}
	if err := c.SendKeys(c.Pane(), []byte("G")); err != nil {
		t.Fatal(err)
	}
	readUntil := func(s *subscriber, marker string) string {
		var output string
		for !strings.Contains(output, marker) {
			select {
			case frame := <-s.ch:
				op, _, payload, _ := decodeFrame(frame)
				if op == opOutput {
					output += string(payload)
				}
			case <-ctx.Done():
				t.Fatalf("missing %s: %q", marker, output)
			}
		}
		return output
	}
	for _, s := range []*subscriber{a, b} {
		output := readUntil(s, "Confirm action? [y/n]")
		for _, q := range []string{"\x1b[c", "\x1b[6n", "\x1b]11;?", "\x1b[?u"} {
			if strings.Contains(output, q) {
				t.Fatalf("live query leaked: %q", output)
			}
		}
		start := strings.Index(output, "REPLIES:") + len("REPLIES:")
		end := strings.Index(output[start:], ":END")
		reply, err := hex.DecodeString(output[start : start+end])
		if err != nil {
			t.Fatal(err)
		}
		if len(regexp.MustCompile(`\x1b\[\?[0-9;]*c`).FindAll(reply, -1)) != 1 || len(regexp.MustCompile(`\x1b\[[0-9]+;[0-9]+R`).FindAll(reply, -1)) != 1 {
			t.Fatalf("expected one DA and cursor reply from tmux: %q", reply)
		}
		if strings.Contains(output, "KEY:") {
			t.Fatalf("prompt consumed unsolicited input: %q", output)
		}
	}
	if err := c.SendKeys(c.Pane(), []byte("n")); err != nil {
		t.Fatal(err)
	}
	for _, s := range []*subscriber{a, b} {
		readUntil(s, "KEY:6e:END")
	}
}
