package recovery

import "testing"

func TestSubcommandRoleFollowsOptionArityAcrossAdapters(t *testing.T) {
	for _, tc := range []struct {
		argv  []string
		specs map[string]optionSpec
		want  string
	}{
		{[]string{"devin", "acp"}, devinRestoreOptions, "acp"},
		{[]string{"devin", "--config", "/private/profile.json", "acp"}, devinRestoreOptions, "acp"},
		{[]string{"devin", "--config=/profile.json", "--model", "configured", "--sandbox", "acp"}, devinRestoreOptions, "acp"},
		{[]string{"devin", "--config", "acp"}, devinRestoreOptions, ""},
		{[]string{"devin", "--model=acp"}, devinRestoreOptions, ""},
		{[]string{"devin", "--", "acp"}, devinRestoreOptions, ""},
		{[]string{"devin", "--unknown", "acp"}, devinRestoreOptions, ""},
		{[]string{"devin", "--config"}, devinRestoreOptions, ""},
		{[]string{"codex", "-c", "some.setting=acp", "--no-alt-screen", "resume", "thread"}, codexRestoreOptions, "resume"},
		{[]string{"custom", "--profile", "serve", "run"}, map[string]optionSpec{"--profile": {1}}, "run"},
	} {
		if got := leadingSubcommand(tc.argv, tc.specs); got != tc.want {
			t.Errorf("%q: got %q, want %q", tc.argv, got, tc.want)
		}
	}
}
