//go:build !windows

package recovery

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"universal-tmux/internal/devinsession"
)

// Only main ACP session-store events bind a conversation. Request IDs, prompts,
// tool output and subagent spans in the same log are not ownership evidence.
var devinCreatedSession = regexp.MustCompile(`^\S+\s+INFO run_acp_server:session_db_call:session_db_job: chisel_agent::session_db: Created new session: ([A-Za-z0-9_-]+)$`)
var devinSavedSession = regexp.MustCompile(`^\S+\s+INFO run_acp_server:session_db_call:session_db_job: chisel_agent::session_db: Saved [0-9]+ message nodes \(starting from [0-9]+\) for session ([A-Za-z0-9_-]+)$`)

func devinSessionFromLog(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return "", err
	}
	// A truncated tail cannot prove that the process used only one session.
	if info.Size() > 8<<20 {
		return "", fmt.Errorf("Devin ownership log exceeds inspection budget")
	}
	scanner := bufio.NewScanner(io.LimitReader(f, (8<<20)+1))
	scanner.Buffer(make([]byte, 4096), 1<<20)
	id := ""
	for scanner.Scan() {
		for _, pattern := range []*regexp.Regexp{devinCreatedSession, devinSavedSession} {
			match := pattern.FindStringSubmatch(strings.TrimSpace(scanner.Text()))
			if len(match) != 2 {
				continue
			}
			if !devinsession.ValidSessionID(match[1]) || (id != "" && id != match[1]) {
				return "", fmt.Errorf("Devin process log has ambiguous conversation ownership")
			}
			id = match[1]
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if id == "" {
		return "", fmt.Errorf("Devin process log has no conversation identity")
	}
	return id, nil
}

func inspectDevinFiles(files []string, state processState) (AgentSession, error) {
	root := devinsession.DataDirectory(state.Environment["HOME"], state.Environment["XDG_DATA_HOME"])
	database := filepath.Join(root, "sessions.db")
	ownedDatabase := false
	var logs []string
	for _, path := range files {
		path = filepath.Clean(path)
		if path == database {
			ownedDatabase = true
		}
		if filepath.Dir(path) == filepath.Join(root, "logs") && strings.HasSuffix(path, ".log") {
			logs = append(logs, path)
		}
	}
	if !ownedDatabase {
		return AgentSession{}, fmt.Errorf("Devin process has no open session database")
	}
	var identity string
	for _, path := range logs {
		id, err := devinSessionFromLog(path)
		if err != nil {
			return AgentSession{}, err
		}
		if identity != "" && identity != id {
			return AgentSession{}, fmt.Errorf("Devin process has ambiguous session logs")
		}
		identity = id
	}
	if identity == "" {
		return AgentSession{}, fmt.Errorf("Devin process has no owned conversation log")
	}
	if !devinsession.Exists(database, identity) {
		return AgentSession{}, fmt.Errorf("Devin's process-owned conversation is absent from its store")
	}
	return AgentSession{Agent: AgentDevin, ID: identity, Path: database, RequireScreenMatch: true}, nil
}

// The interactive frontend delegates storage to an ACP child. Follow only
// same-job descendants, never other sessions or unrelated background agents.
func inspectDevin(root processInfo, processes map[int]processInfo, state processState) (AgentSession, error) {
	pending := []int{root.PID}
	seen := map[int]bool{}
	var found AgentSession
	for len(pending) > 0 {
		pid := pending[0]
		pending = pending[1:]
		if seen[pid] {
			continue
		}
		seen[pid] = true
		for _, process := range processes {
			if process.PPID == pid && process.PGID == root.PGID {
				pending = append(pending, process.PID)
			}
		}
		process := processes[pid]
		if processAgent(process) != AgentDevin {
			continue
		}
		childState := state
		if pid != root.PID {
			var err error
			childState, err = platformProcessState(pid)
			if err != nil || leadingSubcommand(childState.Argv, devinRestoreOptions) != "acp" {
				continue
			}
		}
		files, err := platformOpenFiles(pid)
		if err != nil {
			continue
		}
		session, err := inspectDevinFiles(files, childState)
		if err != nil {
			continue
		}
		if found.ID != "" && (found.ID != session.ID || found.Path != session.Path) {
			return AgentSession{}, fmt.Errorf("Devin foreground job has ambiguous conversation ownership")
		}
		found = session
	}
	if found.ID == "" {
		return AgentSession{}, fmt.Errorf("Devin foreground job has no process-owned conversation identity")
	}
	return found, nil
}
