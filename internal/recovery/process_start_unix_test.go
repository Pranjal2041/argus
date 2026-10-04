//go:build !windows

package recovery

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"
)

func TestRecordedStartTimeMatchesUTCAndLocalWithoutRounding(t *testing.T) {
	local := time.FixedZone("test-local", -4*60*60)
	started := time.Date(2026, 8, 3, 12, 34, 56, 123456000, time.UTC)
	for _, value := range []string{
		"Mon Aug 3 12:34:56 2026", "Mon Aug 3 08:34:56 2026",
	} {
		if !recordedStartTimeMatches(value, started, local) {
			t.Fatalf("valid start rejected: %q", value)
		}
	}
	for _, value := range []string{
		"", "garbage", "12345", "Mon Aug 3 12:34:55 2026", "Mon Aug 3 12:34:57 2026",
	} {
		if recordedStartTimeMatches(value, started, local) {
			t.Fatalf("invalid/stale start accepted: %q", value)
		}
	}
}

func TestInspectClaudeRequiresCurrentProcessLifetime(t *testing.T) {
	pid := os.Getpid()
	started, err := platformProcessStart(pid)
	if err != nil {
		t.Fatal(err)
	}
	const layout = "Mon Jan 2 15:04:05 2006"
	type testCase struct {
		name, start string
		pid         int
		valid       bool
	}
	cases := []testCase{
		{"UTC date", started.UTC().Format(layout), pid, true},
		{"local date", started.Local().Format(layout), pid, true},
		{"stale date", started.Add(-time.Second).UTC().Format(layout), pid, false},
		{"wrong pid", started.UTC().Format(layout), pid + 1, false},
		{"missing start", "", pid, false},
		{"malformed start", "unknown", pid, false},
		{"zero ticks", "0", pid, false},
		{"overflow ticks", "18446744073709551616", pid, false},
	}
	if runtime.GOOS == "linux" {
		ticks, err := platformProcessStartTicks(pid)
		if err != nil {
			t.Fatal(err)
		}
		value, _ := strconv.ParseUint(ticks, 10, 64)
		cases = append(cases,
			testCase{"kernel ticks", ticks, pid, true},
			testCase{"stale ticks", strconv.FormatUint(value+1, 10), pid, false},
		)
	} else {
		cases = append(cases, testCase{"unsupported ticks", "12345", pid, false})
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			config := t.TempDir()
			const id = "f91369d8-9b9b-4424-a0bd-3be2c5b8ed59"
			// The exact session is found by identity, not by the current cwd or
			// the spelling of its project directory at launch.
			transcript := filepath.Join(config, "projects", "launch-path-alias", id+".jsonl")
			registry := filepath.Join(config, "sessions", strconv.Itoa(pid)+".json")
			for _, path := range []string{transcript, registry} {
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(transcript, []byte("{}\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			body, err := json.Marshal(map[string]any{"pid": tc.pid, "sessionId": id, "procStart": tc.start})
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(registry, body, 0o600); err != nil {
				t.Fatal(err)
			}
			gotID, path, _, err := inspectClaude(pid, processState{Environment: map[string]string{"CLAUDE_CONFIG_DIR": config}})
			if tc.valid {
				if err != nil || gotID != id || path != transcript {
					t.Fatalf("valid process transcript = %q %q, %v", gotID, path, err)
				}
			} else if err == nil || gotID != "" || path != "" {
				t.Fatalf("unverified process returned a transcript: %q %q, %v", gotID, path, err)
			}
		})
	}
}
