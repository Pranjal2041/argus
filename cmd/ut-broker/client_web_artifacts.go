package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"universal-tmux/internal/webartifact"
)

func cmdWebArtifacts(args []string) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Print(webArtifactsHelp)
		return 0
	}
	switch args[0] {
	case "add":
		return cmdWebArtifactSave(args[1:], false)
	case "update":
		return cmdWebArtifactSave(args[1:], true)
	case "list", "ls":
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "usage: ut web-artifacts list")
			return 2
		}
		return cmdWebArtifactList()
	case "remove", "rm":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "usage: ut web-artifacts remove <id|name>")
			return 2
		}
		return cmdWebArtifactRemove(args[1])
	default:
		fmt.Fprintf(os.Stderr, "ut web-artifacts: unknown command %q (try `ut web-artifacts help`)\n", args[0])
		return 2
	}
}

type webArtifactSaveArgs struct {
	target      string
	name        string
	cwd         string
	endpointURL string
	command     string
	commandFile string
	session     string
	port        string
}

func cmdWebArtifactSave(args []string, updating bool) int {
	parsed, err := parseWebArtifactSaveArgs(args, updating)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 2
	}
	if parsed.commandFile != "" {
		var body []byte
		if parsed.commandFile == "-" {
			body, err = io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
		} else {
			body, err = os.ReadFile(parsed.commandFile)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "ut web-artifacts: read command:", err)
			return 1
		}
		parsed.command = strings.TrimSpace(string(body))
	}
	if !filepath.IsAbs(parsed.cwd) {
		fmt.Fprintf(os.Stderr, "ut web-artifacts: --cwd must be an absolute path, got %q\n", parsed.cwd)
		return 2
	}
	portMode, err := applyWebArtifactPort(&parsed)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 2
	}
	context, err := resolveCurrentWebArtifactSession(parsed.session)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 1
	}
	request := webartifact.AddRequest{
		Name: parsed.name, SessionName: context.Name,
		StableSessionID: context.ID, SessionLineageID: context.LineageID,
		WorkingDirectory: parsed.cwd, Command: parsed.command, URL: parsed.endpointURL,
		PortMode: portMode,
	}
	payload, _ := json.Marshal(request)
	method := http.MethodPost
	endpoint := localBase() + "/web-artifacts"
	if updating {
		id, resolveErr := resolveWebArtifactID(parsed.target)
		if resolveErr != nil {
			fmt.Fprintln(os.Stderr, "ut web-artifacts:", resolveErr)
			return 1
		}
		method = http.MethodPut
		endpoint += "?id=" + url.QueryEscape(id)
	}
	body, code, err := httpRequest(method, endpoint, payload, 15*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 1
	}
	if code < 200 || code >= 300 {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", responseError(body, code))
		return 1
	}
	var saved webartifact.Recipe
	if err := json.Unmarshal(body, &saved); err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts: broker returned an invalid recipe")
		return 1
	}
	verb := "Saved"
	if updating {
		verb = "Updated"
	}
	fmt.Printf("%s web artifact %q (%s)\n", verb, saved.Name, saved.ID)
	fmt.Printf("  machine:   %s\n", saved.MachineName)
	fmt.Printf("  session:   %s\n", saved.SessionName)
	fmt.Printf("  directory: %s\n", saved.WorkingDirectory)
	fmt.Printf("  url:       %s\n", saved.URL)
	if saved.PortMode == webartifact.PortModeAuto {
		fmt.Println("  port:      automatic (allocated when launched)")
	}
	fmt.Println("No command was run. Open this artifact in Argus when you want to start it.")
	return 0
}

func parseWebArtifactSaveArgs(args []string, updating bool) (webArtifactSaveArgs, error) {
	var result webArtifactSaveArgs
	if updating {
		if len(args) < 2 {
			return result, fmt.Errorf("usage: ut web-artifacts update <id|name> <name> --cwd <absolute-path> --url <loopback-url> --command <command>")
		}
		result.target, result.name, args = args[0], args[1], args[2:]
	} else {
		if len(args) < 1 {
			return result, fmt.Errorf("usage: ut web-artifacts add <name> --cwd <absolute-path> --url <loopback-url> --command <command>")
		}
		result.name, args = args[0], args[1:]
	}
	for i := 0; i < len(args); i++ {
		flag := args[i]
		if i+1 >= len(args) {
			return result, fmt.Errorf("%s requires a value", flag)
		}
		value := args[i+1]
		i++
		switch flag {
		case "--cwd":
			result.cwd = value
		case "--url":
			result.endpointURL = value
		case "--command":
			result.command = value
		case "--command-file":
			result.commandFile = value
		case "--session":
			result.session = value
		case "--port":
			result.port = value
		default:
			return result, fmt.Errorf("unknown option %q", flag)
		}
	}
	if strings.TrimSpace(result.name) == "" {
		return result, fmt.Errorf("name is required")
	}
	if result.cwd == "" || result.endpointURL == "" {
		return result, fmt.Errorf("--cwd and --url are required")
	}
	if (result.command == "") == (result.commandFile == "") {
		return result, fmt.Errorf("provide exactly one of --command or --command-file")
	}
	return result, nil
}

