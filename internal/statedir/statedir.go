// Package statedir resolves the root of one broker instance's durable state
// (session history, hidden sessions, journal inbox, synced user data, workspace
// recovery, visibility, web artifacts).
//
// Files beneath it are already keyed by host so one root can live on a shared
// home (NFS). UT_STATE_DIR separates brokers that share a host AND a home — a
// second install under a shared login — the way `tmux -L` separates servers.
package statedir

import (
	"os"
	"path/filepath"
)

// Dir returns $UT_STATE_DIR when set, else ~/.universal-tmux (under the temp
// dir when no home is known). It does not create the directory.
func Dir() string {
	if dir := os.Getenv("UT_STATE_DIR"); dir != "" {
		return dir
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	return filepath.Join(home, ".universal-tmux")
}
