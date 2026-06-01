//go:build linux

package portfwd

import (
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

var ssProcRe = regexp.MustCompile(`"([^"]+)",pid=(\d+)`)

// listeningPorts parses `ss -ltnpH` (listening TCP, numeric, with process, no
// header). As a normal user it shows that user's process info; system ports
// appear without it. Returns everything — the UI filters.
func listeningPorts() []PortInfo {
	out, err := exec.Command("ss", "-ltnpH").Output()
	if err != nil {
		return nil
	}
	var res []PortInfo
	seen := map[int]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		local := f[3] // e.g. 127.0.0.1:7000 or *:8080 or [::]:22
		i := strings.LastIndex(local, ":")
		if i < 0 {
			continue
		}
		port, err := strconv.Atoi(local[i+1:])
		if err != nil || port == 0 || seen[port] {
			continue
		}
		seen[port] = true
		addr := strings.Trim(local[:i], "[]")
		proc, pid := "", 0
		if m := ssProcRe.FindStringSubmatch(line); m != nil {
			proc = m[1]
			pid, _ = strconv.Atoi(m[2])
		}
		res = append(res, PortInfo{Port: port, Address: addr, Process: proc, PID: pid})
	}
	return res
}
