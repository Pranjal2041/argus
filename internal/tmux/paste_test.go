package tmux

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSendTextHonorsNegotiatedPasteModeWithoutChangingPayload(t *testing.T) {
	provider, socket := tmuxIdentityTestProvider(t)
	for _, bracketed := range []bool{false, true} {
		for _, enter := range []bool{false, true} {
			name := fmt.Sprintf("paste-%v-%v", bracketed, enter)
			path := filepath.Join(t.TempDir(), "received")
			text := "line one\nline two λ; literal $() and `quotes`"
			want := text
			mode := "\033[?2004l"
			if bracketed {
				want = "\x1b[200~" + want + "\x1b[201~"
				mode = "\033[?2004h"
			}
			if enter {
				want += "\r"
			}
			command := fmt.Sprintf("stty raw -echo; printf '%sREADY'; dd bs=1 count=%d of='%s' 2>/dev/null; printf '\\033[?2004lDONE'; sleep 30", mode, len(want), path)
			if out, err := exec.Command("tmux", "-L", socket, "new-session", "-d", "-s", name, command).CombinedOutput(); err != nil {
				t.Fatalf("create: %v %s", err, out)
			}
			deadline := time.Now().Add(3 * time.Second)
			for {
				output, _ := provider.Capture(name, 40)
				if strings.Contains(output, "READY") {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("test reader did not start")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if err := provider.SendText(name, text, enter); err != nil {
				t.Fatal(err)
			}
			for {
				got, _ := os.ReadFile(path)
				if bytes.Equal(got, []byte(want)) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("mode=%v enter=%v: got %q, want %q", bracketed, enter, got, want)
				}
				time.Sleep(10 * time.Millisecond)
			}
		}
	}
	out, err := exec.Command("tmux", "-L", socket, "list-buffers", "-F", "#{buffer_name}").CombinedOutput()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "ut-send-") {
		t.Fatalf("temporary paste buffer leaked: %s", out)
	}
}
