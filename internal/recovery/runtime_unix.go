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
	Visible    bool
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
		"#{@ut_agent}", "#{@ut_visible}", "#{window_active}", "#{pane_active}", "#{pane_current_path}",
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
		fields := strings.SplitN(line, "\t", 9)
		if len(fields) != 9 || strings.HasPrefix(fields[0], "_ut-") {
			continue
		}
		pid, pidErr := strconv.Atoi(fields[1])
		windows, windowsErr := strconv.Atoi(fields[3])
		if pidErr != nil || windowsErr != nil {
			continue
		}
		pane := paneInfo{
			Name: fields[0], PanePID: pid, TTY: fields[2], Windows: windows,
			AgentOwned: fields[4] == "1", Visible: fields[5] == "1",
			Active: fields[6] == "1" && fields[7] == "1", Directory: fields[8],
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
		if agg.chosen.AgentOwned || !agg.chosen.Visible {
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

func codexHome(state processState) string {
	if value := strings.TrimSpace(state.Environment["CODEX_HOME"]); value != "" {
		return filepath.Clean(value)
	}
	if value := strings.TrimSpace(state.Environment["HOME"]); value != "" {
		return filepath.Join(value, ".codex")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".codex")
}

func resolvedPath(path string) string {
	if value, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(value)
	}
	return filepath.Clean(path)
}

func pathWithin(root, path string) bool {
	relative, err := filepath.Rel(resolvedPath(root), resolvedPath(path))
	return err == nil && relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(filepath.Separator)) &&
		!filepath.IsAbs(relative)
}

func codexRollouts(files []string, state processState) []string {
	root := filepath.Join(codexHome(state), "sessions")
	var rollouts []string
	for _, path := range files {
		name := filepath.Base(path)
		if pathWithin(root, path) && strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl") {
			rollouts = append(rollouts, path)
		}
	}
	sort.Strings(rollouts)
	return uniqueStrings(rollouts)
}

