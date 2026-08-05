//go:build !windows

package recovery

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var errNoTmuxServer = errors.New("tmux server is not running")

type paneInfo struct {
	Name       string
	PanePID    int
	TTY        string
	Directory  string
	Windows    int
	Panes      int
	AgentOwned bool
	Active     bool
}

type processInfo struct {
	PID, PPID, PGID, TPGID int
	TTY                    string
	Command                string
}

type processState struct {
	Executable  string
	Argv        []string
	Environment map[string]string
}

func tmuxArgs(socket string, args ...string) []string {
	if socket == "" {
		return args
	}
	return append([]string{"-L", socket}, args...)
}

func toolPath(name string) string {
	if path, err := exec.LookPath(name); err == nil {
		return path
	}
	for _, directory := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"} {
		candidate := filepath.Join(directory, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return name
}

func tmuxCommand(socket string, args ...string) *exec.Cmd {
	cmd := exec.Command(toolPath("tmux"), tmuxArgs(socket, args...)...)
	// Finder-launched macOS applications commonly have neither LANG nor
	// LC_CTYPE. tmux sanitizes control characters in format output in that
	// environment (a tab becomes "_"), which makes structured list output
	// ambiguous. C.UTF-8 is supported by modern macOS and Linux and changes only
	// the tmux client's formatting/decoding boundary.
	cmd.Env = environmentWithOverrides(os.Environ(), map[string]string{
		"LC_ALL":   "",
		"LC_CTYPE": "C.UTF-8",
	})
	return cmd
}

func environmentWithOverrides(base []string, overrides map[string]string) []string {
	out := make([]string, 0, len(base)+len(overrides))
	for _, item := range base {
		key, _, ok := strings.Cut(item, "=")
		if ok {
			if _, replace := overrides[key]; replace {
				continue
			}
		}
		out = append(out, item)
	}
	for key, value := range overrides {
		if value != "" {
			out = append(out, key+"="+value)
		}
	}
	return out
}

func tmuxServerIdentity(socket string) (boot string, pid int, start int64, id string, err error) {
	out, err := tmuxCommand(socket, "display-message", "-p", "#{pid}\t#{start_time}").Output()
	if err != nil {
		return "", 0, 0, "", errNoTmuxServer
	}
	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		return "", 0, 0, "", fmt.Errorf("invalid tmux server identity %q", strings.TrimSpace(string(out)))
	}
	pid, err = strconv.Atoi(fields[0])
	if err != nil || pid <= 0 {
		return "", 0, 0, "", fmt.Errorf("invalid tmux server PID %q", fields[0])
	}
	start, err = strconv.ParseInt(fields[1], 10, 64)
	if err != nil || start <= 0 {
		return "", 0, 0, "", fmt.Errorf("invalid tmux server start time %q", fields[1])
	}
	boot, err = platformBootID()
	if err != nil {
		return "", 0, 0, "", err
	}
	id = boot + ":" + strconv.FormatInt(start, 10) + ":" + strconv.Itoa(pid)
	return boot, pid, start, id, nil
}

func listPanes(socket string) ([]paneInfo, error) {
	format := strings.Join([]string{
		"#{session_name}", "#{pane_pid}", "#{pane_tty}", "#{session_windows}",
		"#{@ut_agent}", "#{window_active}", "#{pane_active}", "#{pane_current_path}",
	}, "\t")
	out, err := tmuxCommand(socket, "list-panes", "-a", "-F", format).Output()
	if err != nil {
		return nil, errNoTmuxServer
	}
	type aggregate struct {
		chosen paneInfo
		panes  int
	}
	byName := map[string]*aggregate{}
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line == "" {
			continue
		}
		fields := strings.SplitN(line, "\t", 8)
		if len(fields) != 8 || strings.HasPrefix(fields[0], "_ut-") {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[1])
		windows, windowsErr := strconv.Atoi(fields[3])
		if pidErr != nil || windowsErr != nil {
			continue
		}
		pane := paneInfo{
			Name: fields[0], PanePID: pid, TTY: fields[2], Windows: windows,
			AgentOwned: fields[4] == "1", Active: fields[5] == "1" && fields[6] == "1",
			Directory: fields[7],
		}
		agg := byName[pane.Name]
		if agg == nil {
			agg = &aggregate{chosen: pane}
			byName[pane.Name] = agg
		}
		agg.panes++
		if pane.Active {
			agg.chosen = pane
		}
	}
	panes := make([]paneInfo, 0, len(byName))
	for _, agg := range byName {
		if agg.chosen.AgentOwned {
			continue
		}
		agg.chosen.Panes = agg.panes
		panes = append(panes, agg.chosen)
	}
	sort.Slice(panes, func(i, j int) bool { return panes[i].Name < panes[j].Name })
	return panes, nil
}

