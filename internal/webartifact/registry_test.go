package webartifact

import (
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type fakeRunner struct {
	has      map[string]bool
	spawned  int
	killed   int
	name     string
	dir      string
	command  string
	idleSecs int
}

func (f *fakeRunner) Has(name string) bool { return f.has[name] }
func (f *fakeRunner) Spawn(name, dir, command string, idleSec int) error {
	f.spawned++
	f.name, f.dir, f.command, f.idleSecs = name, dir, command, idleSec
	f.has[name] = true
	return nil
}
func (f *fakeRunner) Kill(name string) error {
	f.killed++
	delete(f.has, name)
	return nil
}

func validRequest(t *testing.T) AddRequest {
	t.Helper()
	return AddRequest{
		Name: "Gym dashboard", SessionName: "gym_anything",
		StableSessionID: "$12", SessionLineageID: "tmux:10:20:$12",
		WorkingDirectory: t.TempDir(),
		Command:          "source .venv/bin/activate && exec python dashboard.py --port 5800",
		URL:              "http://localhost:5800/dashboard",
	}
}

func automaticPortRequest(t *testing.T) AddRequest {
	t.Helper()
	request := validRequest(t)
	request.Command = "source .venv/bin/activate && exec python dashboard.py --port {port}"
	request.URL = "http://localhost:{port}/dashboard"
	request.PortMode = PortModeAuto
	return request
}

func TestAddPersistsWithoutRunning(t *testing.T) {
	runner := &fakeRunner{has: map[string]bool{}}
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "babel-p9-28", "babel-p9-28", runner)
	request := validRequest(t)
	recipe, err := registry.Add(request)
	if err != nil {
		t.Fatal(err)
	}
	if runner.spawned != 0 {
		t.Fatalf("registration ran the recipe %d time(s)", runner.spawned)
	}
	if recipe.SessionName != request.SessionName || recipe.StableSessionID != request.StableSessionID ||
		recipe.SessionLineageID != request.SessionLineageID {
		t.Fatalf("session provenance was not preserved: %+v", recipe)
	}
	loaded, err := registry.List()
	if err != nil || len(loaded) != 1 || loaded[0].ID != recipe.ID {
		t.Fatalf("List() = %+v, %v", loaded, err)
	}
}

func TestAddRejectsDuplicateAcrossBabelSharedStore(t *testing.T) {
	root := filepath.Join(t.TempDir(), "records")
	first := NewRegistry(root, "babel-p9-28", "babel-p9-28", &fakeRunner{has: map[string]bool{}})
	second := NewRegistry(root, "ut-babel-u5-16", "babel-u5-16", &fakeRunner{has: map[string]bool{}})
	request := validRequest(t)
	if _, err := first.Add(request); err != nil {
		t.Fatal(err)
	}
	if _, err := second.Add(request); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("duplicate Add error = %v", err)
	}
}

func TestConcurrentBabelAddPublishesExactlyOneRecord(t *testing.T) {
	root := filepath.Join(t.TempDir(), "records")
	first := NewRegistry(root, "babel-p9-28", "babel-p9-28", &fakeRunner{has: map[string]bool{}})
	second := NewRegistry(root, "babel-u5-16", "babel-u5-16", &fakeRunner{has: map[string]bool{}})
	request := validRequest(t)
	start := make(chan struct{})
	errors := make(chan error, 2)
	var group sync.WaitGroup
	for _, registry := range []*Registry{first, second} {
		group.Add(1)
		go func(registry *Registry) {
			defer group.Done()
			<-start
			_, err := registry.Add(request)
			errors <- err
		}(registry)
	}
	close(start)
	group.Wait()
	close(errors)
	successes := 0
	for err := range errors {
		if err == nil {
			successes++
		} else if !strings.Contains(err.Error(), "already exists") {
			t.Fatalf("concurrent Add error = %v", err)
		}
	}
	if successes != 1 {
		t.Fatalf("successful concurrent adds = %d, want 1", successes)
	}
	records, err := first.List()
	if err != nil || len(records) != 1 {
		t.Fatalf("List() = %+v, %v", records, err)
	}
}

func TestSharedBabelStoreCannotRunOrMutateAnotherNodesRecipe(t *testing.T) {
	root := filepath.Join(t.TempDir(), "records")
	first := NewRegistry(root, "babel-p9-28", "babel-p9-28", &fakeRunner{has: map[string]bool{}})
	second := NewRegistry(root, "babel-u5-16", "babel-u5-16", &fakeRunner{has: map[string]bool{}})
	request := validRequest(t)
	recipe, err := first.Add(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := second.Start(recipe.ID); err == nil || !strings.Contains(err.Error(), "belongs to") {
		t.Fatalf("cross-node Start error = %v", err)
	}
	if err := second.Delete(recipe.ID); err == nil || !strings.Contains(err.Error(), "belongs to") {
		t.Fatalf("cross-node Delete error = %v", err)
	}
}

func TestAddRequiresAbsoluteDirectoryAndLoopbackURL(t *testing.T) {
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "mac", "mac", nil)
	request := validRequest(t)
	request.WorkingDirectory = "relative/project"
	if _, err := registry.Add(request); err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Fatalf("relative cwd error = %v", err)
	}
	request = validRequest(t)
	request.URL = "http://babel-p9-28:5800/"
	if _, err := registry.Add(request); err == nil || !strings.Contains(err.Error(), "localhost") {
		t.Fatalf("remote URL error = %v", err)
	}
}

