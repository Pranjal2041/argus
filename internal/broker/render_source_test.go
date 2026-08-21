package broker

import "testing"

type staleRenderDirectoryProvider struct{ warmProvider }

func (*staleRenderDirectoryProvider) RenderWorkingDirectory(string) (string, bool) {
	return "", false
}

type liveRenderDirectoryProvider struct{ warmProvider }

func (*liveRenderDirectoryProvider) RenderWorkingDirectory(string) (string, bool) {
	return `C:\Users\pranjala\spatial_bench`, true
}

func TestRenderWorkingDirectoryRejectsStaleBackendPath(t *testing.T) {
	provider := &staleRenderDirectoryProvider{}
	if got := renderWorkingDirectory(provider, "spatial_ue", `C:\Users\pranjala`); got != "" {
		t.Fatalf("stale ConPTY directory remained authoritative: %q", got)
	}
}

func TestRenderWorkingDirectoryUsesLiveBackendPath(t *testing.T) {
	provider := &liveRenderDirectoryProvider{}
	want := `C:\Users\pranjala\spatial_bench`
	if got := renderWorkingDirectory(provider, "spatial_ue", `C:\Users\pranjala`); got != want {
		t.Fatalf("render cwd = %q, want %q", got, want)
	}
}

func TestRenderWorkingDirectoryKeepsCachedPathForExistingBackends(t *testing.T) {
	provider := &warmProvider{}
	want := "/Users/pranjal/Developer/universal_tmux"
	if got := renderWorkingDirectory(provider, "universal_tmux", want); got != want {
		t.Fatalf("render cwd = %q, want %q", got, want)
	}
}
