//go:build !windows

package recovery

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func processStartViaPS(pid int) (time.Time, error) {
	out, err := exec.Command(toolPath("ps"), "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
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
