// Package webartifact stores and launches explicit, durable recipes for web
// dashboards. Registration never executes a recipe; starting is a separate,
// deliberate operation performed by a client such as Argus.
package webartifact

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const SchemaVersion = 1

const (
	PortModeAuto    = "auto"
	PortPlaceholder = "{port}"
)

// Recipe is the complete, location-independent description needed to bring a
// dashboard back. Session fields are provenance/search metadata only; recipes
// always run in their own hidden service session and never type into the panel
// that registered them.
type Recipe struct {
	SchemaVersion    int       `json:"schemaVersion"`
	ID               string    `json:"id"`
	Name             string    `json:"name"`
	MachineName      string    `json:"machineName"`
	MachineHost      string    `json:"machineHost"`
	SessionName      string    `json:"sessionName"`
	StableSessionID  string    `json:"stableSessionID,omitempty"`
	SessionLineageID string    `json:"sessionLineageID,omitempty"`
	WorkingDirectory string    `json:"workingDirectory"`
	Command          string    `json:"command"`
	URL              string    `json:"url"`
	PortMode         string    `json:"portMode,omitempty"`
	Port             int       `json:"port,omitempty"`
	CreatedAt        time.Time `json:"createdAt"`
	UpdatedAt        time.Time `json:"updatedAt"`
}

type AddRequest struct {
	Name             string `json:"name"`
	SessionName      string `json:"sessionName"`
	StableSessionID  string `json:"stableSessionID,omitempty"`
	SessionLineageID string `json:"sessionLineageID,omitempty"`
	WorkingDirectory string `json:"workingDirectory"`
	Command          string `json:"command"`
	URL              string `json:"url"`
	PortMode         string `json:"portMode,omitempty"`
}

type Runner interface {
	Has(name string) bool
	Spawn(name, dir, command string, idleSec int) error
	Kill(name string) error
}

type runtimeState struct {
	startedAt time.Time
	errorText string
}

type Registry struct {
	root        string
	machineName string
	machineHost string
	runner      Runner
	mu          sync.Mutex
	runtime     map[string]runtimeState
	now         func() time.Time
}

func DefaultRoot() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	return filepath.Join(home, ".universal-tmux", "web-artifacts", "records")
}

func NewRegistry(root, machineName, machineHost string, runner Runner) *Registry {
	if root == "" {
		root = DefaultRoot()
	}
	return &Registry{
		root: root, machineName: machineName, machineHost: machineHost,
		runner: runner, runtime: map[string]runtimeState{}, now: time.Now,
	}
}

func (r *Registry) List() ([]Recipe, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.listLocked()
}

func (r *Registry) listLocked() ([]Recipe, error) {
	if err := os.MkdirAll(r.root, 0o700); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(r.root)
	if err != nil {
		return nil, err
	}
	result := make([]Recipe, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".json") {
			continue
		}
		body, readErr := os.ReadFile(filepath.Join(r.root, entry.Name()))
		if readErr != nil {
			continue
		}
		var recipe Recipe
		if json.Unmarshal(body, &recipe) != nil || recipe.SchemaVersion != SchemaVersion || recipe.ID == "" {
			continue
		}
		result = append(result, recipe)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].UpdatedAt.After(result[j].UpdatedAt) })
	return result, nil
}

func (r *Registry) Add(request AddRequest) (Recipe, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	request.Name = strings.TrimSpace(request.Name)
	request.SessionName = strings.TrimSpace(request.SessionName)
	request.WorkingDirectory = strings.TrimSpace(request.WorkingDirectory)
	request.Command = strings.TrimSpace(request.Command)
	request.URL = strings.TrimSpace(request.URL)
	request.PortMode = strings.ToLower(strings.TrimSpace(request.PortMode))
	if err := ValidateRequest(request); err != nil {
		return Recipe{}, err
	}
	if err := requireDirectory(request.WorkingDirectory); err != nil {
		return Recipe{}, err
	}
	existing, err := r.listLocked()
	if err != nil {
		return Recipe{}, err
	}
	for _, recipe := range existing {
		if duplicateKey(recipe.MachineName, recipe.MachineHost, recipe.SessionName, recipe.Name) ==
			duplicateKey(r.machineName, r.machineHost, request.SessionName, request.Name) {
			return Recipe{}, fmt.Errorf("web artifact %q already exists for session %q; use `ut web-artifacts update`", request.Name, request.SessionName)
		}
	}
	id := recipeID(r.machineName, r.machineHost, request.SessionName, request.Name)
	now := r.now().UTC()
	recipe := Recipe{
		SchemaVersion: SchemaVersion, ID: id, Name: request.Name,
		MachineName: r.machineName, MachineHost: r.machineHost,
		SessionName: request.SessionName, StableSessionID: request.StableSessionID,
		SessionLineageID: request.SessionLineageID,
		WorkingDirectory: request.WorkingDirectory, Command: request.Command, URL: request.URL,
		PortMode:  request.PortMode,
		CreatedAt: now, UpdatedAt: now,
	}
	if err := r.writeNewLocked(recipe); err != nil {
		if os.IsExist(err) {
			return Recipe{}, fmt.Errorf("web artifact %q already exists for session %q; use `ut web-artifacts update`", request.Name, request.SessionName)
		}
		return Recipe{}, err
	}
	return recipe, nil
}

