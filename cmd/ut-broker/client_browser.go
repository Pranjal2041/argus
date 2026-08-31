package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type browserStatus struct {
	Available     bool   `json:"available"`
	BrowserHost   string `json:"browser_host"`
	NetworkOrigin string `json:"network_origin"`
	Provider      string `json:"provider"`
	Version       int    `json:"version"`
}

type browserPeer struct {
	Name string `json:"name"`
	Host string `json:"host"`
	Os   string `json:"os"`
}

type browserTarget struct {
	host string
	url  string
}

type browserRPCResponse struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result"`
	Error  string          `json:"error"`
}

type browserDownloadResult struct {
	Filename string `json:"filename"`
	Path     string `json:"path"`
	State    string `json:"state"`
	Error    string `json:"error"`
}

type browserOpenedTabResult struct {
	ID        string                  `json:"id"`
	Title     string                  `json:"title"`
	URL       string                  `json:"url"`
	Downloads []browserDownloadResult `json:"downloads"`
}

// A local-mode Windows broker may need one discovery pass before it can relay
// to the Mac's native HTTP broker. That path is consistently a little over
// eight seconds on the live tailnet, so an eight-second client deadline races
// a healthy provider. Keep the probe bounded while leaving enough headroom for
// the broker's own peer-resolution pass.
const browserProviderProbeTimeout = 15 * time.Second

// Browser uploads travel as base64 inside the versioned JSON RPC. Keep the
// aggregate raw payload bounded so an accidental model-selected directory or
// huge checkpoint cannot balloon the broker or Argus process.
const browserUploadMaxBytes int64 = 32 << 20

func cmdBrowser(args []string) int {
	if len(args) == 0 || args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
		fmt.Print(browserHelpText)
		return 0
	}

	var method, screenshotPath string
	var params map[string]any
	var err error
	if args[0] == "status" {
		if len(args) != 1 {
			fmt.Fprintln(os.Stderr, "ut browser: usage: ut browser status")
			return 2
		}
	} else {
		method, params, screenshotPath, err = parseBrowserCommand(args)
		if err != nil {
			fmt.Fprintln(os.Stderr, "ut browser:", err)
			return 2
		}
	}

	providerHost, status, err := findBrowserProvider()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut browser:", err)
		return 1
	}
	if args[0] == "status" {
		fmt.Printf("provider:       %s (browser.v%d)\n", status.Provider, status.Version)
		fmt.Printf("browser host:   %s\n", status.BrowserHost)
		fmt.Printf("network origin: %s\n", status.NetworkOrigin)
		fmt.Println("The requesting agent's machine does not change the browser's network origin.")
		return 0
	}

	if method == "credentials.request" {
		fmt.Fprintln(os.Stderr, "Waiting for Argus credential approval…")
	}
	response, err := callBrowser(providerHost, method, params, browserTimeout(method))
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut browser:", err)
		return 1
	}
	if screenshotPath != "" || method == "page.screenshot" || method == "app.screenshot" {
		return writeBrowserScreenshot(response, screenshotPath, false)
	}
	if method == "page.click" || method == "page.type" || method == "page.scroll" || method == "page.upload" {
		return writeBrowserScreenshot(response, "", true)
	}
	printBrowserResult(response.Result)
	return 0
}

