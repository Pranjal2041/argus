//go:build darwin

package recovery

import (
	"encoding/binary"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

func platformBootID() (string, error) {
	value, err := unix.SysctlTimeval("kern.boottime")
	if err != nil {
		return "", err
	}
	return "darwin-" + strconv.FormatInt(value.Sec, 10), nil
}

func platformProcessStart(pid int) (time.Time, error) {
	process, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return time.Time{}, err
	}
	return time.Unix(process.Proc.P_starttime.Sec, int64(process.Proc.P_starttime.Usec)*1000), nil
}

func darwinProcArgs(pid int) ([]byte, error) {
	const (
		ctlKern       = 1
		kernProcArgs2 = 49
	)
	mib := [3]int32{ctlKern, kernProcArgs2, int32(pid)}
	var size uintptr
	_, _, errno := unix.Syscall6(
		unix.SYS_SYSCTL,
		uintptr(unsafe.Pointer(&mib[0])), uintptr(len(mib)),
		0, uintptr(unsafe.Pointer(&size)), 0, 0,
	)
	if errno != 0 {
		return nil, errno
	}
	if size == 0 {
		return nil, fmt.Errorf("empty KERN_PROCARGS2 result")
	}
	buffer := make([]byte, size)
	_, _, errno = unix.Syscall6(
		unix.SYS_SYSCTL,
		uintptr(unsafe.Pointer(&mib[0])), uintptr(len(mib)),
		uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)), 0, 0,
	)
	if errno != 0 {
		return nil, errno
	}
	return buffer[:size], nil
}

func nulEnd(data []byte, start int) int {
	for index := start; index < len(data); index++ {
		if data[index] == 0 {
			return index
		}
	}
	return -1
}

func platformProcessState(pid int) (processState, error) {
	raw, err := darwinProcArgs(pid)
	if err != nil {
		return processState{}, err
	}
	if len(raw) < 4 {
		return processState{}, fmt.Errorf("truncated KERN_PROCARGS2 result")
	}
	argc := int(int32(binary.LittleEndian.Uint32(raw[:4])))
	position := 4
	end := nulEnd(raw, position)
	if end < 0 {
		return processState{}, fmt.Errorf("malformed executable path")
	}
	state := processState{Executable: string(raw[position:end]), Environment: map[string]string{}}
	position = end + 1
	for position < len(raw) && raw[position] == 0 {
		position++
	}
	values := make([]string, 0, argc+16)
	for position < len(raw) {
		end = nulEnd(raw, position)
		if end < 0 {
			end = len(raw)
		}
		values = append(values, string(raw[position:end]))
		position = end + 1
	}
	if argc < 0 || len(values) < argc {
		return processState{}, fmt.Errorf("kernel returned %d of %d argv values", len(values), argc)
	}
	state.Argv = append([]string(nil), values[:argc]...)
	for _, value := range values[argc:] {
		if key, item, ok := strings.Cut(value, "="); ok {
			state.Environment[key] = item
		}
	}
	return state, nil
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