func (r *Registry) Update(id string, request AddRequest) (Recipe, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	current, err := r.loadOwnedLocked(id)
	if err != nil {
		return Recipe{}, err
	}
	request.Name = strings.TrimSpace(request.Name)
	request.SessionName = strings.TrimSpace(request.SessionName)
	request.WorkingDirectory = strings.TrimSpace(request.WorkingDirectory)
	request.Command = strings.TrimSpace(request.Command)
	request.URL = strings.TrimSpace(request.URL)
	request.PortMode = strings.ToLower(strings.TrimSpace(request.PortMode))
	if err := ValidateRequest(request); err != nil {
		return Recipe{}, err
	}
	if err := requireDirectory(request.WorkingDirectory); err != nil {
		return Recipe{}, err
	}
	all, err := r.listLocked()
	if err != nil {
		return Recipe{}, err
	}
	for _, recipe := range all {
		if recipe.ID != current.ID && duplicateKey(recipe.MachineName, recipe.MachineHost, recipe.SessionName, recipe.Name) ==
			duplicateKey(current.MachineName, current.MachineHost, request.SessionName, request.Name) {
			return Recipe{}, fmt.Errorf("web artifact %q already exists for session %q", request.Name, request.SessionName)
		}
	}
	current.Name = request.Name
	current.SessionName = request.SessionName
	current.StableSessionID = request.StableSessionID
	current.SessionLineageID = request.SessionLineageID
	current.WorkingDirectory = request.WorkingDirectory
	current.Command = request.Command
	current.URL = request.URL
	current.PortMode = request.PortMode
	current.Port = 0
	current.UpdatedAt = r.now().UTC()
	if err := r.writeLocked(current); err != nil {
		return Recipe{}, err
	}
	return current, nil
}

func (r *Registry) Delete(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, err := r.loadOwnedLocked(id); err != nil {
		return err
	}
	if err := os.Remove(r.path(id)); err != nil {
		return err
	}
	delete(r.runtime, id)
	return nil
}

func (r *Registry) Start(id string) (Status, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	recipe, err := r.loadOwnedLocked(id)
	if err != nil {
		return Status{}, err
	}
	runnerName := RunnerName(id)
	if recipe.PortMode == PortModeAuto {
		if recipe.Port > 0 && r.runner != nil && r.runner.Has(runnerName) {
			_, resolvedURL, resolveErr := resolveRecipe(recipe)
			if resolveErr == nil && endpointReady(resolvedURL) {
				delete(r.runtime, id)
				return Status{ID: id, State: "ready", URL: resolvedURL}, nil
			}
		}
	} else if endpointReady(recipe.URL) {
		delete(r.runtime, id)
		return Status{ID: id, State: "ready", URL: recipe.URL}, nil
	}
	if r.runner == nil {
		return Status{}, errors.New("web artifact runner is unavailable")
	}
	if r.runner.Has(runnerName) {
		if err := r.runner.Kill(runnerName); err != nil {
			return Status{}, fmt.Errorf("remove previous runner: %w", err)
		}
	}
	command, endpointURL := recipe.Command, recipe.URL
	if recipe.PortMode == PortModeAuto {
		port, allocateErr := r.allocatePortLocked(id, recipe.Port)
		if allocateErr != nil {
			return Status{}, allocateErr
		}
		recipe.Port = port
		if err := r.writeLocked(recipe); err != nil {
			return Status{}, fmt.Errorf("save allocated port: %w", err)
		}
		command, endpointURL, err = resolveRecipe(recipe)
		if err != nil {
			return Status{}, err
		}
	}
	if err := r.runner.Spawn(runnerName, recipe.WorkingDirectory, command, 0); err != nil {
		r.runtime[id] = runtimeState{startedAt: r.now(), errorText: err.Error()}
		return Status{}, err
	}
	r.runtime[id] = runtimeState{startedAt: r.now()}
	return Status{ID: id, State: "starting", URL: endpointURL}, nil
}

