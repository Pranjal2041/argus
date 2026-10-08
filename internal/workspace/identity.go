package workspace

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"universal-tmux/internal/statedir"
)

// DefaultRoot resolves a local installation. Network runtimes should supply
// their durable installation identity through DefaultRootForInstallation.
func DefaultRoot(socket string) (string, error) {
	return DefaultRootForInstallation(socket, "")
}

// DefaultRootForInstallation isolates installations even when they share a home
// and a cloned OS machine ID. installationID must be an opaque, durable runtime
// identity, never a display name, address, hostname, or process/boot identifier.
// UT_MACHINE_ID remains an explicit operator override. Local installations keep
// their existing OS-derived roots; a runtime identity must not silently fall
// back to an OS identity when its runtime cannot supply it.
func DefaultRootForInstallation(socket, installationID string) (string, error) {
	return resolveInstallationRoot(statedir.Dir(), socket, os.Getenv("UT_MACHINE_ID"), installationID, osMachineIdentity)
}

func resolveInstallationRoot(stateDir, socket, override, installationID string, machineIdentity func() string) (string, error) {
	root, err := resolveRoot(stateDir, socket, override, installationID, machineIdentity)
	if err != nil || strings.TrimSpace(override) != "" || strings.TrimSpace(installationID) == "" {
		return root, err
	}
	if _, err := os.Stat(root); err == nil {
		return root, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	legacy, err := resolveRoot(stateDir, socket, "", "", machineIdentity)
	if err != nil { // A runtime installation does not require an OS machine ID.
		return root, nil
	}
	if _, err := os.Stat(filepath.Join(legacy, "workspace.db")); err == nil {
		// A cloned OS identity on a shared home can belong to a DIFFERENT
		// installation. Neither copying it nor silently minting new IDs is safe.
		return "", fmt.Errorf("workspace identity migration required: verify ownership of %q, then map it to %q; create a new root explicitly only for a distinct installation", legacy, root)
	} else if !os.IsNotExist(err) {
		return "", err
	}
	return root, nil
}

func resolveRoot(stateDir, socket, override, installationID string, machineIdentity func() string) (string, error) {
	id := strings.TrimSpace(override)
	if id == "" {
		id = strings.TrimSpace(installationID)
	}
	if id == "" {
		id = strings.TrimSpace(machineIdentity())
	}
	if id == "" {
		return "", errors.New("cannot establish a stable broker identity; configure UT_MACHINE_ID")
	}
	h := sha256.Sum256([]byte(id + "\x00" + socket))
	return filepath.Join(stateDir, "workspaces", hex.EncodeToString(h[:16])), nil
}

func osMachineIdentity() string {
	id := ""
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
	return id
}