func readProcessTable() (map[int]processInfo, error) {
	out, err := exec.Command(toolPath("ps"), "-axo", "pid=,ppid=,pgid=,tpgid=,tty=,comm=").Output()
	if err != nil {
		return nil, err
	}
	processes := map[int]processInfo{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		pid, e1 := strconv.Atoi(fields[0])
		ppid, e2 := strconv.Atoi(fields[1])
		pgid, e3 := strconv.Atoi(fields[2])
		tpgid, e4 := strconv.Atoi(fields[3])
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
			continue
		}
		processes[pid] = processInfo{PID: pid, PPID: ppid, PGID: pgid, TPGID: tpgid, TTY: fields[4], Command: strings.Join(fields[5:], " ")}
	}
	return processes, nil
}

func processAgent(process processInfo) string {
	name := strings.ToLower(filepath.Base(process.Command))
	if name == "codex" || strings.HasPrefix(name, "codex-") {
		return AgentCodex
	}
	if name == "claude" || name == "claude.exe" || strings.HasPrefix(name, "claude-") {
		return AgentClaude
	}
	return ""
}

func findAgent(root int, processes map[int]processInfo) (string, processInfo, bool) {
	children := map[int][]int{}
	for _, process := range processes {
		children[process.PPID] = append(children[process.PPID], process.PID)
	}
	type node struct{ pid, depth int }
	pending := []node{{root, 0}}
	seen := map[int]bool{}
	type candidate struct {
		depth   int
		agent   string
		process processInfo
	}
	var candidates []candidate
	for len(pending) > 0 {
		current := pending[0]
		pending = pending[1:]
		if seen[current.pid] {
			continue
		}
		seen[current.pid] = true
		if process, ok := processes[current.pid]; ok {
			if agent := processAgent(process); agent != "" && process.PGID == process.TPGID {
				candidates = append(candidates, candidate{current.depth, agent, process})
			}
		}
		for _, child := range children[current.pid] {
			pending = append(pending, node{child, current.depth + 1})
		}
	}
	if len(candidates) == 0 {
		return "", processInfo{}, false
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].depth != candidates[j].depth {
			return candidates[i].depth < candidates[j].depth
		}
		return candidates[i].process.PID < candidates[j].process.PID
	})
	return candidates[0].agent, candidates[0].process, true
}

func findClaudeTranscript(configDir, sessionID string) string {
	matches, _ := filepath.Glob(filepath.Join(configDir, "projects", "*", sessionID+".jsonl"))
	if len(matches) == 0 {
		return ""
	}
	sort.Strings(matches)
	return matches[0]
}