type Status struct {
	ID      string `json:"id"`
	State   string `json:"state"`
	URL     string `json:"url"`
	Message string `json:"message,omitempty"`
}

func (r *Registry) Status(id string) (Status, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	recipe, err := r.loadOwnedLocked(id)
	if err != nil {
		return Status{}, err
	}
	endpointURL := recipe.URL
	if recipe.PortMode == PortModeAuto && recipe.Port > 0 {
		_, endpointURL, err = resolveRecipe(recipe)
		if err != nil {
			return Status{}, err
		}
	}
	runnerAlive := r.runner != nil && r.runner.Has(RunnerName(id))
	if endpointReady(endpointURL) && (recipe.PortMode != PortModeAuto || runnerAlive) {
		delete(r.runtime, id)
		return Status{ID: id, State: "ready", URL: endpointURL}, nil
	}
	state, launched := r.runtime[id]
	if state.errorText != "" {
		return Status{ID: id, State: "failed", URL: endpointURL, Message: state.errorText}, nil
	}
	if launched {
		if !runnerAlive {
			return Status{ID: id, State: "failed", URL: endpointURL, Message: "The launch command exited before the saved URL became reachable."}, nil
		}
		if r.now().Sub(state.startedAt) > 60*time.Second {
			return Status{ID: id, State: "failed", URL: endpointURL, Message: "The command started, but the saved URL did not become reachable within 60 seconds."}, nil
		}
		return Status{ID: id, State: "starting", URL: endpointURL}, nil
	}
	return Status{ID: id, State: "stopped", URL: endpointURL}, nil
}

func (r *Registry) Stop(id string) (Status, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	recipe, err := r.loadOwnedLocked(id)
	if err != nil {
		return Status{}, err
	}
	if r.runner != nil && r.runner.Has(RunnerName(id)) {
		if err := r.runner.Kill(RunnerName(id)); err != nil {
			return Status{}, err
		}
	}
	delete(r.runtime, id)
	endpointURL := recipe.URL
	if recipe.PortMode == PortModeAuto && recipe.Port > 0 {
		_, endpointURL, _ = resolveRecipe(recipe)
	}
	return Status{ID: id, State: "stopped", URL: endpointURL}, nil
}

func RunnerName(id string) string {
	clean := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, id)
	if len(clean) > 12 {
		clean = clean[:12]
	}
	return "_web-" + clean
}

func ValidateRequest(request AddRequest) error {
	if request.Name == "" {
		return errors.New("name is required")
	}
	if request.SessionName == "" {
		return errors.New("session provenance is required; run inside a ut session or pass --session")
	}
	if request.WorkingDirectory == "" || !filepath.IsAbs(request.WorkingDirectory) {
		return fmt.Errorf("working directory must be an absolute path: %q", request.WorkingDirectory)
	}
	if request.Command == "" {
		return errors.New("command is required")
	}
	if request.PortMode != "" && request.PortMode != PortModeAuto {
		return fmt.Errorf("unsupported port mode %q", request.PortMode)
	}
	if request.PortMode == PortModeAuto {
		if !strings.Contains(request.Command, PortPlaceholder) {
			return fmt.Errorf("automatic port commands must contain %s", PortPlaceholder)
		}
		if !strings.Contains(request.URL, PortPlaceholder) {
			return fmt.Errorf("automatic port URLs must contain %s", PortPlaceholder)
		}
		_, err := ParseEndpoint(strings.ReplaceAll(request.URL, PortPlaceholder, "49152"))
		return err
	}
	_, err := ParseEndpoint(request.URL)
	return err
}

