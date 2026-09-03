package recovery

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

type stringList []string

func (values *stringList) String() string { return strings.Join(*values, ",") }
func (values *stringList) Set(value string) error {
	*values = append(*values, value)
	return nil
}

func writeJSON(writer io.Writer, value any) {
	encoder := json.NewEncoder(writer)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(value)
}

func decodeEntryEdits(values []string) ([]EntryEdit, error) {
	edits := make([]EntryEdit, 0, len(values))
	for _, value := range values {
		var edit EntryEdit
		if err := json.Unmarshal([]byte(value), &edit); err != nil {
			return nil, fmt.Errorf("decode recovery edit: %w", err)
		}
		if strings.TrimSpace(edit.Panel) == "" {
			return nil, fmt.Errorf("decode recovery edit: panel is required")
		}
		edits = append(edits, edit)
	}
	return edits, nil
}

func cliFlags(name string, stderr io.Writer) (*flag.FlagSet, *string) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	socket := flags.String("tmux-socket", "ut", "tmux server socket (-L)")
	return flags, socket
}

// RunCLI implements `ut-broker recovery ...`. It is deliberately available
// without a running HTTP broker, which is the condition immediately after a
// reboot when the desktop Restore button needs it most.
func RunCLI(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: ut-broker recovery <status|capture|restore|bootstrap> [options]")
		return 2
	}
	switch args[0] {
	case "status":
		flags, socket := cliFlags("recovery status", stderr)
		snapshot := flags.String("snapshot", "", "inspect a specific snapshot ID")
		if flags.Parse(args[1:]) != nil {
			return 2
		}
		status := NewStore(*socket).Status(*snapshot)
		writeJSON(stdout, status)
		if status.Error != "" {
			return 1
		}
		return 0
	case "capture":
		flags, socket := cliFlags("recovery capture", stderr)
		if flags.Parse(args[1:]) != nil {
			return 2
		}
		snapshot, err := NewStore(*socket).Capture()
		if err != nil {
			writeJSON(stdout, map[string]any{"error": err.Error()})
			return 1
		}
		writeJSON(stdout, snapshot)
		return 0
	case "restore":
		flags, socket := cliFlags("recovery restore", stderr)
		snapshot := flags.String("snapshot", "", "snapshot ID to restore")
		parallel := flags.Int("parallel", 3, "maximum simultaneous agent starts")
		bootstrap := flags.Bool("bootstrap", true, "start the normal broker supervisor after restoration")
		useCapturedLaunch := flags.Bool(
			"use-captured-launch", false,
			"run the exact snapshot argv for explicitly reviewed panels",
		)
		var sessions stringList
		var editJSON stringList
		flags.Var(&sessions, "session", "panel name to restore (repeatable; default all ready panels)")
		flags.Var(&editJSON, "edit-json", "explicit JSON correction for one panel (repeatable)")
		if flags.Parse(args[1:]) != nil {
			return 2
		}
		if *snapshot == "" {
			fmt.Fprintln(stderr, "recovery restore: --snapshot is required")
			return 2
		}
		store := NewStore(*socket)
		var response RestoreResponse
		if *useCapturedLaunch {
			if len(sessions) == 0 {
				fmt.Fprintln(stderr, "recovery restore: --use-captured-launch requires at least one --session")
				return 2
			}
			response = store.RestoreCapturedLaunch(*snapshot, sessions, *parallel)
		} else if edits, err := decodeEntryEdits(editJSON); err != nil {
			fmt.Fprintln(stderr, "recovery restore:", err)
			return 2
		} else if len(edits) > 0 {
			response = store.RestoreWithEdits(*snapshot, sessions, *parallel, edits)
		} else {
			response = store.Restore(*snapshot, sessions, *parallel)
		}
		if *bootstrap {
			bootstrapSession := ""
			for _, result := range response.Results {
				if result.State == RestoreRestored || result.State == RestoreAlreadyRunning {
					bootstrapSession = result.Name
					break
				}
			}
			// A resumed agent may have started but failed identity verification.
			// Bootstrap from any resulting user panel so Argus can expose the
			// shell and diagnostics instead of leaving a live tmux server dark.
			if err := store.Bootstrap(bootstrapSession); err != nil {
				response.Bootstrap = err.Error()
			} else {
				response.Bootstrap = "started"
			}
		}
		writeJSON(stdout, response)
		for _, result := range response.Results {
			if result.State == RestoreFailed {
				return 1
			}
		}
		if response.Bootstrap != "" && response.Bootstrap != "started" {
			return 1
		}
		return 0
	case "bootstrap":
		flags, socket := cliFlags("recovery bootstrap", stderr)
		session := flags.String("session", "", "existing restored session used to start the broker")
		if flags.Parse(args[1:]) != nil {
			return 2
		}
		err := NewStore(*socket).Bootstrap(*session)
		if err != nil {
			writeJSON(stdout, map[string]any{"ok": false, "error": err.Error()})
			return 1
		}
		writeJSON(stdout, map[string]any{"ok": true})
		return 0
	default:
		fmt.Fprintf(stderr, "unknown recovery command %q\n", args[0])
		return 2
	}
}

func RunCLIForProcess(args []string) int { return RunCLI(args, os.Stdout, os.Stderr) }