func inspectClaude(pid int, state processState) (string, string, string, error) {
	config := state.Environment["CLAUDE_CONFIG_DIR"]
	if config == "" {
		home, _ := os.UserHomeDir()
		config = filepath.Join(home, ".claude")
	}
	registry := filepath.Join(config, "sessions", strconv.Itoa(pid)+".json")
	body, err := os.ReadFile(registry)
	if err != nil {
		return "", "", registry, fmt.Errorf("read Claude active-session registry: %w", err)
	}
	var record struct {
		PID       int    `json:"pid"`
		SessionID string `json:"sessionId"`
		ProcStart string `json:"procStart"`
	}
	if err := json.Unmarshal(body, &record); err != nil {
		return "", "", registry, fmt.Errorf("decode Claude active-session registry: %w", err)
	}
	if record.PID != pid || !uuidPattern.MatchString(record.SessionID) {
		return "", "", registry, fmt.Errorf("Claude active-session registry has invalid process identity")
	}
	started, err := platformProcessStart(pid)
	if err != nil {
		return "", "", registry, fmt.Errorf("read Claude process start: %w", err)
	}
	value := strings.Join(strings.Fields(record.ProcStart), " ")
	const layout = "Mon Jan 2 15:04:05 2006"
	recordedUTC, utcErr := time.ParseInLocation(layout, value, time.UTC)
	recordedLocal, localErr := time.ParseInLocation(layout, value, time.Local)
	if (utcErr != nil || recordedUTC.Unix() != started.Unix()) && (localErr != nil || recordedLocal.Unix() != started.Unix()) {
		return "", "", registry, fmt.Errorf("Claude active-session registry is stale (process start mismatch)")
	}
	return record.SessionID, findClaudeTranscript(config, record.SessionID), registry, nil
}

