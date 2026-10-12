package terminalenv

import (
	"reflect"
	"testing"
)

func TestInteractiveEnvironmentIsIndependentOfLauncherOutputPolicy(t *testing.T) {
	for _, windows := range []bool{false, true} {
		base := []string{"PATH=/tools", "TERM=tmux-256color", "COLORTERM=truecolor", "TOKEN=private=value",
			"NO_COLOR=1", "NO_COLOR=", "CLICOLOR=0", "CLICOLOR_FORCE=1", "FORCE_COLOR=0", "APP_SETTING=keep"}
		original := append([]string(nil), base...)
		want := []string{"PATH=/tools", "TERM=tmux-256color", "COLORTERM=truecolor", "TOKEN=private=value", "APP_SETTING=keep"}
		if got := interactive(base, windows); !reflect.DeepEqual(got, want) {
			t.Fatalf("windows=%v: environment = %v", windows, got)
		}
		if !reflect.DeepEqual(base, original) {
			t.Fatal("changed the launcher's environment")
		}
	}
}

func TestEnvironmentKeyCasingFollowsPlatform(t *testing.T) {
	base := []string{"No_Color=1", "Force_Color=0", "Path=/tools"}
	if got := interactive(base, false); !reflect.DeepEqual(got, base) {
		t.Fatalf("Unix environment keys are case sensitive: %v", got)
	}
	if got := interactive(base, true); !reflect.DeepEqual(got, []string{"Path=/tools"}) {
		t.Fatalf("Windows environment keys are case insensitive: %v", got)
	}
}

func TestTmuxRemovesOverridesBeforeFirstPaneWithoutChangingExplicitCommand(t *testing.T) {
	command := []string{"-d", "-s", "work", "sh", "-c", "NO_COLOR=1 my-program"}
	got := TmuxNewSession(command...)
	want := []string{}
	for _, key := range colorOverrides {
		want = append(want, "set-environment", "-gu", key, ";")
	}
	want = append(want, "new-session")
	want = append(want, command...)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("creation sequence = %q", got)
	}
}
