//go:build linux

package recovery

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func platformBootID() (string, error) {
	body, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "", err
	}
	return "linux-" + strings.TrimSpace(string(body)), nil
}

func platformProcessStart(pid int) (time.Time, error) {
	return processStartViaPS(pid)
}

func platformProcessDirectory(pid int) (string, error) {
	return os.Readlink(filepath.Join("/proc", strconv.Itoa(pid), "cwd"))
}

func platformProcessDirectories(pids []int) map[int]string {
	directories := make(map[int]string, len(pids))
	for _, pid := range pids {
		if directory, err := platformProcessDirectory(pid); err == nil {
			directories[pid] = directory
		}
	}
	return directories
}

func platformProcessState(pid int) (processState, error) {
	root := filepath.Join("/proc", strconv.Itoa(pid))
	executable, err := os.Readlink(filepath.Join(root, "exe"))
	if err != nil {
		return processState{}, err
	}
	cmdline, err := os.ReadFile(filepath.Join(root, "cmdline"))
	if err != nil {
		return processState{}, err
	}
	environ, err := os.ReadFile(filepath.Join(root, "environ"))
	if err != nil {
		return processState{}, err
	}
	state := processState{Executable: executable, Environment: map[string]string{}}
	for _, value := range strings.Split(string(cmdline), "\x00") {
		if value != "" {
			state.Argv = append(state.Argv, value)
		}
	}
	for _, value := range strings.Split(string(environ), "\x00") {
		if key, item, ok := strings.Cut(value, "="); ok {
			state.Environment[key] = item
		}
	}
	if len(state.Argv) == 0 {
		return processState{}, fmt.Errorf("empty process argv")
	}
	return state, nil
}

func platformOpenFiles(pid int) ([]string, error) {
	directory := filepath.Join("/proc", strconv.Itoa(pid), "fd")
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if path, err := os.Readlink(filepath.Join(directory, entry.Name())); err == nil {
			paths = append(paths, path)
		}
	}
	return paths, nil
}
