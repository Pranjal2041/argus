//go:build !windows

package tmux

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"universal-tmux/internal/toolcommand"
)

// Recovery is exceptional, not a per-refresh process scan. Serialize it so
// concurrent inventory, attach and create calls cannot send a signal storm.
var socketRecoveryGate = make(chan struct{}, 1)

func recoverSocket(ctx context.Context, endpoint string) (bool, error) {
	select {
	case socketRecoveryGate <- struct{}{}:
		defer func() { <-socketRecoveryGate }()
	case <-ctx.Done():
		return false, ctx.Err()
	}
	owners, err := socketOwners(ctx, endpoint)
	if err != nil {
		return false, err // an incomplete scan never proves an empty workspace
	}
	if len(owners) == 0 {
		return false, nil
	}
	if len(owners) != 1 {
		return false, fmt.Errorf("ambiguous live owners of %q: %v", endpoint, owners)
	}
	if info, err := os.Lstat(endpoint); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return false, fmt.Errorf("refusing recovery over non-socket %q", endpoint)
		}
		return true, nil // another caller already recovered it; retry the read
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	pid := owners[0]
	identity, err := socketOwnerIdentity(ctx, pid)
	if err != nil {
		return false, err
	}
	if err := ensureSocketDirectory(endpoint); err != nil {
		return false, err
	}
	// Recheck both the bound descriptor and process incarnation immediately
	// before signaling. Never signal by name, remembered PID alone, or hostname.
	owners, err = socketOwners(ctx, endpoint)
	if err != nil || len(owners) != 1 || owners[0] != pid {
		return false, fmt.Errorf("socket owner changed during recovery: %v", err)
	}
	current, err := socketOwnerIdentity(ctx, pid)
	if err != nil || current != identity {
		return false, fmt.Errorf("process identity changed during recovery: %v", err)
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if _, err := os.Lstat(endpoint); err == nil {
		return true, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	// tmux documents SIGUSR1 as recreating an accidentally removed socket.
	// It leaves the server, pane processes and session identities untouched.
	if err := syscall.Kill(pid, syscall.SIGUSR1); err != nil {
		return false, fmt.Errorf("recreate socket for server %d: %w", pid, err)
	}
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-timer.C:
			return false, fmt.Errorf("server %d has not restored %q", pid, endpoint)
		case <-tick.C:
			if info, err := os.Lstat(endpoint); err == nil && info.Mode()&os.ModeSocket != 0 {
				log.Printf("recovered tmux transport %q on existing server %d; sessions preserved", endpoint, pid)
				return true, nil
			}
		}
	}
}

func socketOwners(ctx context.Context, endpoint string) ([]int, error) {
	// -a is essential: lsof otherwise ORs the user, command and UNIX filters.
	cmd := toolcommand.CommandContext(ctx, "lsof", "-nP", "-a", "-U", "-u", strconv.Itoa(os.Geteuid()), "-c", "tmux", "-Fpcun")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if stderr.Len() != 0 {
		return nil, fmt.Errorf("incomplete socket owner scan: %s", strings.TrimSpace(stderr.String()))
	}
	if err != nil {
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 1 || len(out) != 0 {
			return nil, fmt.Errorf("inspect live socket owners: %w", err)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return parseSocketOwners(string(out), endpoint, os.Geteuid()), nil
}

func canonicalSocket(path string) string {
	// Resolve existing ancestors even if the private socket directory vanished.
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	parent := filepath.Dir(path)
	if parent == path {
		return filepath.Clean(path)
	}
	return filepath.Join(canonicalSocket(parent), filepath.Base(path))
}

func parseSocketOwners(output, endpoint string, uid int) []int {
	endpoint = canonicalSocket(endpoint)
	seen := map[int]bool{}
	var owners []int
	pid, ownerUID, command := 0, -1, ""
	for _, line := range strings.Split(output, "\n") {
		if len(line) < 2 {
			continue
		}
		switch line[0] {
		case 'p':
			pid, _ = strconv.Atoi(line[1:])
			ownerUID, command = -1, ""
		case 'u':
			var err error
			ownerUID, err = strconv.Atoi(line[1:])
			if err != nil {
				ownerUID = -1
			}
		case 'c':
			command = line[1:]
		case 'n':
			if pid > 1 && ownerUID == uid && (command == "tmux" || strings.HasPrefix(command, "tmux: ")) &&
				filepath.IsAbs(line[1:]) && canonicalSocket(line[1:]) == endpoint && !seen[pid] {
				seen[pid] = true
				owners = append(owners, pid)
			}
		}
	}
	return owners
}

func socketOwnerIdentity(ctx context.Context, pid int) (string, error) {
	out, err := toolcommand.CommandContext(ctx, "ps", "-p", strconv.Itoa(pid), "-o", "uid=", "-o", "lstart=", "-o", "comm=").Output()
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) < 7 || fields[0] != strconv.Itoa(os.Geteuid()) {
		return "", fmt.Errorf("cannot verify socket owner %d", pid)
	}
	return strings.TrimSpace(string(out)), nil
}

func ensureSocketDirectory(endpoint string) error {
	dir := filepath.Dir(endpoint)
	// Only recreate the immediate private directory. Missing ancestors or a
	// foreign/symlinked directory need an error, not recursive filesystem edits.
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return fmt.Errorf("restore socket directory: %w", err)
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || stat.Uid != uint32(os.Geteuid()) || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("socket directory %q is not private and owned by this user", dir)
	}
	return nil
}