func applyWebArtifactPort(parsed *webArtifactSaveArgs) (string, error) {
	value := strings.ToLower(strings.TrimSpace(parsed.port))
	if value == "" {
		_, err := webartifact.ParseEndpoint(parsed.endpointURL)
		return "", err
	}
	if value == webartifact.PortModeAuto {
		request := webartifact.AddRequest{
			Name: "validation", SessionName: "validation", WorkingDirectory: parsed.cwd,
			Command: parsed.command, URL: parsed.endpointURL, PortMode: webartifact.PortModeAuto,
		}
		if err := webartifact.ValidateRequest(request); err != nil {
			return "", err
		}
		return webartifact.PortModeAuto, nil
	}
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return "", fmt.Errorf("--port must be `auto` or a number from 1 to 65535")
	}
	if !strings.Contains(parsed.endpointURL, webartifact.PortPlaceholder) ||
		!strings.Contains(parsed.command, webartifact.PortPlaceholder) {
		return "", fmt.Errorf("numeric --port requires %s in both --url and the launch command", webartifact.PortPlaceholder)
	}
	replacement := strconv.Itoa(port)
	parsed.endpointURL = strings.ReplaceAll(parsed.endpointURL, webartifact.PortPlaceholder, replacement)
	parsed.command = strings.ReplaceAll(parsed.command, webartifact.PortPlaceholder, replacement)
	_, err = webartifact.ParseEndpoint(parsed.endpointURL)
	return "", err
}

type webArtifactSession struct {
	Name      string `json:"name"`
	ID        string `json:"id"`
	LineageID string `json:"lineageID"`
}

func resolveCurrentWebArtifactSession(explicit string) (webArtifactSession, error) {
	name := strings.TrimSpace(explicit)
	lineageID := ""
	if name == "" {
		lineageID = strings.TrimSpace(os.Getenv("UT_SESSION_LINEAGE_ID"))
	}
	if name == "" && lineageID == "" {
		var err error
		name, err = currentTmuxSessionName(os.Getenv("TMUX"), os.Getenv("TMUX_PANE"))
		if err != nil {
			return webArtifactSession{}, fmt.Errorf("cannot determine the originating session: %w; pass --session <name> explicitly", err)
		}
	}
	body, code, err := httpGet(localBase()+"/sessions", 8*time.Second)
	if err != nil {
		return webArtifactSession{}, fmt.Errorf("cannot verify session %q with the local broker: %w", name, err)
	}
	if code != http.StatusOK {
		return webArtifactSession{}, fmt.Errorf("cannot verify session %q: %s", name, responseError(body, code))
	}
	var response struct {
		Sessions []webArtifactSession `json:"sessions"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return webArtifactSession{}, fmt.Errorf("local broker returned invalid session metadata")
	}
	if session, ok := matchWebArtifactSession(response.Sessions, name, lineageID); ok {
		return session, nil
	}
	if lineageID != "" {
		return webArtifactSession{}, fmt.Errorf("the current Windows panel is not owned by this machine's ut broker")
	}
	return webArtifactSession{}, fmt.Errorf("session %q is not owned by this machine's ut broker", name)
}

func matchWebArtifactSession(sessions []webArtifactSession, name, lineageID string) (webArtifactSession, bool) {
	for _, session := range sessions {
		if (name != "" && session.Name == name) ||
			(lineageID != "" && session.LineageID == lineageID) {
			return session, true
		}
	}
	return webArtifactSession{}, false
}

func currentTmuxSessionName(tmuxEnvironment, pane string) (string, error) {
	if strings.TrimSpace(tmuxEnvironment) == "" || strings.TrimSpace(pane) == "" {
		return "", fmt.Errorf("TMUX/TMUX_PANE are not set")
	}
	socket := strings.SplitN(tmuxEnvironment, ",", 2)[0]
	if socket == "" || !filepath.IsAbs(socket) {
		return "", fmt.Errorf("TMUX contains no absolute socket path")
	}
	out, err := exec.Command("tmux", "-S", socket, "display-message", "-p", "-t", pane, "#{session_name}").Output()
	if err != nil {
		return "", fmt.Errorf("tmux could not resolve pane %s", pane)
	}
	name := strings.TrimSpace(string(out))
	if name == "" {
		return "", fmt.Errorf("tmux returned an empty session name")
	}
	return name, nil
}

func cmdWebArtifactList() int {
	recipes, err := fetchWebArtifacts()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 1
	}
	if len(recipes) == 0 {
		fmt.Println("No web artifacts saved.")
		return 0
	}
	for _, recipe := range recipes {
		port := "fixed"
		if recipe.PortMode == webartifact.PortModeAuto {
			port = "auto"
		}
		fmt.Printf("%-12s  %-12s  %-18s  %-28s  %-20s  %s\n", recipe.MachineName, port, shortWebArtifactID(recipe.ID), recipe.Name, recipe.SessionName, recipe.URL)
	}
	return 0
}

func cmdWebArtifactRemove(target string) int {
	id, err := resolveWebArtifactID(target)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 1
	}
	body, code, err := httpDelete(localBase()+"/web-artifacts?id="+url.QueryEscape(id), 10*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", err)
		return 1
	}
	if code < 200 || code >= 300 {
		fmt.Fprintln(os.Stderr, "ut web-artifacts:", responseError(body, code))
		return 1
	}
	fmt.Printf("Removed web artifact %s. No running web service was stopped.\n", id)
	return 0
}

func fetchWebArtifacts() ([]webartifact.Recipe, error) {
	body, code, err := httpGet(localBase()+"/web-artifacts", 10*time.Second)
	if err != nil {
		return nil, err
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("%s", responseError(body, code))
	}
	var response struct {
		Artifacts []webartifact.Recipe `json:"artifacts"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return nil, fmt.Errorf("broker returned invalid web artifacts")
	}
	return response.Artifacts, nil
}