func resolveRecipe(recipe Recipe) (command, endpointURL string, err error) {
	if recipe.PortMode != PortModeAuto {
		return recipe.Command, recipe.URL, nil
	}
	if recipe.Port < 1 || recipe.Port > 65535 {
		return "", "", errors.New("automatic port has not been allocated")
	}
	port := fmt.Sprint(recipe.Port)
	return strings.ReplaceAll(recipe.Command, PortPlaceholder, port),
		strings.ReplaceAll(recipe.URL, PortPlaceholder, port), nil
}

func (r *Registry) allocatePortLocked(id string, preferred int) (int, error) {
	reserved := map[int]bool{}
	recipes, err := r.listLocked()
	if err != nil {
		return 0, err
	}
	for _, other := range recipes {
		if other.ID == id || other.PortMode != PortModeAuto || other.Port == 0 {
			continue
		}
		if r.runner != nil && r.runner.Has(RunnerName(other.ID)) {
			reserved[other.Port] = true
		}
	}
	if preferred > 0 && !reserved[preferred] && portAvailable(preferred) {
		return preferred, nil
	}
	for attempt := 0; attempt < 64; attempt++ {
		listener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			return 0, fmt.Errorf("allocate automatic port: %w", listenErr)
		}
		port := listener.Addr().(*net.TCPAddr).Port
		_ = listener.Close()
		if !reserved[port] {
			return port, nil
		}
	}
	return 0, errors.New("could not allocate an unused loopback port")
}

func portAvailable(port int) bool {
	listener, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", fmt.Sprint(port)))
	if err != nil {
		return false
	}
	_ = listener.Close()
	return true
}

func requireDirectory(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("working directory is not accessible: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("working directory is not a directory: %q", path)
	}
	return nil
}

type Endpoint struct {
	Scheme string
	Port   int
	Path   string
}

func ParseEndpoint(raw string) (Endpoint, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return Endpoint{}, fmt.Errorf("url must be a complete loopback URL, for example http://localhost:5800/dashboard")
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return Endpoint{}, fmt.Errorf("url scheme must be http or https")
	}
	host := strings.ToLower(u.Hostname())
	if host != "localhost" && host != "127.0.0.1" && host != "::1" {
		return Endpoint{}, fmt.Errorf("url must use localhost, 127.0.0.1, or ::1; got %q", host)
	}
	port := 80
	if u.Scheme == "https" {
		port = 443
	}
	if u.Port() != "" {
		if _, scanErr := fmt.Sscanf(u.Port(), "%d", &port); scanErr != nil || port < 1 || port > 65535 {
			return Endpoint{}, fmt.Errorf("url has an invalid port")
		}
	}
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	if u.RawQuery != "" {
		path += "?" + u.RawQuery
	}
	return Endpoint{Scheme: u.Scheme, Port: port, Path: path}, nil
}

func endpointReady(raw string) bool {
	endpoint, err := ParseEndpoint(raw)
	if err != nil {
		return false
	}
	for _, host := range []string{"127.0.0.1", "::1"} {
		conn, dialErr := net.DialTimeout("tcp", net.JoinHostPort(host, fmt.Sprint(endpoint.Port)), 220*time.Millisecond)
		if dialErr == nil {
			_ = conn.Close()
			return true
		}
	}
	return false
}

func duplicateKey(machineName, machineHost, sessionName, name string) string {
	return machineScope(machineName, machineHost) + "\x00" + strings.ToLower(strings.TrimSpace(sessionName)) + "\x00" + strings.ToLower(strings.TrimSpace(name))
}

func machineScope(name, host string) string {
	for _, raw := range []string{name, host} {
		value := strings.ToLower(strings.TrimSpace(raw))
		value = strings.TrimPrefix(value, "ut-")
		value = strings.SplitN(value, ".", 2)[0]
		if strings.HasPrefix(value, "babel-") {
			return "babel"
		}
	}
	if host != "" {
		return strings.ToLower(strings.TrimSpace(host))
	}
	return strings.ToLower(strings.TrimSpace(name))
}

func sameMachine(recipe Recipe, name, host string) bool {
	normalize := func(value string) string {
		value = strings.ToLower(strings.TrimSpace(value))
		value = strings.TrimPrefix(value, "ut-")
		return strings.SplitN(value, ".", 2)[0]
	}
	return normalize(recipe.MachineName) == normalize(name) || normalize(recipe.MachineHost) == normalize(host)
}