func inspectCodexRollout(path string) (id, sessionID string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return "", "", err
	}
	var record struct {
		Type    string `json:"type"`
		Payload struct {
			ID        string `json:"id"`
			SessionID string `json:"session_id"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &record) != nil || record.Type != "session_meta" {
		return "", "", fmt.Errorf("Codex rollout lacks session_meta")
	}
	id = record.Payload.ID
	sessionID = record.Payload.SessionID
	if id == "" {
		id = sessionID
	}
	if !uuidPattern.MatchString(id) {
		return "", "", fmt.Errorf("Codex rollout has an invalid session ID")
	}
	return id, sessionID, nil
}

func inspectCodexRollouts(rollouts []string) (string, string, error) {
	if len(rollouts) == 0 {
		return "", "", fmt.Errorf("Codex process has no open rollout files")
	}

	// Current Codex builds keep subagent rollouts open in the root process. The
	// root rollout identifies itself by using the same conversation and session
	// ID; subagents have their own ID and point session_id back at the root.
	// Require one unambiguous root instead of rejecting every multi-agent turn.
	type rootRollout struct {
		id   string
		path string
	}
	var roots []rootRollout
	for _, path := range rollouts {
		id, sessionID, err := inspectCodexRollout(path)
		if err != nil {
			continue
		}
		if sessionID == "" || id == sessionID {
			roots = append(roots, rootRollout{id: id, path: path})
		}
	}
	if len(roots) != 1 {
		return "", "", fmt.Errorf("Codex process has %d open rollout files and %d unambiguous roots", len(rollouts), len(roots))
	}
	return roots[0].id, roots[0].path, nil
}

func inspectCodex(pid int, state processState) (string, string, error) {
	files, err := platformOpenFiles(pid)
	if err != nil {
		return "", "", fmt.Errorf("list Codex open files: %w", err)
	}
	return inspectCodexRollouts(codexRollouts(files, state))
}

// InspectAgentSession identifies the foreground agent conversation in a tmux
// session from kernel-owned process state. Provider-specific discovery stays
// here; consumers receive the same process-proven transcript contract.
func InspectAgentSession(socket, name string) (AgentSession, error) {
	panes, err := listPanes(socket)
	if err != nil {
		return AgentSession{}, err
	}
	for _, pane := range panes {
		if pane.Name != name {
			continue
		}
		processes, err := readProcessTable()
		if err != nil {
			return AgentSession{}, err
		}
		agent, process, ok := findAgent(pane.PanePID, processes)
		if !ok {
			return AgentSession{}, fmt.Errorf("session %q has no supported foreground agent process", name)
		}
		state, err := platformProcessState(process.PID)
		if err != nil {
			return AgentSession{}, err
		}
		var id, path string
		switch agent {
		case AgentCodex:
			id, path, err = inspectCodex(process.PID, state)
		case AgentClaude:
			id, path, _, err = inspectClaude(process.PID, state)
		default:
			err = fmt.Errorf("unsupported foreground agent %q", agent)
		}
		if err != nil {
			return AgentSession{}, err
		}
		if path == "" {
			return AgentSession{}, fmt.Errorf("%s process has no exact transcript file", agent)
		}
		return AgentSession{Agent: agent, ID: id, Path: path}, nil
	}
	return AgentSession{}, fmt.Errorf("no such session: %q", name)
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
		entry.ClaudeConfig = strings.TrimSpace(state.Environment["CLAUDE_CONFIG_DIR"])
	case AgentCodex:
		entry.SessionID, entry.SessionPath, err = inspectCodex(process.PID, state)
		entry.CodexHome = strings.TrimSpace(state.Environment["CODEX_HOME"])
		if entry.CodexHome == "" {
			entry.CodexHome = codexHomeFromTranscript(entry.SessionPath)
		}
	}
	if err != nil {
		entry.CaptureError = err.Error()
	}
	return enrichProcessOwnedSessionEvidence(entry)
}

// Capture records the latest valid state for the current tmux server lifetime.
func (s *Store) Capture() (Snapshot, error) {
	boot, serverPID, started, serverID, err := tmuxServerIdentity(s.Socket)
	if err != nil {
		return Snapshot{}, err
	}
	panes, err := listPanesForCapture(s.Socket, 2*time.Second)
	if err != nil {
		return Snapshot{}, err
	}
	processes, err := readProcessTable()
	if err != nil {
		return Snapshot{}, err
	}
	host := s.Host
	if host == "" {
		host, _ = os.Hostname()
	}
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

// A newly created tmux pane can exist a few scheduler ticks before tmux has a
// current path for it. An empty path is not a usable recovery record: passing
// it back through `new-session -c` either fails or restores in an arbitrary
// directory. Wait briefly for tmux to settle, and if it never does, leave the
// previous valid snapshot untouched by failing this capture.
func listPanesForCapture(socket string, timeout time.Duration) ([]paneInfo, error) {
	deadline := time.Now().Add(timeout)
	for {
		panes, err := listPanes(socket)
		if err != nil {
			return nil, err
		}
		invalid := ""
		for _, pane := range panes {
			if strings.TrimSpace(pane.Directory) == "" {
				invalid = pane.Name
				break
			}
		}
		if invalid == "" {
			return panes, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("tmux pane %q has no stable working directory", invalid)
		}
		time.Sleep(50 * time.Millisecond)
	}
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

func (s *Store) Status(requestedSnapshot string) Status {
	current, currentServerID := currentEntries(s.Socket)
	return s.statusWithCurrent(requestedSnapshot, current, currentServerID)
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
	args = append(args,
		";", "set-option", "-t", panel.Name, "@ut_visible", "1",
		";", "set-option", "-t", panel.Name, "@ut_origin", "workspace-restore",
	)
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

func prepareCapturedLaunch(panel PanelStatus) PanelStatus {
	if panel.State != PanelUnsupported || !panel.CapturedLaunchReviewable {
		return panel
	}
	argv, err := capturedLaunchArgv(panel.Entry)
	if err != nil {
		panel.Detail = err.Error()
		return panel
	}
	panel.ResumeArgv = argv
	panel.State = PanelReady
	panel.Detail = "Launch the exact captured command after explicit review."
	return panel
}

func verifyCapturedLaunch(socket string, expected Entry, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var last string
	for time.Now().Before(deadline) {
		entry, ok := currentEntry(socket, expected.Name)
		if ok {
			sameDirectory := equivalentDirectory(entry.Directory, expected.Directory)
			if sameDirectory && entry.Agent == expected.Agent {
				return nil
			}
			last = fmt.Sprintf("observed %s session in %s", entry.Agent, entry.Directory)
		}
		time.Sleep(350 * time.Millisecond)
	}
	if last == "" {
		last = "captured agent command did not remain active before the verification deadline"
	}
	return errors.New(last)
}

func equivalentDirectory(left, right string) bool {
	left = filepath.Clean(left)
	right = filepath.Clean(right)
	if resolved, err := filepath.EvalSymlinks(left); err == nil {
		left = resolved
	}
	if resolved, err := filepath.EvalSymlinks(right); err == nil {
		right = resolved
	}
	return left == right
}

func (s *Store) restoreOne(panel PanelStatus, useCapturedLaunch bool) RestoreResult {
	result := RestoreResult{Name: panel.Name, SessionID: panel.SessionID}
	if useCapturedLaunch {
		panel = prepareCapturedLaunch(panel)
	}
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
	if useCapturedLaunch {
		fresh = prepareCapturedLaunch(fresh)
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
	verify := verifyRestored
	if useCapturedLaunch {
		verify = verifyCapturedLaunch
	}
	if err := verify(s.Socket, panel.Entry, 25*time.Second); err != nil {
		result.State = RestoreFailed
		result.Detail = "Created, but identity verification failed: " + err.Error()
		return result
	}
	result.State = RestoreRestored
	if useCapturedLaunch {
		result.Detail = "Captured launch started after explicit review; working directory and agent process verified."
	} else {
		result.Detail = "Working directory and session identity verified."
	}
	return result
}

func (s *Store) Restore(snapshotID string, names []string, concurrency int) RestoreResponse {
	return s.restore(snapshotID, names, concurrency, false)
}

// RestoreCapturedLaunch is the explicit-review escape hatch for a panel whose
// conversation cannot be reconstructed automatically. It reloads argv from the
// server-owned snapshot and executes it as argv—not a client-provided command
// string—while retaining the normal directory and name-conflict checks.
func (s *Store) RestoreCapturedLaunch(snapshotID string, names []string, concurrency int) RestoreResponse {
	if len(names) == 0 {
		return RestoreResponse{
			SnapshotID: snapshotID,
			Results:    []RestoreResult{{State: RestoreFailed, Detail: "An explicitly reviewed panel name is required."}},
		}
	}
	return s.restore(snapshotID, names, concurrency, true)
}

func (s *Store) restore(snapshotID string, names []string, concurrency int, useCapturedLaunch bool) RestoreResponse {
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
			if useCapturedLaunch && (panel.State != PanelUnsupported || !panel.CapturedLaunchReviewable) {
				panel.State = PanelUnsupported
				panel.Detail = "This panel does not have an explicitly reviewable captured launch."
				panel.CapturedLaunchReviewable = false
			}
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
		results[0] = s.restoreOne(panels[0], useCapturedLaunch)
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
			results[index] = s.restoreOne(panel, useCapturedLaunch)
		}(index, panel)
	}
	wg.Wait()
	targetServer := ""
	var targetCaptureErr error
	if s.Cluster != "" && !sameRecoveryHost(status.Snapshot.Host, s.Host) {
		for _, result := range results {
			if result.State == RestoreRestored || result.State == RestoreAlreadyRunning {
				target, err := s.Capture()
				if err != nil {
					targetCaptureErr = err
				} else {
					targetServer = target.ServerID
				}
				break
			}
		}
	}
	for index := range results {
		if results[index].State == RestoreRestored || results[index].State == RestoreAlreadyRunning {
			if targetCaptureErr != nil {
				results[index].State = RestoreFailed
				results[index].Detail = "Workspace resumed, but the target recovery snapshot could not be saved: " + targetCaptureErr.Error()
				continue
			}
			if err := s.markRestored(*status.Snapshot, results[index].Name, targetServer); err != nil {
				results[index].State = RestoreFailed
				results[index].Detail = "Workspace resumed, but its cross-node recovery receipt could not be saved: " + err.Error()
			}
		}
	}
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