func resolveWebArtifactID(target string) (string, error) {
	recipes, err := fetchWebArtifacts()
	if err != nil {
		return "", err
	}
	var matches []webartifact.Recipe
	for _, recipe := range recipes {
		if recipe.ID == target || strings.HasPrefix(recipe.ID, target) || strings.EqualFold(recipe.Name, target) {
			matches = append(matches, recipe)
		}
	}
	if len(matches) == 0 {
		return "", fmt.Errorf("no web artifact matches %q", target)
	}
	if len(matches) > 1 {
		return "", fmt.Errorf("%q matches multiple web artifacts; use a longer id", target)
	}
	return matches[0].ID, nil
}

func shortWebArtifactID(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}

func httpRequest(method, endpoint string, payload []byte, timeout time.Duration) ([]byte, int, error) {
	req, err := http.NewRequest(method, endpoint, strings.NewReader(string(payload)))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	return body, response.StatusCode, nil
}

func responseError(body []byte, code int) string {
	var response struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(body, &response) == nil && response.Error != "" {
		return response.Error
	}
	return fmt.Sprintf("broker returned HTTP %d: %s", code, strings.TrimSpace(string(body)))
}

const webArtifactsHelp = `ut web-artifacts — save exact web-service launch recipes without running them.

USAGE
  ut web-artifacts add <name> --cwd <absolute-path> --port auto --url <loopback-url-template> --command <command-template>
  ut web-artifacts add <name> --cwd <absolute-path> --url <fixed-loopback-url> --command <command>
  ut web-artifacts add <name> --cwd <absolute-path> --url <loopback-url> --command-file <path|->
  ut web-artifacts update <id|name> <name> --cwd ... --url ... --command ...
  ut web-artifacts list
  ut web-artifacts remove <id|name>

Registration is explicit and never runs the command. The current ut session is
recorded and verified automatically; use --session <name> only when invoking the
command outside that session. --cwd must be absolute. The saved command must
contain every initialization step needed to start the web service.

Use --port auto with {port} in both the URL and command to let the broker choose
an unused loopback port whenever the web artifact is launched. A numeric --port
resolves the same placeholders immediately. Omitting --port preserves the fixed
URL behavior used by existing recipes.

EXAMPLE
  ut web-artifacts add "Gym dashboard" \
    --cwd /home/pranjala/gym-anything \
    --port auto \
    --url 'http://localhost:{port}/dashboard' \
    --command 'source .venv/bin/activate && exec python dashboard.py --port {port}'
`