func findBrowserProvider() (string, browserStatus, error) {
	if explicit := strings.TrimSpace(os.Getenv("UT_BROWSER_PROVIDER")); explicit != "" {
		status, err := fetchBrowserStatus(explicit)
		if err != nil || !status.Available {
			return "", browserStatus{}, fmt.Errorf("provider %q is not running Argus", explicit)
		}
		return explicit, status, nil
	}

	if status, err := fetchBrowserStatus(""); err == nil && status.Available {
		return "", status, nil
	}

	body, _, err := httpGet(localBase()+"/mesh/peers", 20*time.Second)
	if err != nil {
		return "", browserStatus{}, fmt.Errorf("cannot discover the Argus browser provider: %w", err)
	}
	var response struct {
		Peers []browserPeer `json:"peers"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return "", browserStatus{}, fmt.Errorf("cannot decode broker peers")
	}
	// Prefer macOS peers, but retain a deterministic fallback for a future Argus
	// provider on another platform.
	sort.SliceStable(response.Peers, func(i, j int) bool {
		leftMac, rightMac := response.Peers[i].Os == "darwin", response.Peers[j].Os == "darwin"
		if leftMac != rightMac {
			return leftMac
		}
		return response.Peers[i].Name < response.Peers[j].Name
	})
	macTargets := make([]browserTarget, 0, len(response.Peers))
	otherTargets := make([]browserTarget, 0, len(response.Peers))
	for _, peer := range response.Peers {
		host := peer.Name
		if host == "" {
			host = peer.Host
		}
		candidate := browserTarget{host: host, url: peerURL(host, "/browser/status", nil)}
		if peer.Os == "darwin" {
			macTargets = append(macTargets, candidate)
		} else {
			otherTargets = append(otherTargets, candidate)
		}
	}
	if host, status, ok := probeBrowserTargets(macTargets); ok {
		return host, status, nil
	}
	if host, status, ok := probeBrowserTargets(otherTargets); ok {
		return host, status, nil
	}
	return "", browserStatus{}, fmt.Errorf("no running Argus browser provider found; open Argus on the Mac")
}

// Probe one preference tier in parallel and return as soon as a provider
// answers. A stale or half-offline peer therefore cannot delay a healthy Mac,
// and a whole fleet costs one bounded timeout rather than N sequential ones.
func probeBrowserTargets(targets []browserTarget) (string, browserStatus, bool) {
	type probeResult struct {
		host   string
		status browserStatus
		ok     bool
	}
	results := make(chan probeResult, len(targets))
	for _, candidate := range targets {
		go func() {
			status, err := fetchBrowserStatusURL(candidate.url)
			results <- probeResult{host: candidate.host, status: status, ok: err == nil && status.Available}
		}()
	}
	for range targets {
		result := <-results
		if result.ok {
			return result.host, result.status, true
		}
	}
	return "", browserStatus{}, false
}

func fetchBrowserStatus(host string) (browserStatus, error) {
	return fetchBrowserStatusURL(peerURL(host, "/browser/status", nil))
}

func fetchBrowserStatusURL(url string) (browserStatus, error) {
	body, code, err := httpGet(url, browserProviderProbeTimeout)
	if err != nil {
		return browserStatus{}, err
	}
	if code != 200 {
		return browserStatus{}, fmt.Errorf("browser status returned HTTP %d", code)
	}
	var status browserStatus
	if err := json.Unmarshal(body, &status); err != nil {
		return browserStatus{}, err
	}
	return status, nil
}

func callBrowser(host, method string, params map[string]any, timeout time.Duration) (browserRPCResponse, error) {
	request := map[string]any{
		"version": 1,
		"id":      fmt.Sprintf("cli-%d", time.Now().UnixNano()),
		"method":  method,
		"params":  params,
	}
	if method == "credentials.request" || method == "credentials.fill" || method == "api_keys.request" {
		caller, ok := currentBrowserCaller()
		if !ok {
			return browserRPCResponse{}, fmt.Errorf("credential access must be requested from inside a verified ut panel")
		}
		request["caller"] = caller
	}
	payload, _ := json.Marshal(request)
	body, code, err := httpPost(peerURL(host, "/browser/rpc", nil), payload, timeout)
	if err != nil {
		return browserRPCResponse{}, err
	}
	var response browserRPCResponse
	if err := json.Unmarshal(body, &response); err != nil {
		return response, fmt.Errorf("invalid response from Argus (HTTP %d)", code)
	}
	if code != 200 || !response.OK {
		if response.Error == "" {
			response.Error = brokerResponseError(body, code)
		}
		return response, fmt.Errorf("%s", response.Error)
	}
	return response, nil
}

func browserTimeout(method string) time.Duration {
	switch method {
	case "credentials.request", "api_keys.request":
		return 15 * time.Minute
	case "page.screenshot", "page.upload":
		return 90 * time.Second
	case "tabs.open", "tabs.navigate":
		return 60 * time.Second
	default:
		return 30 * time.Second
	}
}

func parseBrowserCommand(args []string) (method string, params map[string]any, screenshotPath string, err error) {
	params = map[string]any{}
	command := args[0]
	rest := args[1:]
	switch command {
	case "tabs", "ls":
		if len(rest) != 0 {
			return "", nil, "", fmt.Errorf("usage: ut browser tabs")
		}
		return "tabs.list", params, "", nil
	case "downloads":
		if len(rest) != 1 {
			return "", nil, "", fmt.Errorf("usage: ut browser downloads <tab-id>")
		}
		params["tab_id"] = rest[0]
		return "downloads.list", params, "", nil
	case "open":
		if len(rest) == 0 {
			return "", nil, "", fmt.Errorf("usage: ut browser open <url> [--visible] [--width N] [--height N]")
		}
		params["url"] = rest[0]
		params["visible"] = false
		if err := parseBrowserOpenFlags(rest[1:], params); err != nil {
			return "", nil, "", err
		}
		return "tabs.open", params, "", nil
	case "show", "close", "back", "forward", "reload":
		if len(rest) != 1 {
			return "", nil, "", fmt.Errorf("usage: ut browser %s <tab-id>", command)
		}
		params["tab_id"] = rest[0]
		return "tabs." + command, params, "", nil
	case "navigate":
		if len(rest) != 2 {
			return "", nil, "", fmt.Errorf("usage: ut browser navigate <tab-id> <url>")
		}
		params["tab_id"], params["url"] = rest[0], rest[1]
		return "tabs.navigate", params, "", nil
	case "snapshot":
		if len(rest) != 1 {
			return "", nil, "", fmt.Errorf("usage: ut browser snapshot <tab-id>")
		}
		params["tab_id"] = rest[0]
		return "page.snapshot", params, "", nil
	case "screenshot":
		if len(rest) == 0 {
			return "", nil, "", fmt.Errorf("usage: ut browser screenshot <tab-id> [--full-page] [-o path] | --argus [-o path]")
		}
		if rest[0] == "--argus" {
			path, err := parseScreenshotFlags(rest[1:], params)
			if err != nil {
				return "", nil, "", err
			}
			if params["full_page"] == true {
				return "", nil, "", fmt.Errorf("--full-page applies only to browser tabs")
			}
			return "app.screenshot", params, path, nil
		}
		params["tab_id"] = rest[0]
		params["full_page"] = false
		path, err := parseScreenshotFlags(rest[1:], params)
		if err != nil {
			return "", nil, "", err
		}
		return "page.screenshot", params, path, nil
	case "click":
		if len(rest) < 2 {
			return "", nil, "", fmt.Errorf("usage: ut browser click <tab-id> <x> <y> | --ref <element-ref>")
		}
		params["tab_id"] = rest[0]
		if rest[1] == "--ref" {
			if len(rest) != 3 {
				return "", nil, "", fmt.Errorf("--ref needs exactly one element reference")
			}
			params["ref"] = rest[2]
		} else {
			if len(rest) != 3 {
				return "", nil, "", fmt.Errorf("coordinate click needs x and y")
			}
			x, xerr := strconv.ParseFloat(rest[1], 64)
			y, yerr := strconv.ParseFloat(rest[2], 64)
			if xerr != nil || yerr != nil || x < 0 || y < 0 {
				return "", nil, "", fmt.Errorf("click coordinates must be non-negative numbers")
			}
			params["x"], params["y"] = x, y
		}
		return "page.click", params, "", nil
	case "type":
		if len(rest) < 2 {
			return "", nil, "", fmt.Errorf("usage: ut browser type <tab-id> [--ref ref | --at x y] <text...>")
		}
		params["tab_id"] = rest[0]
		textStart := 1
		switch rest[1] {
		case "--ref":
			if len(rest) < 4 {
				return "", nil, "", fmt.Errorf("--ref needs an element reference and text")
			}
			params["ref"] = rest[2]
			textStart = 3
		case "--at":
			if len(rest) < 5 {
				return "", nil, "", fmt.Errorf("--at needs x, y, and text")
			}
			x, xerr := strconv.ParseFloat(rest[2], 64)
			y, yerr := strconv.ParseFloat(rest[3], 64)
			if xerr != nil || yerr != nil || x < 0 || y < 0 {
				return "", nil, "", fmt.Errorf("type coordinates must be non-negative numbers")
			}
			params["x"], params["y"] = x, y
			textStart = 4
		default:
		}
		params["text"] = strings.Join(rest[textStart:], " ")
		return "page.type", params, "", nil
	case "upload":
		if len(rest) < 2 {
			return "", nil, "", fmt.Errorf("usage: ut browser upload <tab-id> [--ref ref | --at x y] <path...>")
		}
		params["tab_id"] = rest[0]
		fileStart := 1
		switch rest[1] {
		case "--ref":
			if len(rest) < 4 || strings.TrimSpace(rest[2]) == "" {
				return "", nil, "", fmt.Errorf("--ref needs an element reference and at least one path")
			}
			params["ref"] = rest[2]
			fileStart = 3
		case "--at":
			if len(rest) < 5 {
				return "", nil, "", fmt.Errorf("--at needs x, y, and at least one path")
			}
			x, xerr := strconv.ParseFloat(rest[2], 64)
			y, yerr := strconv.ParseFloat(rest[3], 64)
			if xerr != nil || yerr != nil || x < 0 || y < 0 {
				return "", nil, "", fmt.Errorf("upload coordinates must be non-negative numbers")
			}
			params["x"], params["y"] = x, y
			fileStart = 4
		}
		files, loadErr := loadBrowserUploadFiles(rest[fileStart:])
		if loadErr != nil {
			return "", nil, "", loadErr
		}
		params["files"] = files
		return "page.upload", params, "", nil
	case "scroll":
		if len(rest) != 3 {
			return "", nil, "", fmt.Errorf("usage: ut browser scroll <tab-id> <dx> <dy>")
		}
		dx, xerr := strconv.ParseFloat(rest[1], 64)
		dy, yerr := strconv.ParseFloat(rest[2], 64)
		if xerr != nil || yerr != nil {
			return "", nil, "", fmt.Errorf("scroll deltas must be numbers")
		}
		params["tab_id"], params["dx"], params["dy"] = rest[0], dx, dy
		return "page.scroll", params, "", nil
	case "credentials", "credential", "vault":
		return parseBrowserCredentialCommand(rest)
	default:
		return "", nil, "", fmt.Errorf("unknown browser command %q (try `ut browser help`)", command)
	}
}

func loadBrowserUploadFiles(paths []string) ([]map[string]any, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("provide at least one file path")
	}
	files := make([]map[string]any, 0, len(paths))
	var total int64
	for _, path := range paths {
		info, err := os.Stat(path)
		if err != nil {
			return nil, fmt.Errorf("cannot read %q: %w", path, err)
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("%q is not a regular file", path)
		}
		if info.Size() > browserUploadMaxBytes-total {
			return nil, fmt.Errorf("upload exceeds the %d MiB total limit", browserUploadMaxBytes>>20)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("cannot read %q: %w", path, err)
		}
		total += int64(len(data))
		mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
		files = append(files, map[string]any{
			"name":             filepath.Base(path),
			"mime_type":        mimeType,
			"data_base64":      base64.StdEncoding.EncodeToString(data),
			"last_modified_ms": info.ModTime().UnixMilli(),
		})
	}
	return files, nil
}

func parseBrowserCredentialCommand(args []string) (method string, params map[string]any, screenshotPath string, err error) {
	params = map[string]any{}
	if len(args) == 0 {
		return "", nil, "", fmt.Errorf("usage: ut browser credentials list|request|fill")
	}
	switch args[0] {
	case "list", "ls":
		if len(args) != 1 {
			return "", nil, "", fmt.Errorf("usage: ut browser credentials list")
		}
		return "credentials.list", params, "", nil
	case "request":
		if len(args) != 2 && len(args) != 4 {
			return "", nil, "", fmt.Errorf("usage: ut browser credentials request <credential> [--tab <tab-id>]")
		}
		params["credential"] = args[1]
		if len(args) == 4 {
			if args[2] != "--tab" || strings.TrimSpace(args[3]) == "" {
				return "", nil, "", fmt.Errorf("request accepts only --tab <tab-id>")
			}
			params["tab_id"] = args[3]
		}
		return "credentials.request", params, "", nil
	case "fill":
		if len(args) < 6 {
			return "", nil, "", fmt.Errorf("usage: ut browser credentials fill <tab-id> <credential> --grant <grant> [--username-ref ref|--username-at x y] [--password-ref ref|--password-at x y]")
		}
		params["tab_id"], params["credential"] = args[1], args[2]
		targets := map[string]any{}
		for i := 3; i < len(args); i++ {
			switch args[i] {
			case "--grant":
				if i+1 >= len(args) {
					return "", nil, "", fmt.Errorf("--grant requires a value")
				}
				params["grant"] = args[i+1]
				i++
			case "--username-ref", "--password-ref":
				if i+1 >= len(args) {
					return "", nil, "", fmt.Errorf("%s requires a value", args[i])
				}
				field := strings.TrimSuffix(strings.TrimPrefix(args[i], "--"), "-ref")
				targets[field] = map[string]any{"ref": args[i+1]}
				i++
			case "--username-at", "--password-at":
				if i+2 >= len(args) {
					return "", nil, "", fmt.Errorf("%s requires x and y", args[i])
				}
				x, xerr := strconv.ParseFloat(args[i+1], 64)
				y, yerr := strconv.ParseFloat(args[i+2], 64)
				if xerr != nil || yerr != nil || x < 0 || y < 0 {
					return "", nil, "", fmt.Errorf("%s coordinates must be non-negative numbers", args[i])
				}
				field := strings.TrimSuffix(strings.TrimPrefix(args[i], "--"), "-at")
				targets[field] = map[string]any{"x": x, "y": y}
				i += 2
			default:
				return "", nil, "", fmt.Errorf("unknown credential fill option %q", args[i])
			}
		}
		grant, _ := params["grant"].(string)
		if strings.TrimSpace(grant) == "" {
			return "", nil, "", fmt.Errorf("--grant is required")
		}
		if len(targets) == 0 {
			return "", nil, "", fmt.Errorf("provide at least one username or password target")
		}
		params["targets"] = targets
		return "credentials.fill", params, "", nil
	default:
		return "", nil, "", fmt.Errorf("unknown credentials command %q", args[0])
	}
}

func currentBrowserCaller() (map[string]any, bool) {
	session, err := resolveCurrentWebArtifactSession("")
	if err != nil {
		return nil, false
	}
	body, code, err := httpGet(localBase()+"/whoami", 4*time.Second)
	if err != nil || code != 200 {
		return nil, false
	}
	var who struct {
		Name string `json:"name"`
		Host string `json:"host"`
	}
	if json.Unmarshal(body, &who) != nil || (who.Name == "" && who.Host == "") {
		return nil, false
	}
	workingDirectory, err := os.Getwd()
	if err != nil || !filepath.IsAbs(workingDirectory) {
		return nil, false
	}
	return map[string]any{
		"machine_name":       who.Name,
		"machine_host":       who.Host,
		"session_name":       session.Name,
		"stable_session_id":  session.ID,
		"session_lineage_id": session.LineageID,
		"working_directory":  workingDirectory,
		"dotenv_path":        filepath.Join(workingDirectory, ".env"),
	}, true
}

func parseBrowserOpenFlags(args []string, params map[string]any) error {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--visible":
			params["visible"] = true
		case "--width", "--height":
			if i+1 >= len(args) {
				return fmt.Errorf("%s needs a value", args[i])
			}
			value, err := strconv.Atoi(args[i+1])
			if err != nil || value < 320 || value > 7680 {
				return fmt.Errorf("%s must be between 320 and 7680", args[i])
			}
			params[strings.TrimPrefix(args[i], "--")] = value
			i++
		default:
			return fmt.Errorf("unknown open option %q", args[i])
		}
	}
	return nil
}

func parseScreenshotFlags(args []string, params map[string]any) (string, error) {
	output := ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--full-page":
			params["full_page"] = true
		case "-o", "--output":
			if i+1 >= len(args) {
				return "", fmt.Errorf("%s needs a path", args[i])
			}
			output = args[i+1]
			i++
		default:
			return "", fmt.Errorf("unknown screenshot option %q", args[i])
		}
	}
	return output, nil
}

func printBrowserResult(raw json.RawMessage) {
	if len(raw) == 0 {
		fmt.Println("ok")
		return
	}
	var value any
	if json.Unmarshal(raw, &value) != nil {
		fmt.Println(string(raw))
		return
	}
	pretty, _ := json.MarshalIndent(value, "", "  ")
	fmt.Println(string(pretty))
}

func writeBrowserScreenshot(response browserRPCResponse, requestedPath string, observation bool) int {
	var result struct {
		ImageBase64     string                   `json:"image_base64"`
		MimeType        string                   `json:"mime_type"`
		TabID           string                   `json:"tab_id"`
		Scope           string                   `json:"scope"`
		Width           float64                  `json:"width"`
		Height          float64                  `json:"height"`
		Generation      int                      `json:"generation"`
		InteractionMode string                   `json:"interaction_mode"`
		Uploaded        []string                 `json:"uploaded"`
		Downloads       []browserDownloadResult  `json:"downloads"`
		OpenedTabs      []browserOpenedTabResult `json:"opened_tabs"`
	}
	if err := json.Unmarshal(response.Result, &result); err != nil || result.ImageBase64 == "" {
		fmt.Fprintln(os.Stderr, "ut browser screenshot: Argus returned no image")
		return 1
	}
	image, err := base64.StdEncoding.DecodeString(result.ImageBase64)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut browser screenshot: invalid image payload")
		return 1
	}
	path := requestedPath
	if path == "" {
		if result.Scope == "argus-window" {
			path = fmt.Sprintf("argus-window-%s.png", time.Now().Format("20060102-150405.000"))
		}
	}
	if path == "" {
		short := result.TabID
		if len(short) > 8 {
			short = short[:8]
		}
		name := fmt.Sprintf("argus-browser-%s-%s.png", short, time.Now().Format("20060102-150405.000"))
		if observation {
			directory := filepath.Join(os.TempDir(), "ut-browser-observations")
			if err := os.MkdirAll(directory, 0o755); err != nil {
				fmt.Fprintln(os.Stderr, "ut browser observation:", err)
				return 1
			}
			name = fmt.Sprintf("argus-browser-%s-%06d.png", short, result.Generation)
			path = filepath.Join(directory, name)
		} else {
			path = name
		}
	}
	path, _ = filepath.Abs(path)
	if err := os.WriteFile(path, image, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "ut browser screenshot:", err)
		return 1
	}
	fmt.Printf("%s\n", path)
	if len(result.Uploaded) > 0 {
		fmt.Printf("uploaded %s\n", strings.Join(result.Uploaded, ", "))
	}
	for _, opened := range result.OpenedTabs {
		fmt.Printf("opened tab %s · %s\n", opened.ID, opened.URL)
		for _, download := range opened.Downloads {
			printBrowserDownload(download)
		}
	}
	for _, download := range result.Downloads {
		printBrowserDownload(download)
	}
	if result.Scope == "argus-window" {
		fmt.Printf("Argus window · %.0fx%.0f\n", result.Width, result.Height)
		return 0
	}
	fmt.Printf("tab %s · %.0fx%.0f · observation %d", result.TabID, result.Width, result.Height, result.Generation)
	if result.InteractionMode != "" {
		fmt.Printf(" · %s", result.InteractionMode)
	}
	fmt.Println()
	return 0
}

func printBrowserDownload(download browserDownloadResult) {
	if download.State == "failed" {
		fmt.Printf("download failed %s · %s\n", download.Filename, download.Error)
		return
	}
	fmt.Printf("%s %s → %s\n", download.State, download.Filename, download.Path)
}

const browserHelpText = `ut browser — control the browser hosted by Argus on your Mac.

The requesting agent may run on any machine. Rendering, cookies, JavaScript, and
ordinary Internet traffic remain on the Mac that is running Argus.

USAGE
  ut browser status
  ut browser tabs
  ut browser downloads <tab-id>
  ut browser open <url> [--visible] [--width N] [--height N]
  ut browser show <tab-id>
  ut browser close <tab-id>
  ut browser navigate <tab-id> <url>
  ut browser back|forward|reload <tab-id>
  ut browser snapshot <tab-id>
  ut browser screenshot <tab-id> [--full-page] [-o path]
  ut browser screenshot --argus [-o path]
  ut browser click <tab-id> <x> <y>
  ut browser click <tab-id> --ref <element-ref>
  ut browser type <tab-id> [--ref ref | --at x y] <text...>
  ut browser upload <tab-id> [--ref ref | --at x y] <path...>
  ut browser scroll <tab-id> <dx> <dy>
  ut browser credentials list
  ut browser credentials request <credential> [--tab <tab-id>]
  ut browser credentials fill <tab-id> <credential> --grant <grant> \
      [--username-ref ref|--username-at x y] [--password-ref ref|--password-at x y]

New tabs are hidden unless --visible is given. ` + "`show`" + ` adds the exact live
tab to Argus without reloading or activating Argus. Upload reads files on the
calling machine, then attaches them to the page's file input without opening a
native picker; omit a target only when the page has one file input. Coordinates
use screenshot pixels from the top-left of the current viewport. Set
UT_BROWSER_PROVIDER when more than one Argus browser provider is available.

Clicks, typing, scrolling, and uploads are injected into the addressed WebKit tab.
They do not activate Argus, move macOS focus, open native pickers, or send input
to another application. Page-requested downloads keep the current WebKit session
and are written to the Argus Mac's Downloads folder; interaction output reports
new paths, and ` + "`downloads <tab-id>`" + ` reports their current state.

Credential grants are opaque permissions, not passwords. The request command waits for an
Argus approval (or resolves immediately under a saved/unattended policy). The fill command
injects selected fields inside WebKit and returns only the field names it filled.
`
