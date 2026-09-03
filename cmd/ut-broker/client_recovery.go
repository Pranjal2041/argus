package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"
)

func recoveryRoute(value string) string {
	value = strings.TrimSpace(strings.TrimPrefix(value, "@"))
	if value == "." || strings.EqualFold(value, "local") {
		return ""
	}
	return value
}

func cmdRecovery(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: ut recovery <transfer|remote> ...")
		return 2
	}
	switch args[0] {
	case "transfer":
		return cmdRecoveryTransfer(args[1:])
	case "remote":
		return cmdRecoveryRemote(args[1:])
	default:
		fmt.Fprintln(os.Stderr, "usage: ut recovery <transfer|remote> ...")
		return 2
	}
}

func cmdRecoveryTransfer(args []string) int {
	flags := flag.NewFlagSet("recovery transfer", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	source := flags.String("source", "", "machine that currently exposes the snapshot")
	target := flags.String("target", "", "machine that should stage the snapshot")
	snapshot := flags.String("snapshot", "", "exact recovery snapshot ID")
	socket := flags.String("tmux-socket", "ut", "tmux server socket (-L)")
	if flags.Parse(args) != nil {
		return 2
	}
	if *source == "" || *target == "" || *snapshot == "" {
		fmt.Fprintln(os.Stderr, "recovery transfer: --source, --target, and --snapshot are required")
		return 2
	}
	query := url.Values{"id": {*snapshot}, "socket": {*socket}}
	body, code, err := httpGet(peerURL(recoveryRoute(*source), "/recovery/snapshot", query), 30*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "recovery transfer: read source: %v\n", err)
		return 1
	}
	if code != 200 {
		fmt.Fprintf(os.Stderr, "recovery transfer: source returned %s\n", responseError(body, code))
		return 1
	}
	targetQuery := url.Values{"socket": {*socket}}
	result, code, err := httpPost(peerURL(recoveryRoute(*target), "/recovery/snapshot", targetQuery), body, 30*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "recovery transfer: write target: %v\n", err)
		return 1
	}
	if code != 200 {
		fmt.Fprintf(os.Stderr, "recovery transfer: target returned %s\n", responseError(result, code))
		return 1
	}
	_, _ = os.Stdout.Write(result)
	return 0
}

type recoverySessionList []string

func (values *recoverySessionList) String() string { return strings.Join(*values, ",") }
func (values *recoverySessionList) Set(value string) error {
	*values = append(*values, value)
	return nil
}

// cmdRecoveryRemote invokes recovery through the target broker rather than by
// guessing a remote executable path or shell syntax. The operation therefore
// runs beside whichever backend owns the sessions (tmux or ConPTY).
func cmdRecoveryRemote(args []string) int {
	flags := flag.NewFlagSet("recovery remote", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	target := flags.String("target", "", "machine whose running broker owns the recovery operation")
	if flags.Parse(args) != nil {
		return 2
	}
	rest := flags.Args()
	if *target == "" || len(rest) == 0 {
		fmt.Fprintln(os.Stderr, "usage: ut recovery remote --target <machine> <status|restore> [options]")
		return 2
	}
	switch rest[0] {
	case "status":
		statusFlags := flag.NewFlagSet("recovery remote status", flag.ContinueOnError)
		statusFlags.SetOutput(os.Stderr)
		socket := statusFlags.String("tmux-socket", "ut", "session socket")
		snapshot := statusFlags.String("snapshot", "", "snapshot ID to inspect")
		if statusFlags.Parse(rest[1:]) != nil {
			return 2
		}
		query := url.Values{"socket": {*socket}}
		if *snapshot != "" {
			query.Set("snapshot", *snapshot)
		}
		body, code, err := httpGet(peerURL(recoveryRoute(*target), "/recovery/status", query), 30*time.Second)
		if err != nil {
			fmt.Fprintf(os.Stderr, "recovery status: %v\n", err)
			return 1
		}
		if code != 200 {
			fmt.Fprintf(os.Stderr, "recovery status: target returned %s\n", responseError(body, code))
			return 1
		}
		_, _ = os.Stdout.Write(body)
		return 0
	case "restore":
		restoreFlags := flag.NewFlagSet("recovery remote restore", flag.ContinueOnError)
		restoreFlags.SetOutput(os.Stderr)
		socket := restoreFlags.String("tmux-socket", "ut", "session socket")
		snapshot := restoreFlags.String("snapshot", "", "snapshot ID to restore")
		parallel := restoreFlags.Int("parallel", 3, "maximum simultaneous starts")
		_ = restoreFlags.Bool("bootstrap", false, "broker is already running for remote restore")
		captured := restoreFlags.Bool("use-captured-launch", false, "run explicitly reviewed captured launch")
		var sessions recoverySessionList
		var editJSON recoverySessionList
		restoreFlags.Var(&sessions, "session", "panel name to restore")
		restoreFlags.Var(&editJSON, "edit-json", "explicit JSON correction for one panel")
		if restoreFlags.Parse(rest[1:]) != nil {
			return 2
		}
		if *snapshot == "" {
			fmt.Fprintln(os.Stderr, "recovery remote restore: --snapshot is required")
			return 2
		}
		edits := make([]json.RawMessage, 0, len(editJSON))
		for _, value := range editJSON {
			var edit json.RawMessage
			if !json.Valid([]byte(value)) {
				fmt.Fprintln(os.Stderr, "recovery restore: --edit-json must contain valid JSON")
				return 2
			}
			edit = append(edit, value...)
			edits = append(edits, edit)
		}
		body, err := json.Marshal(map[string]any{
			"snapshotId": *snapshot, "sessions": []string(sessions),
			"concurrency": *parallel, "useCapturedLaunch": *captured, "edits": edits,
		})
		if err != nil {
			fmt.Fprintf(os.Stderr, "recovery restore: %v\n", err)
			return 1
		}
		result, code, err := httpPost(
			peerURL(recoveryRoute(*target), "/recovery/restore", url.Values{"socket": {*socket}}),
			body, 3*time.Minute,
		)
		if err != nil {
			fmt.Fprintf(os.Stderr, "recovery restore: %v\n", err)
			return 1
		}
		if code != 200 {
			fmt.Fprintf(os.Stderr, "recovery restore: target returned %s\n", responseError(result, code))
			return 1
		}
		_, _ = os.Stdout.Write(result)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "recovery remote: unknown operation %q\n", rest[0])
		return 2
	}
}
