package conpty

import (
	"reflect"
	"testing"
)

func TestSessionEnvironmentSeparatesLauncherPolicyFromTerminalIdentity(t *testing.T) {
	base := []string{"NO_COLOR=1", "FORCE_COLOR=0", "CLICOLOR=0", "CLICOLOR_FORCE=1",
		"Path=C:\\tools", "APP_SETTING=keep", "TERM=xterm-256color", "COLORTERM=truecolor",
		"UT_SESSION_LINEAGE_ID=parent", "ut_session_lineage_id=also-parent"}
	want := []string{"Path=C:\\tools", "APP_SETTING=keep", "TERM=xterm-256color", "COLORTERM=truecolor",
		"UT_SESSION_LINEAGE_ID=new-terminal"}
	if got := sessionEnvironment(base, "new-terminal"); !reflect.DeepEqual(got, want) {
		t.Fatalf("ConPTY child environment = %q", got)
	}
}
