//go:build !windows

package recovery

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"universal-tmux/internal/toolcommand"
)

// verifyRecordedProcessStart binds a stored PID to its current lifetime. Some
// producers record Linux's exact /proc start ticks; others record ps lstart.
// Compare each representation in its own domain, never convert ticks to a
// rounded wall-clock time or accept a PID without start evidence.
func verifyRecordedProcessStart(pid int, recorded string) error {
	value := strings.Join(strings.Fields(recorded), " ")
	if ticks, err := strconv.ParseUint(value, 10, 64); err == nil {
		if ticks == 0 {
			return fmt.Errorf("empty process start identity")
		}
		observed, err := platformProcessStartTicks(pid)
		if err != nil {
			return fmt.Errorf("read process start ticks: %w", err)
		}
		if strconv.FormatUint(ticks, 10) != observed {
			return fmt.Errorf("process start mismatch")
		}
		return nil
	}
	started, err := platformProcessStart(pid)
	if err != nil {
		return fmt.Errorf("read process start: %w", err)
	}
	if !recordedStartTimeMatches(value, started, time.Local) {
		return fmt.Errorf("process start mismatch")
	}
	return nil
}

func recordedStartTimeMatches(recorded string, started time.Time, local *time.Location) bool {
	const layout = "Mon Jan 2 15:04:05 2006"
	for _, location := range []*time.Location{time.UTC, local} {
		parsed, err := time.ParseInLocation(layout, recorded, location)
		if err == nil && parsed.Unix() == started.Unix() {
			return true
		}
	}
	return false
}

func processStartViaPS(pid int) (time.Time, error) {
	out, err := toolcommand.Command("ps", "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
	if err != nil {
		return time.Time{}, err
	}
	value := strings.Join(strings.Fields(string(out)), " ")
	parsed, err := time.ParseInLocation("Mon Jan 2 15:04:05 2006", value, time.Local)
	if err != nil {
		return time.Time{}, fmt.Errorf("parse process start %q: %w", value, err)
	}
	return parsed, nil
}
