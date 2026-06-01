//go:build darwin

package portfwd

import (
	"os/exec"
	"strconv"
	"strings"
)

// listeningPorts parses `lsof -nP -iTCP -sTCP:LISTEN`. Columns:
// COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME(addr:port)
func listeningPorts() []PortInfo {
	out, err := exec.Command("lsof", "-nP", "-iTCP", "-sTCP:LISTEN").Output()
	if err != nil {
		return nil
	}
	var res []PortInfo
	seen := map[int]bool{}
	lines := strings.Split(string(out), "\n")
	for _, line := range lines {
		f := strings.Fields(line)
		if len(f) < 9 || f[0] == "COMMAND" {
			continue
		}
		// The NAME (addr:port) is followed by the state "(LISTEN)"; find the
		// addr:port field (has a colon, not a paren).
		name := ""
		for j := len(f) - 1; j >= 8; j-- {
			if strings.Contains(f[j], ":") && !strings.HasPrefix(f[j], "(") {
				name = f[j]
				break
			}
		}
		i := strings.LastIndex(name, ":")
		if i < 0 {
			continue
		}
		port, err := strconv.Atoi(name[i+1:])
		if err != nil || port == 0 || seen[port] {
			continue
		}
		seen[port] = true
		pid, _ := strconv.Atoi(f[1])
		res = append(res, PortInfo{Port: port, Address: strings.Trim(name[:i], "[]"), Process: f[0], PID: pid})
	}
	return res
}
