package recovery

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type optionSpec struct {
	Values int // number of following argv values; -1 means consume values until the next option
}

var codexRestoreOptions = map[string]optionSpec{
	"--yolo": {0}, "--dangerously-bypass-approvals-and-sandbox": {0},
	"--dangerously-bypass-hook-trust": {0}, "--search": {0}, "--oss": {0},
	"--no-alt-screen": {0}, "--strict-config": {0},
	"-c": {1}, "--config": {1}, "--enable": {1}, "--disable": {1},
	"-i": {-1}, "--image": {-1}, "-m": {1}, "--model": {1},
	"-p": {1}, "--profile": {1}, "-s": {1}, "--sandbox": {1},
	"-a": {1}, "--ask-for-approval": {1}, "--add-dir": {1},
	"--local-provider": {1}, "--remote": {1}, "--remote-auth-token-env": {1},
}

var claudeRestoreOptions = map[string]optionSpec{
	"--dangerously-skip-permissions": {0}, "--allow-dangerously-skip-permissions": {0},
	"--chrome": {0}, "--no-chrome": {0}, "--strict-mcp-config": {0},
	"--ide": {0}, "--verbose": {0},
	"--permission-mode": {1}, "--model": {1}, "--fallback-model": {1},
	"--effort": {1}, "--agent": {1}, "--add-dir": {-1},
	"--allowedTools": {-1}, "--allowed-tools": {-1},
	"--disallowedTools": {-1}, "--disallowed-tools": {-1},
	"--tools": {-1}, "--plugin-dir": {-1}, "--mcp-config": {-1},
	"--settings": {1}, "--setting-sources": {1},
	"--system-prompt": {1}, "--system-prompt-file": {1},
	"--append-system-prompt": {1}, "--append-system-prompt-file": {1},
	"--betas": {-1}, "--debug": {0}, "--debug-file": {1},
	"--remote-control": {0}, "--remote-control-session-name-prefix": {1},
}

func splitOption(arg string) (string, bool) {
	if !strings.HasPrefix(arg, "--") {
		return arg, false
	}
	if index := strings.IndexByte(arg, '='); index > 0 {
		return arg[:index], true
	}
	return arg, false
}

// preserveOptions parses only options whose resume behavior is explicit. It
// never carries an initial prompt into a restored conversation, and an unknown
// option blocks automatic restoration instead of being silently dropped.
func preserveOptions(args []string, specs map[string]optionSpec, stopWords map[string]bool) ([]string, error) {
	var out []string
	for index := 0; index < len(args); {
		arg := args[index]
		if stopWords[arg] {
			break
		}
		name, inlineValue := splitOption(arg)
		spec, ok := specs[name]
		if !ok {
			if !strings.HasPrefix(arg, "-") {
				return nil, fmt.Errorf("initial prompt or positional argument %q is not replayed automatically", arg)
			}
			return nil, fmt.Errorf("unknown startup option %q requires manual review", arg)
		}
		out = append(out, arg)
		index++
		if inlineValue || spec.Values == 0 {
			continue
		}
		if spec.Values > 0 {
			if index+spec.Values > len(args) {
				return nil, fmt.Errorf("startup option %q is missing its value", arg)
			}
			out = append(out, args[index:index+spec.Values]...)
			index += spec.Values
			continue
		}
		start := index
		for index < len(args) && !strings.HasPrefix(args[index], "-") && !stopWords[args[index]] {
			out = append(out, args[index])
			index++
		}
		if index == start {
			return nil, fmt.Errorf("startup option %q is missing its value", arg)
		}
	}
	return out, nil
}

// normalizeCodexResumeArgs removes the extra launcher marker emitted by some
// Codex wrappers. It is safe to ignore only when it sits directly before a
// resume selector whose ID matches the conversation independently identified
// from Codex's open rollout file.
func normalizeCodexResumeArgs(args []string, sessionID string) []string {
	for index := 1; index+1 < len(args); index++ {
		if args[index] != "resume" || args[index+1] != sessionID || !strings.EqualFold(args[index-1], AgentCodex) {
			continue
		}
		return append(append([]string{}, args[:index-1]...), args[index:]...)
	}
	return args
}

func effectiveExecutable(entry Entry) (string, error) {
	for _, candidate := range []string{entry.Executable, firstArg(entry.Argv)} {
		if candidate != "" {
			if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
				return candidate, nil
			}
		}
	}
	name := entry.Agent
	if len(entry.Argv) > 0 && entry.Argv[0] != "" {
		name = filepath.Base(entry.Argv[0])
	}
	path, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("%s executable is no longer installed", entry.Agent)
	}
	return path, nil
}

func firstArg(argv []string) string {
	if len(argv) == 0 {
		return ""
	}
	return strings.TrimSpace(argv[0])
}

