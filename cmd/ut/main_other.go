//go:build !windows

package main

import "fmt"

// On Unix the drop-in for tmux is the `ut` shell script (it execs `tmux attach`).
// This binary is the Windows console client; on other platforms it's a no-op.
func main() {
	fmt.Println("ut.exe is the Windows console client; on Unix use the `ut` shell script.")
}
