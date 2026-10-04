package workspace

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"universal-tmux/internal/statedir"
)

// DefaultRoot isolates broker instances on shared homes without making a
// mutable display name, IP address or hostname their identity. UT_MACHINE_ID is
// an explicit installation identity for platforms without an OS machine ID.
func DefaultRoot(socket string) (string, error) {
	id := strings.TrimSpace(os.Getenv("UT_MACHINE_ID"))
	if id == "" {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		switch runtime.GOOS {
		case "linux":
			for _, p := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
				if b, err := os.ReadFile(p); err == nil && strings.TrimSpace(string(b)) != "" {
					id = strings.TrimSpace(string(b))
					break
				}
			}
		case "darwin":
			b, err := exec.CommandContext(ctx, "/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
			if err == nil {
				for _, line := range strings.Split(string(b), "\n") {
					if strings.Contains(line, `"IOPlatformUUID"`) {
						_, value, ok := strings.Cut(line, "=")
						if ok {
							id = strings.Trim(strings.TrimSpace(value), `"`)
						}
						break
					}
				}
			}
		case "windows":
			b, err := exec.CommandContext(ctx, "reg.exe", "query", `HKLM\SOFTWARE\Microsoft\Cryptography`, "/v", "MachineGuid").Output()
			if err == nil {
				for _, line := range strings.Split(string(b), "\n") {
					fields := strings.Fields(line)
					if len(fields) == 3 && fields[0] == "MachineGuid" {
						id = fields[2]
					}
				}
			}
		}
	}
	if id == "" {
		return "", errors.New("cannot establish a stable broker identity; configure UT_MACHINE_ID")
	}
	h := sha256.Sum256([]byte(id + "\x00" + socket))
	return filepath.Join(statedir.Dir(), "workspaces", hex.EncodeToString(h[:16])), nil
}