// codexResumeSessionFromArgv accepts only an explicit, unambiguous
// `resume <UUID>` selector from the kernel-owned process argv. This is not a
// transcript scan or a command-name convention: it is the exact conversation
// selector the running Codex process was launched with. Multiple different
// selectors fail closed.
func codexResumeSessionFromArgv(argv []string) (string, bool) {
	unique := map[string]bool{}
	for index := 1; index+1 < len(argv); index++ {
		if argv[index] == "resume" && uuidPattern.MatchString(argv[index+1]) {
			unique[strings.ToLower(argv[index+1])] = true
		}
	}
	if len(unique) != 1 {
		return "", false
	}
	for id := range unique {
		return id, true
	}
	return "", false
}

func enrichProcessOwnedSessionEvidence(entry Entry) Entry {
	if entry.Agent != AgentCodex || entry.SessionID != "" {
		return entry
	}
	id, ok := codexResumeSessionFromArgv(entry.Argv)
	if !ok {
		return entry
	}
	entry.SessionID = id
	entry.SessionEvidence = "resume-argv"
	entry.CaptureError = ""
	return entry
}

// capturedLaunchArgv returns the exact argv stored in the recovery snapshot
// after proving only that its executable is still available on this target.
// The caller must require an explicit user review; arguments are never parsed,
// rewritten, or passed through a shell.
func capturedLaunchArgv(entry Entry) ([]string, error) {
	if len(entry.Argv) == 0 || firstArg(entry.Argv) == "" {
		return nil, fmt.Errorf("no captured launch command is available")
	}
	executable := firstArg(entry.Argv)
	if strings.ContainsRune(executable, os.PathSeparator) {
		info, err := os.Stat(executable)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			return nil, fmt.Errorf("captured executable %q is not available", executable)
		}
	} else if _, err := exec.LookPath(executable); err != nil {
		return nil, fmt.Errorf("captured executable %q is not available", executable)
	}
	return append([]string(nil), entry.Argv...), nil
}

func capturedLaunchAvailable(entry Entry) bool {
	_, err := capturedLaunchArgv(entry)
	return err == nil
}

func environmentExecutable() string {
	if path, err := exec.LookPath("env"); err == nil {
		return path
	}
	return "env"
}

func resumeArgv(entry Entry) ([]string, error) {
	if entry.Agent == AgentShell {
		return nil, nil
	}
	if !uuidPattern.MatchString(entry.SessionID) {
		return nil, fmt.Errorf("%s session ID is missing or invalid", entry.Agent)
	}
	executable, err := effectiveExecutable(entry)
	if err != nil {
		return nil, err
	}
	args := entry.Argv
	if len(args) == 0 {
		return nil, fmt.Errorf("%s kernel argv was not captured", entry.Agent)
	}
	switch entry.Agent {
	case AgentCodex:
		codexArgs := normalizeCodexResumeArgs(args[1:], entry.SessionID)
		options, err := preserveOptions(codexArgs, codexRestoreOptions, map[string]bool{"resume": true})
		if err != nil {
			return nil, err
		}
		command := append([]string{executable}, append(options, "resume", entry.SessionID)...)
		if home := effectiveCodexHome(entry); home != "" {
			command = append([]string{environmentExecutable(), "CODEX_HOME=" + home}, command...)
		}
		return command, nil
	case AgentClaude:
		options, err := preserveOptions(args[1:], claudeRestoreOptions, map[string]bool{
			"-r": true, "--resume": true, "-c": true, "--continue": true,
		})
		if err != nil {
			return nil, err
		}
		command := append([]string{executable}, append(options, "--resume", entry.SessionID)...)
		if config := strings.TrimSpace(entry.ClaudeConfig); config != "" {
			command = append([]string{environmentExecutable(), "CLAUDE_CONFIG_DIR=" + filepath.Clean(config)}, command...)
		}
		return command, nil
	default:
		return nil, fmt.Errorf("unsupported agent %q", entry.Agent)
	}
}

// effectiveCodexHome preserves the account/profile behind any Codex launcher
// (codex2 today, arbitrary wrappers tomorrow). New snapshots record it
// explicitly; older snapshots can recover it from the authoritative rollout
// path without guessing from a command name.
func effectiveCodexHome(entry Entry) string {
	if home := strings.TrimSpace(entry.CodexHome); home != "" {
		return filepath.Clean(home)
	}
	return codexHomeFromTranscript(entry.SessionPath)
}

func codexHomeFromTranscript(path string) string {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "." || path == "" {
		return ""
	}
	for directory := filepath.Dir(path); ; directory = filepath.Dir(directory) {
		if filepath.Base(directory) == "sessions" {
			return filepath.Dir(directory)
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			return ""
		}
	}
}

func shellJoin(argv []string) string {
	parts := make([]string, len(argv))
	for index, arg := range argv {
		if arg != "" && strings.IndexFunc(arg, func(r rune) bool {
			return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("_@%+=:,./-", r))
		}) == -1 {
			parts[index] = arg
		} else {
			parts[index] = "'" + strings.ReplaceAll(arg, "'", "'\"'\"'") + "'"
		}
	}
	return strings.Join(parts, " ")
}
