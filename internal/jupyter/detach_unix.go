//go:build !windows

package jupyter

import "syscall"

// detachAttr puts the JupyterLab process in its own process group so it isn't
// signalled when the broker (its parent) is killed/restarted — it keeps running
// and the next broker re-adopts it from the state file.
func detachAttr() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setpgid: true} }

// killProcessGroup SIGKILLs the whole group led by pid (negative pid = the group),
// reaping jupyter-lab and any children when a launch times out.
func killProcessGroup(pid int) { _ = syscall.Kill(-pid, syscall.SIGKILL) }
