//go:build windows

package portfwd

import (
	"os/exec"
	"strconv"
	"strings"
)

// listeningPorts parses `netstat -ano` (all TCP LISTENING rows, IPv4 AND IPv6)
// and maps PIDs to process names via tasklist. We deliberately do NOT pass
// `-p TCP`: on Windows that filter is IPv4-only and hides IPv6 listeners such as
// `[::]:8000`, which is the default bind for Node, `serve`, .NET/Kestrel, etc.
// UDP rows have no LISTENING state, so the state filter excludes them.
func listeningPorts() []PortInfo {
	out, err := exec.Command("netstat", "-ano").Output()
	if err != nil {
		return nil
	}
	names := pidNames()
	var res []PortInfo
	seen := map[int]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		// Rows: `TCP  0.0.0.0:8000  0.0.0.0:0  LISTENING  5678` or the IPv6
		// form `TCP  [::]:8000  [::]:0  LISTENING  5678` (proto may be TCPv6).
		if len(f) < 5 || !strings.HasPrefix(strings.ToUpper(f[0]), "TCP") || !strings.EqualFold(f[3], "LISTENING") {
			continue
		}
		local := f[1]
		i := strings.LastIndex(local, ":")
		if i < 0 {
			continue
		}
		port, err := strconv.Atoi(local[i+1:])
		if err != nil || port == 0 || seen[port] {
			continue
		}
		seen[port] = true
		pid, _ := strconv.Atoi(f[4])
		res = append(res, PortInfo{Port: port, Address: strings.Trim(local[:i], "[]"), Process: names[pid], PID: pid})
	}
	return res
}

func pidNames() map[int]string {
	m := map[int]string{}
	out, err := exec.Command("tasklist", "/fo", "csv", "/nh").Output()
	if err != nil {
		return m
	}
	for _, line := range strings.Split(string(out), "\n") {
		parts := strings.Split(line, "\",\"") // "name.exe","1234",...
		if len(parts) < 2 {
			continue
		}
		pid, err := strconv.Atoi(strings.Trim(parts[1], "\" \r"))
		if err == nil {
			m[pid] = strings.Trim(parts[0], "\"")
		}
	}
	return m
}
