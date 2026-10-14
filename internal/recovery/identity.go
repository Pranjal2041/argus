package recovery

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
)

// The HTTP runtime can own an identity independent of the OS (for example two
// isolated runtimes on one host). A node-local binding lets the offline recovery
// CLI inspect that same store without requiring a live HTTP listener. It is
// scoped by state root, socket and explicit identity override, never hostname.
func localIdentityPath(root, socket string, explicitPort ...string) string {
	directory := os.Getenv("UT_LOCAL_DIR")
	if directory == "" {
		name := os.Getenv("USER")
		if current, err := user.Current(); err == nil {
			name = current.Username
		}
		base := "/tmp"
		if runtime.GOOS == "windows" {
			base = os.TempDir()
		}
		directory = filepath.Join(base, "ut-"+safeComponent(name))
	}
	absolute, err := filepath.Abs(root)
	if err != nil {
		absolute = root
	}
	port := os.Getenv("UT_LOCAL_PORT")
	if port == "" {
		port = os.Getenv("UT_PORT")
	}
	if port == "" {
		port = "8722"
	}
	if len(explicitPort) > 0 && explicitPort[0] != "" {
		port = explicitPort[0]
	}
	scope := sha256.Sum256([]byte(absolute + "\x00" + socket + "\x00" + port + "\x00" + os.Getenv("UT_MACHINE_ID")))
	return filepath.Join(directory, "recovery-identity-"+hex.EncodeToString(scope[:16]))
}

func localRecoveryIdentity(root, socket string) string {
	body, err := os.ReadFile(localIdentityPath(root, socket))
	if err != nil {
		return ""
	}
	key := strings.TrimSpace(string(body))
	decoded, err := hex.DecodeString(key)
	if err != nil || len(decoded) != 16 {
		return ""
	}
	return key
}

// BindLocalIdentity is called by the broker once it has established its actual
// installation identity. Constructing a Store alone never changes this binding.
func (s *Store) BindLocalIdentity(port ...string) error {
	if s.identityError != nil {
		return s.identityError
	}
	if s.InstallationID == "" {
		return fmt.Errorf("recovery installation identity is missing")
	}
	return writeAtomic(localIdentityPath(s.Root, s.Socket, port...), []byte(s.InstallationID+"\n"), 0o600)
}

func (s *Store) ownsSnapshot(snapshot Snapshot) bool {
	if s.InstallationID != "" || snapshot.InstallationID != "" {
		return s.InstallationID != "" && s.InstallationID == snapshot.InstallationID
	}
	// Legacy stores/fixtures retain their old semantics. New installation stores
	// never infer ownership of an untagged snapshot from a matching display name.
	return sameRecoveryHost(snapshot.Host, s.Host)
}
