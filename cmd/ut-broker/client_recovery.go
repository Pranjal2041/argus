package main

import (
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
	if len(args) == 0 || args[0] != "transfer" {
		fmt.Fprintln(os.Stderr, "usage: ut recovery transfer --source <machine|.> --target <machine|.> --snapshot <id> [--tmux-socket <socket>]")
		return 2
	}
	flags := flag.NewFlagSet("recovery transfer", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	source := flags.String("source", "", "machine that currently exposes the snapshot")
	target := flags.String("target", "", "machine that should stage the snapshot")
	snapshot := flags.String("snapshot", "", "exact recovery snapshot ID")
	socket := flags.String("tmux-socket", "ut", "tmux server socket (-L)")
	if flags.Parse(args[1:]) != nil {
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
