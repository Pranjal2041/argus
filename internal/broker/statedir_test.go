package broker

import (
	"path/filepath"
	"strings"
	"testing"
)

// Two brokers sharing a host and a home (a second install under a shared login)
// must not share durable state: every per-instance file follows UT_STATE_DIR.
func TestBrokerStateFollowsInstanceStateDir(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	state := filepath.Join(t.TempDir(), "second-install")
	t.Setenv("UT_STATE_DIR", state)
	for name, path := range map[string]string{
		"history":       historyStatePath(),
		"hidden":        hiddenStatePath(),
		"journal inbox": journalInboxPath(),
		"user data":     userDataPath("notes"),
	} {
		if !strings.HasPrefix(path, state+string(filepath.Separator)) {
			t.Errorf("%s path %q is outside instance state dir %q", name, path, state)
		}
	}
}