func recipeID(machineName, machineHost, sessionName, name string) string {
	sum := sha256.Sum256([]byte(duplicateKey(machineName, machineHost, sessionName, name)))
	return fmt.Sprintf("%x", sum[:16])
}

func (r *Registry) path(id string) string {
	return filepath.Join(r.root, id+".json")
}

func (r *Registry) loadLocked(id string) (Recipe, error) {
	if id == "" || strings.ContainsAny(id, `/\\`) {
		return Recipe{}, errors.New("invalid web artifact id")
	}
	body, err := os.ReadFile(r.path(id))
	if err != nil {
		if os.IsNotExist(err) {
			return Recipe{}, fmt.Errorf("no such web artifact %q", id)
		}
		return Recipe{}, err
	}
	var recipe Recipe
	if err := json.Unmarshal(body, &recipe); err != nil {
		return Recipe{}, err
	}
	return recipe, nil
}

func (r *Registry) loadOwnedLocked(id string) (Recipe, error) {
	recipe, err := r.loadLocked(id)
	if err != nil {
		return Recipe{}, err
	}
	if !sameMachine(recipe, r.machineName, r.machineHost) {
		return Recipe{}, fmt.Errorf("%q belongs to %s, not this machine", recipe.Name, recipe.MachineName)
	}
	return recipe, nil
}

func (r *Registry) writeLocked(recipe Recipe) error {
	if err := os.MkdirAll(r.root, 0o700); err != nil {
		return err
	}
	body, err := json.MarshalIndent(recipe, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(r.root, ".web-artifact-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(body, '\n')); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, r.path(recipe.ID))
}

// writeNewLocked publishes a complete record with one atomic hard-link. The
// deterministic ID plus link-if-absent makes duplicate prevention work across
// independent Babel brokers sharing the same filesystem, not just goroutines
// in this Registry process.
func (r *Registry) writeNewLocked(recipe Recipe) error {
	if err := os.MkdirAll(r.root, 0o700); err != nil {
		return err
	}
	body, err := json.MarshalIndent(recipe, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(r.root, ".web-artifact-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(body, '\n')); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Link(tmpPath, r.path(recipe.ID))
}

// RegisterRoutes exposes the local registry. The surrounding broker already
// supplies tailnet routing, so the CLI writes to its own host while Argus can
// aggregate the same endpoint across discovered machines.
func (r *Registry) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/web-artifacts", r.handleCollection)
	mux.HandleFunc("/web-artifacts/start", r.handleStart)
	mux.HandleFunc("/web-artifacts/status", r.handleStatus)
	mux.HandleFunc("/web-artifacts/stop", r.handleStop)
}

func (r *Registry) handleCollection(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	switch req.Method {
	case http.MethodGet:
		recipes, err := r.List()
		if err != nil {
			writeError(w, http.StatusInternalServerError, err)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"artifacts": recipes})
	case http.MethodPost, http.MethodPut:
		defer req.Body.Close()
		var request AddRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 1<<20)).Decode(&request); err != nil {
			writeError(w, http.StatusBadRequest, fmt.Errorf("invalid recipe: %w", err))
			return
		}
		var recipe Recipe
		var err error
		if req.Method == http.MethodPut {
			recipe, err = r.Update(req.URL.Query().Get("id"), request)
		} else {
			recipe, err = r.Add(request)
		}
		if err != nil {
			writeError(w, http.StatusBadRequest, err)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(recipe)
	case http.MethodDelete:
		if err := r.Delete(req.URL.Query().Get("id")); err != nil {
			writeError(w, http.StatusNotFound, err)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	default:
		w.Header().Set("Allow", "GET, POST, PUT, DELETE")
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
	}
}

func (r *Registry) handleStart(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, errors.New("POST only"))
		return
	}
	status, err := r.Start(req.URL.Query().Get("id"))
	writeStatus(w, status, err)
}

func (r *Registry) handleStatus(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, errors.New("GET only"))
		return
	}
	status, err := r.Status(req.URL.Query().Get("id"))
	writeStatus(w, status, err)
}

func (r *Registry) handleStop(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, errors.New("POST only"))
		return
	}
	status, err := r.Stop(req.URL.Query().Get("id"))
	writeStatus(w, status, err)
}

func writeStatus(w http.ResponseWriter, status Status, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	_ = json.NewEncoder(w).Encode(status)
}

func writeError(w http.ResponseWriter, code int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
}