func inspectCodex(pid int) (string, string, error) {
	files, err := platformOpenFiles(pid)
	if err != nil {
		return "", "", fmt.Errorf("list Codex open files: %w", err)
	}
	var rollouts []string
	for _, path := range files {
		name := filepath.Base(path)
		if strings.Contains(filepath.ToSlash(path), "/.codex/sessions/") && strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl") {
			rollouts = append(rollouts, path)
		}
	}
	sort.Strings(rollouts)
	rollouts = uniqueStrings(rollouts)
	if len(rollouts) != 1 {
		return "", "", fmt.Errorf("Codex process has %d open rollout files", len(rollouts))
	}
	f, err := os.Open(rollouts[0])
	if err != nil {
		return "", rollouts[0], err
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return "", rollouts[0], err
	}
	var record struct {
		Type    string `json:"type"`
		Payload struct {
			ID        string `json:"id"`
			SessionID string `json:"session_id"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &record) != nil || record.Type != "session_meta" {
		return "", rollouts[0], fmt.Errorf("Codex rollout lacks session_meta")
	}
	id := record.Payload.ID
	if id == "" {
		id = record.Payload.SessionID
	}
	if !uuidPattern.MatchString(id) {
		return "", rollouts[0], fmt.Errorf("Codex rollout has an invalid session ID")
	}
	return id, rollouts[0], nil
}

func uniqueStrings(values []string) []string {
	if len(values) < 2 {
		return values
	}
	out := values[:1]
	for _, value := range values[1:] {
		if value != out[len(out)-1] {
			out = append(out, value)
		}
	}
	return out
}

func captureEntry(pane paneInfo, processes map[int]processInfo) Entry {
	entry := Entry{Name: pane.Name, Directory: pane.Directory, Agent: AgentShell, Windows: pane.Windows, Panes: pane.Panes}
	if pane.Windows > 1 || pane.Panes > 1 {
		entry.CaptureNotice = fmt.Sprintf("only the active pane is resumable (%d windows, %d panes)", pane.Windows, pane.Panes)
	}
	agent, process, ok := findAgent(pane.PanePID, processes)
	if !ok {
		return entry
	}
	entry.Agent = agent
	entry.AgentPID = process.PID
	state, err := platformProcessState(process.PID)
	if err != nil {
		entry.CaptureError = err.Error()
		return entry
	}
	entry.Executable = state.Executable
	entry.Argv = state.Argv
	switch agent {
	case AgentClaude:
		entry.SessionID, entry.SessionPath, _, err = inspectClaude(process.PID, state)
	case AgentCodex:
		entry.SessionID, entry.SessionPath, err = inspectCodex(process.PID)
	}
	if err != nil {
		entry.CaptureError = err.Error()
	}
	return entry
}

// Capture records the latest valid state for the current tmux server lifetime.
func (s *Store) Capture() (Snapshot, error) {
	boot, serverPID, started, serverID, err := tmuxServerIdentity(s.Socket)
	if err != nil {
		return Snapshot{}, err
	}
	panes, err := listPanes(s.Socket)
	if err != nil {
		return Snapshot{}, err
	}
	processes, err := readProcessTable()
	if err != nil {
		return Snapshot{}, err
	}
	host, _ := os.Hostname()
	snapshot := Snapshot{
		SchemaVersion: SchemaVersion, ID: snapshotID(serverID), Host: host, Socket: s.Socket,
		BootID: boot, ServerID: serverID, ServerPID: serverPID, ServerStarted: started, CapturedAt: s.Now().UTC(),
		Entries: make([]Entry, 0, len(panes)),
	}
	for _, pane := range panes {
		snapshot.Entries = append(snapshot.Entries, captureEntry(pane, processes))
	}
	if err := s.saveCaptured(&snapshot); err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

// RunCaptureLoop snapshots immediately, after each interval, and once more on
// clean shutdown. Failures are intentionally non-fatal to the broker.
func (s *Store) RunCaptureLoop(ctx context.Context, interval time.Duration, report func(error)) {
	capture := func() {
		_, err := s.Capture()
		if err != nil && !errors.Is(err, errNoTmuxServer) && report != nil {
			report(err)
		}
	}
	capture()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			capture()
			return
		case <-ticker.C:
			capture()
		}
	}
}

func currentEntries(socket string) (map[string]Entry, string) {
	_, _, _, serverID, err := tmuxServerIdentity(socket)
	if err != nil {
		return map[string]Entry{}, ""
	}
	panes, err := listPanes(socket)
	if err != nil {
		return map[string]Entry{}, serverID
	}
	processes, _ := readProcessTable()
	entries := make(map[string]Entry, len(panes))
	for _, pane := range panes {
		entries[pane.Name] = captureEntry(pane, processes)
	}
	return entries, serverID
}

func currentEntry(socket, name string) (Entry, bool) {
	panes, err := listPanes(socket)
	if err != nil {
		return Entry{}, false
	}
	for _, pane := range panes {
		if pane.Name != name {
			continue
		}
		processes, err := readProcessTable()
		if err != nil {
			return Entry{}, false
		}
		return captureEntry(pane, processes), true
	}
	return Entry{}, false
}

func preflight(entry Entry, current map[string]Entry) PanelStatus {
	panel := PanelStatus{Entry: entry}
	if live, exists := current[entry.Name]; exists {
		if entriesMatch(entry, live) {
			panel.State = PanelAlreadyRunning
			panel.Detail = "This exact workspace is already running."
			return panel
		}
		panel.State = PanelConflict
		panel.Detail = "A different live session already uses this panel name."
		return panel
	}
	if entry.CaptureError != "" {
		panel.State = PanelUnsupported
		panel.Detail = entry.CaptureError
		return panel
	}
	if info, err := os.Stat(entry.Directory); err != nil || !info.IsDir() {
		panel.State = PanelMissingDirectory
		panel.Detail = "The original working directory is no longer available."
		return panel
	}
	if entry.Agent != AgentShell {
		if entry.SessionPath == "" {
			panel.State = PanelMissingSession
			panel.Detail = "The conversation transcript was not found when this snapshot was recorded."
			return panel
		}
		if _, err := os.Stat(entry.SessionPath); err != nil {
			panel.State = PanelMissingSession
			panel.Detail = "The saved conversation is no longer present on disk."
			return panel
		}
		argv, err := resumeArgv(entry)
		if err != nil {
			panel.State = PanelUnsupported
			panel.Detail = err.Error()
			return panel
		}
		panel.ResumeArgv = argv
		panel.RestoreCommand = shellJoin(argv)
	}
	panel.State = PanelReady
	panel.Selected = true
	if entry.Agent == AgentShell {
		panel.Detail = "Restore an interactive shell in its original folder."
	} else {
		panel.Detail = "Resume the exact saved conversation."
	}
	return panel
}

func (s *Store) Status(requestedSnapshot string) Status {
	items, err := s.loadAll()
	if err != nil {
		return Status{Error: err.Error()}
	}
	current, currentServerID := currentEntries(s.Socket)
	var selected *Snapshot
	if requestedSnapshot != "" {
		for index := range items {
			if items[index].ID == requestedSnapshot {
				selected = &items[index]
				break
			}
		}
	} else if currentServerID == "" {
		// Before tmux has restarted, the newest non-empty manifest is exactly
		// the workspace that disappeared.
		for index := range items {
			if len(items[index].Entries) > 0 {
				selected = &items[index]
				break
			}
		}
	} else {
		var currentSnapshot *Snapshot
		for index := range items {
			if items[index].ServerID == currentServerID {
				currentSnapshot = &items[index]
				break
			}
		}
		if currentSnapshot == nil {
			// Narrow startup race: tmux exists but this server's first automatic
			// capture has not landed yet.
			for index := range items {
				if len(items[index].Entries) > 0 && items[index].ServerID != currentServerID {
					selected = &items[index]
					break
				}
			}
		} else if currentSnapshot.RecoverySourceID != "" && !currentSnapshot.RecoveryComplete {
			for index := range items {
				if items[index].ID == currentSnapshot.RecoverySourceID {
					selected = &items[index]
					break
				}
			}
		}
	}
	status := Status{Snapshot: selected, CurrentServerID: currentServerID}
	if selected == nil {
		if requestedSnapshot != "" {
			status.Error = fmt.Sprintf("recovery snapshot %q not found", requestedSnapshot)
		}
		return status
	}
	for _, entry := range selected.Entries {
		panel := preflight(entry, current)
		if panel.State == PanelReady {
			status.ReadyCount++
		}
		status.Panels = append(status.Panels, panel)
	}
	status.Available = status.ReadyCount > 0
	return status
}

func createRestoredSession(socket string, panel PanelStatus) error {
	args := []string{"new-session", "-d", "-s", panel.Name, "-c", panel.Directory}
	if panel.Agent != AgentShell {
		// tmux accepts command + arguments as separate argv. The wrapper leaves an
		// interactive shell behind if the resumed TUI exits, matching normal panels.
		wrapper := "\"$@\"\nexec \"${SHELL:-/bin/sh}\" -l"
		args = append(args, "sh", "-c", wrapper, "restore-agent")
		args = append(args, panel.ResumeArgv...)
	}
	out, err := tmuxCommand(socket, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("create tmux session: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func verifyRestored(socket string, expected Entry, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var last string
	for time.Now().Before(deadline) {
		entry, ok := currentEntry(socket, expected.Name)
		if ok {
			if entriesMatch(expected, entry) && filepath.Clean(entry.Directory) == filepath.Clean(expected.Directory) {
				return nil
			}
			if entry.CaptureError != "" {
				last = entry.CaptureError
			} else {
				last = fmt.Sprintf("observed %s session %s", entry.Agent, entry.SessionID)
			}
		}
		time.Sleep(350 * time.Millisecond)
	}
	if last == "" {
		last = "agent did not become identifiable before the verification deadline"
	}
	return errors.New(last)
}

func (s *Store) restoreOne(panel PanelStatus) RestoreResult {
	result := RestoreResult{Name: panel.Name, SessionID: panel.SessionID}
	if panel.State == PanelAlreadyRunning {
		result.State = RestoreAlreadyRunning
		result.Detail = panel.Detail
		return result
	}
	if panel.State != PanelReady {
		result.State = RestoreFailed
		result.Detail = panel.Detail
		return result
	}
	// Re-run preflight immediately before mutation so a concurrent click or CLI
	// cannot overwrite a session created after the status screen was loaded.
	current := map[string]Entry{}
	if entry, ok := currentEntry(s.Socket, panel.Name); ok {
		current[panel.Name] = entry
	}
	fresh := preflight(panel.Entry, current)
	if fresh.State == PanelAlreadyRunning {
		result.State = RestoreAlreadyRunning
		result.Detail = fresh.Detail
		return result
	}
	if fresh.State != PanelReady {
		result.State = RestoreFailed
		result.Detail = fresh.Detail
		return result
	}
	if err := createRestoredSession(s.Socket, fresh); err != nil {
		result.State = RestoreFailed
		result.Detail = err.Error()
		return result
	}
	if err := verifyRestored(s.Socket, panel.Entry, 25*time.Second); err != nil {
		result.State = RestoreFailed
		result.Detail = "Created, but identity verification failed: " + err.Error()
		return result
	}
	result.State = RestoreRestored
	result.Detail = "Working directory and session identity verified."
	return result
}

func (s *Store) Restore(snapshotID string, names []string, concurrency int) RestoreResponse {
	status := s.Status(snapshotID)
	response := RestoreResponse{SnapshotID: snapshotID}
	if status.Error != "" || status.Snapshot == nil {
		detail := status.Error
		if detail == "" {
			detail = "recovery snapshot is unavailable"
		}
		return RestoreResponse{SnapshotID: snapshotID, Results: []RestoreResult{{State: RestoreFailed, Detail: detail}}}
	}
	wanted := map[string]bool{}
	for _, name := range names {
		wanted[name] = true
	}
	var panels []PanelStatus
	found := map[string]bool{}
	for _, panel := range status.Panels {
		if (len(wanted) == 0 && panel.State == PanelReady) || wanted[panel.Name] {
			panels = append(panels, panel)
			found[panel.Name] = true
		}
	}
	if concurrency < 1 {
		concurrency = 3
	}
	if concurrency > 6 {
		concurrency = 6
	}
	results := make([]RestoreResult, len(panels))
	startAt := 0
	if _, _, _, _, err := tmuxServerIdentity(s.Socket); errors.Is(err, errNoTmuxServer) && len(panels) > 0 {
		// Starting several `tmux new-session` processes against a nonexistent
		// socket can race server creation. Establish the first session
		// synchronously, then use bounded parallelism for the rest.
		results[0] = s.restoreOne(panels[0])
		startAt = 1
	}
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup
	for index := startAt; index < len(panels); index++ {
		panel := panels[index]
		wg.Add(1)
		go func(index int, panel PanelStatus) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			results[index] = s.restoreOne(panel)
		}(index, panel)
	}
	wg.Wait()
	for _, name := range names {
		if !found[name] {
			results = append(results, RestoreResult{Name: name, State: RestoreFailed, Detail: "Panel is not present in this recovery snapshot."})
		}
	}
	response.Results = results
	return response
}

func (s *Store) Bootstrap(sessionName string) error {
	if sessionName == "" {
		panes, err := listPanes(s.Socket)
		if err != nil || len(panes) == 0 {
			return fmt.Errorf("no restored session is available to bootstrap the broker")
		}
		sessionName = panes[0].Name
	}
	home, _ := os.UserHomeDir()
	candidates := []string{}
	if value := os.Getenv("UT_CLI"); value != "" {
		candidates = append(candidates, value)
	}
	if executable, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(executable), "ut"))
	}
	candidates = append(candidates, filepath.Join(home, ".universal-tmux", "ut"))
	if path, err := exec.LookPath("ut"); err == nil {
		candidates = append(candidates, path)
	}
	var cli string
	for _, candidate := range uniqueStrings(candidates) {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			cli = candidate
			break
		}
	}
	if cli == "" {
		return fmt.Errorf("ut launcher was not found")
	}
	args := []string{"-L", s.Socket, sessionName}
	cmd := exec.Command(cli, args...)
	path := os.Getenv("PATH")
	for _, directory := range []string{"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"} {
		if !strings.Contains(":"+path+":", ":"+directory+":") {
			path = directory + ":" + path
		}
	}
	overrides := map[string]string{"UT_NO_ATTACH": "1", "PATH": path}
	if executable, err := os.Executable(); err == nil {
		overrides["UT_BROKER"] = executable
	}
	cmd.Env = environmentWithOverrides(os.Environ(), overrides)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("bootstrap broker: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
