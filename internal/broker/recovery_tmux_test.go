//go:build !windows

package broker

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"universal-tmux/internal/session"
	"universal-tmux/internal/tmux"
)

type silentSnapshotAttachment struct{ session.Session }

func (s *silentSnapshotAttachment) RequestSnapshot(uint64) error { return nil }

type firstSilentAttachmentProvider struct {
	session.Provider
	dials int
}

func (p *firstSilentAttachmentProvider) Dial(ctx context.Context, name string) (session.Session, error) {
	s, err := p.Provider.Dial(ctx, name)
	p.dials++
	if err == nil && p.dials == 1 {
		// Inject a lost snapshot response at the common backend boundary while
		// retaining the real control process, output stream and detach behavior.
		return &silentSnapshotAttachment{s}, nil
	}
	return s, err
}

func TestRealStalledControlAttachmentRecoversWithoutRestartingPane(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux unavailable")
	}
	// This server and its control clients belong only to this test.
	socket := fmt.Sprintf("argus-recovery-test-%d", time.Now().UnixNano())
	run := func(args ...string) string {
		t.Helper()
		out, err := exec.Command("tmux", append([]string{"-L", socket}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("tmux %v: %v: %s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	t.Cleanup(func() { _ = exec.Command("tmux", "-L", socket, "kill-server").Run() })
	run("-f", "/dev/null", "new-session", "-d", "-s", "fixture", "-x", "80", "-y", "24", "printf 'recovery-fixture'; exec sleep 30")
	identity := func() string {
		return run("display-message", "-p", "-t", "fixture", "#{pid}:#{session_id}:#{pane_id}:#{pane_pid}")
	}
	before := identity()
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	provider := &firstSilentAttachmentProvider{Provider: tmux.NewProvider(socket)}
	m := &Manager{ctx: ctx, prov: provider, hubs: make(map[string]*sessionHub)}
	h, err := m.hub("fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer h.close()
	var controlPID int
	for controlPID == 0 {
		for _, line := range strings.Split(run("list-clients", "-F", "#{client_pid} #{client_control_mode}"), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && fields[1] == "1" {
				controlPID, _ = strconv.Atoi(fields[0])
			}
		}
		if ctx.Err() != nil {
			t.Fatal("control attachment did not register")
		}
		if controlPID == 0 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	h.snapshotWait = 30 * time.Millisecond
	sub, disconnected := recoverySubscriber(h)
	if err := h.requestSnapshot(sub); err != nil {
		t.Fatal(err)
	}
	awaitRecovery(t, h.dead)
	awaitRecovery(t, disconnected.Done())
	if got := identity(); got != before {
		t.Fatalf("retirement restarted the terminal: before=%s after=%s", before, got)
	}
	if err := syscall.Kill(controlPID, 0); err == nil {
		t.Fatal("retired control process was not reaped")
	}
	next, err := m.hub("fixture")
	if err != nil {
		t.Fatal(err)
	}
	defer next.close()
	fresh, _ := recoverySubscriber(next)
	if err := next.requestSnapshot(fresh); err != nil {
		t.Fatal(err)
	}
	if got := readRecoverySnapshot(t, fresh); !strings.Contains(got, "recovery-fixture") {
		t.Fatalf("replacement did not restore the existing pane: %q", got)
	}
	if got := identity(); got != before {
		t.Fatalf("reconnect restarted the terminal: before=%s after=%s", before, got)
	}
}
