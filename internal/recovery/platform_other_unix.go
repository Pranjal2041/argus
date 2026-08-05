//go:build !darwin && !linux && !windows

package recovery

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func platformBootID() (string, error) {
	host, err := os.Hostname()
	return "unix-" + host, err
}

func platformProcessStart(pid int) (time.Time, error) { return processStartViaPS(pid) }

func platformProcessState(pid int) (processState, error) {
	out, err := exec.Command(toolPath("ps"), "-ww", "-p", strconv.Itoa(pid), "-o", "command=").Output()
	if err != nil {
		return processState{}, err
	}
	return processState{}, fmt.Errorf("exact kernel argv is not implemented on this Unix (%s)", strings.TrimSpace(string(out)))
}

func platformOpenFiles(pid int) ([]string, error) {
	out, err := exec.Command(toolPath("lsof"), "-n", "-Fn", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "n/") {
			paths = append(paths, line[1:])
		}
	}
	return paths, nil
}
