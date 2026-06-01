//go:build windows

package fsvc

import "os"

// systemRoots probes A:..Z: for existing drives (no extra syscalls/deps).
func systemRoots() []string {
	var roots []string
	for c := byte('A'); c <= 'Z'; c++ {
		d := string(c) + ":\\"
		if _, err := os.Stat(d); err == nil {
			roots = append(roots, d)
		}
	}
	if len(roots) == 0 {
		roots = []string{"C:\\"}
	}
	return roots
}