func TestAutomaticPortRequiresExplicitCommandAndURLPlaceholders(t *testing.T) {
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "mac", "mac", nil)
	request := automaticPortRequest(t)
	request.Command = "python dashboard.py"
	if _, err := registry.Add(request); err == nil || !strings.Contains(err.Error(), PortPlaceholder) {
		t.Fatalf("missing command placeholder error = %v", err)
	}
	request = automaticPortRequest(t)
	request.URL = "http://localhost:5800/dashboard"
	if _, err := registry.Add(request); err == nil || !strings.Contains(err.Error(), PortPlaceholder) {
		t.Fatalf("missing URL placeholder error = %v", err)
	}
}

func TestAutomaticPortIsAllocatedPersistedAndSubstitutedAtLaunch(t *testing.T) {
	runner := &fakeRunner{has: map[string]bool{}}
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "mac", "mac", runner)
	recipe, err := registry.Add(automaticPortRequest(t))
	if err != nil {
		t.Fatal(err)
	}
	if recipe.Port != 0 || runner.spawned != 0 {
		t.Fatalf("registration allocated or launched unexpectedly: recipe=%+v runner=%+v", recipe, runner)
	}
	status, err := registry.Start(recipe.ID)
	if err != nil {
		t.Fatal(err)
	}
	endpoint, err := ParseEndpoint(status.URL)
	if err != nil || endpoint.Port < 1 {
		t.Fatalf("Start URL = %q, endpoint=%+v, err=%v", status.URL, endpoint, err)
	}
	portText := fmt.Sprint(endpoint.Port)
	if strings.Contains(runner.command, PortPlaceholder) || !strings.Contains(runner.command, "--port "+portText) {
		t.Fatalf("spawned command = %q, want allocated port %s", runner.command, portText)
	}
	loaded, err := registry.List()
	if err != nil || len(loaded) != 1 || loaded[0].Port != endpoint.Port {
		t.Fatalf("persisted recipes = %+v, err=%v", loaded, err)
	}

	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", portText))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	status, err = registry.Status(recipe.ID)
	if err != nil || status.State != "ready" || status.URL != "http://localhost:"+portText+"/dashboard" {
		t.Fatalf("Status() = %+v, err=%v", status, err)
	}
}

func TestRunningAutomaticArtifactsReceiveDifferentPorts(t *testing.T) {
	runner := &fakeRunner{has: map[string]bool{}}
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "mac", "mac", runner)
	firstRequest := automaticPortRequest(t)
	firstRequest.Name = "First dashboard"
	first, err := registry.Add(firstRequest)
	if err != nil {
		t.Fatal(err)
	}
	secondRequest := automaticPortRequest(t)
	secondRequest.Name = "Second dashboard"
	second, err := registry.Add(secondRequest)
	if err != nil {
		t.Fatal(err)
	}
	firstStatus, err := registry.Start(first.ID)
	if err != nil {
		t.Fatal(err)
	}
	secondStatus, err := registry.Start(second.ID)
	if err != nil {
		t.Fatal(err)
	}
	firstEndpoint, _ := ParseEndpoint(firstStatus.URL)
	secondEndpoint, _ := ParseEndpoint(secondStatus.URL)
	if firstEndpoint.Port == secondEndpoint.Port {
		t.Fatalf("both running artifacts were assigned port %d", firstEndpoint.Port)
	}
}

func TestStartUsesDedicatedHiddenRunnerAndExactRecipe(t *testing.T) {
	runner := &fakeRunner{has: map[string]bool{}}
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "babel-p9-28", "babel-p9-28", runner)
	request := validRequest(t)
	recipe, err := registry.Add(request)
	if err != nil {
		t.Fatal(err)
	}
	status, err := registry.Start(recipe.ID)
	if err != nil {
		t.Fatal(err)
	}
	if status.State != "starting" || runner.spawned != 1 {
		t.Fatalf("Start() = %+v; runner=%+v", status, runner)
	}
	if runner.name != RunnerName(recipe.ID) || !strings.HasPrefix(runner.name, "_web-") {
		t.Fatalf("runner name = %q", runner.name)
	}
	if runner.dir != request.WorkingDirectory || runner.command != request.Command || runner.idleSecs != 0 {
		t.Fatalf("runner changed recipe: %+v", runner)
	}
}

func TestStartDoesNotSpawnWhenEndpointAlreadyListening(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	runner := &fakeRunner{has: map[string]bool{}}
	registry := NewRegistry(filepath.Join(t.TempDir(), "records"), "mac", "mac", runner)
	request := validRequest(t)
	request.URL = "http://localhost:" + strings.TrimPrefix(listener.Addr().String(), "127.0.0.1:") + "/"
	recipe, err := registry.Add(request)
	if err != nil {
		t.Fatal(err)
	}
	status, err := registry.Start(recipe.ID)
	if err != nil {
		t.Fatal(err)
	}
	if status.State != "ready" || runner.spawned != 0 {
		t.Fatalf("Start() = %+v; runner spawned=%d", status, runner.spawned)
	}
}
