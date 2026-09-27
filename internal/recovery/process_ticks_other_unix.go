//go:build !linux && !windows

package recovery

import "fmt"

func platformProcessStartTicks(pid int) (string, error) {
	return "", fmt.Errorf("kernel process start ticks are unavailable for pid %d on this platform", pid)
}
