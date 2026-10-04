//go:build linux

package recovery

import (
	"strings"
	"testing"
)

func TestProcStatStartTicks(t *testing.T) {
	for _, comm := range []string{"worker", "worker name", "worker ) tricky (name)"} {
		stat := "42 (" + comm + ") S " + strings.Repeat("0 ", 18) + "987654321 0 0\n"
		got, err := procStatStartTicks(stat)
		if err != nil || got != "987654321" {
			t.Fatalf("comm %q: ticks = %q, %v", comm, got, err)
		}
	}
	for _, stat := range []string{
		"", "42 worker", "42 (worker) S 0",
		"42 (worker) S " + strings.Repeat("0 ", 18) + "0",
		"42 (worker) S " + strings.Repeat("0 ", 18) + "-1",
		"42 (worker) S " + strings.Repeat("0 ", 18) + "18446744073709551616",
	} {
		if got, err := procStatStartTicks(stat); err == nil {
			t.Fatalf("malformed stat accepted as %q: %q", got, stat)
		}
	}
}
