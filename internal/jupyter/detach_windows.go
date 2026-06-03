//go:build windows

package jupyter

import "syscall"

// detachAttr: on Windows a new process group keeps the child off the broker's
// Ctrl-C/teardown. (Exp 0 targets Mac + Babel; Windows Jupyter is later.)
func detachAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{CreationFlags: 0x00000200} // CREATE_NEW_PROCESS_GROUP
}

// killProcessGroup: cmd.Process.Kill at the call site handles the main process on
// Windows; group teardown is best-effort here (Exp 0 targets Mac + Babel).
func killProcessGroup(pid int) {}
