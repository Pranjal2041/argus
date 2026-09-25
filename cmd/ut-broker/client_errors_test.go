package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCLIReportsBrokerRejection(t *testing.T) {
	// HTTP failure is distinct from a transport failure. Both a mesh router's
	// plain-text rejection and a provider's JSON rejection must reach the user.
	for _, response := range []struct {
		name, body, want string
		status           int
	}{
		{"mesh", "mesh: no such machine: unknown-host\n", "no such machine: unknown-host", 404},
		{"provider", `{"error":"session name already exists"}`, "session name already exists", 400},
		{"empty", "", "Service Unavailable", 503},
	} {
		t.Run(response.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(response.status)
				_, _ = io.WriteString(w, response.body)
			}))
			defer server.Close()
			u, _ := url.Parse(server.URL)
			t.Setenv("UT_PORT", u.Port())
			oldSelf := selfNames
			selfNames = map[string]bool{}
			t.Cleanup(func() { selfNames = oldSelf })
			localFile := filepath.Join(t.TempDir(), "input.txt")
			if err := os.WriteFile(localFile, []byte("test"), 0o600); err != nil {
				t.Fatal(err)
			}
			for _, command := range []struct {
				name string
				run  func() int
			}{
				{"spawn", func() int { return cmdSpawn([]string{"@unknown-host:job", "echo test"}) }},
				{"sh", func() int { return cmdSh([]string{"@unknown-host", "job"}) }},
				{"send", func() int { return cmdSend([]string{"@unknown-host:job", "test"}) }},
				{"cp-read", func() int { return cmdCp([]string{"unknown-host:/file", localFile}) }},
				{"cp-write", func() int { return cmdCp([]string{localFile, "unknown-host:/file"}) }},
			} {
				t.Run(command.name, func(t *testing.T) {
					code, stderr := captureCLIStderr(t, command.run)
					if code != 1 || !strings.Contains(stderr, response.want) || !strings.Contains(stderr, "HTTP ") || strings.Contains(stderr, "<nil>") {
						t.Fatalf("exit=%d stderr=%q; want the broker's rejection and HTTP status", code, stderr)
					}
				})
			}
		})
	}
}

func TestHTTPHelpersRejectTruncatedResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "100")
		_, _ = io.WriteString(w, "partial")
	}))
	defer server.Close()
	for _, method := range []string{"GET", "POST", "DELETE"} {
		t.Run(method, func(t *testing.T) {
			var err error
			var body []byte
			var code int
			switch method {
			case "GET":
				body, code, err = httpGet(server.URL, 0)
			case "POST":
				body, code, err = httpPost(server.URL, nil, 0)
			case "DELETE":
				body, code, err = httpDelete(server.URL, 0)
			}
			if err == nil || code != 200 || string(body) != "partial" {
				t.Fatalf("truncated HTTP response was silently accepted: body=%q code=%d err=%v", body, code, err)
			}
		})
	}
}

func TestSpawnReportsTransportFailure(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	server.Close()
	u, _ := url.Parse(server.URL)
	t.Setenv("UT_PORT", u.Port())
	oldSelf := selfNames
	selfNames = map[string]bool{"worker": true}
	t.Cleanup(func() { selfNames = oldSelf })
	code, stderr := captureCLIStderr(t, func() int { return cmdSpawn([]string{"@worker:job", "true"}) })
	if code != 1 || !strings.Contains(stderr, "connect") || strings.Contains(stderr, "<nil>") || strings.Contains(stderr, "HTTP ") {
		t.Fatalf("transport failure: exit=%d stderr=%q", code, stderr)
	}
}

func TestSpawnPreservesShellSafeTargetAndCommand(t *testing.T) {
	for _, shell := range []string{"bash", "zsh"} {
		t.Run(shell, func(t *testing.T) {
			bin, err := exec.LookPath(shell)
			if err != nil {
				t.Skipf("%s not installed", shell)
			}
			// Exercise actual shell expansion, not a hand-built approximation of
			// the argument. Braces preserve a colon after a variable in both shells.
			target, err := exec.Command(bin, "-c", `HOST=worker.example; printf '%s' "@${HOST}:job"`).Output()
			if err != nil || string(target) != "@worker.example:job" {
				t.Fatalf("shell target=%q err=%v", target, err)
			}
			type request struct {
				method, path, body string
				query              url.Values
			}
			requests := make(chan request, 2)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				requests <- request{r.Method, r.URL.Path, string(body), r.URL.Query()}
				_, _ = io.WriteString(w, `{"ok":true}`)
			}))
			defer server.Close()
			u, _ := url.Parse(server.URL)
			t.Setenv("UT_PORT", u.Port())
			oldSelf := selfNames
			selfNames = map[string]bool{}
			t.Cleanup(func() { selfNames = oldSelf })
			command := "printf 'payload with spaces\\n' | tee output.log"
			code, stderr := captureCLIStderr(t, func() int { return cmdSpawn([]string{string(target), "--idle", "24h", command}) })
			if code != 0 || stderr != "" {
				t.Fatalf("spawn exit=%d stderr=%q", code, stderr)
			}
			select {
			case req := <-requests:
				if req.method != "POST" || req.path != "/mesh/proxy" || req.query.Get("_mhost") != "worker.example" || req.query.Get("_mpath") != "/control" || req.query.Get("action") != "spawn" || req.query.Get("session") != "job" || req.query.Get("idle") != "86400" || req.body != command {
					t.Fatalf("wrong spawn request: %#v", req)
				}
			case <-time.After(time.Second):
				t.Fatal("no spawn request")
			}
			if len(requests) != 0 {
				t.Fatal("spawn sent more than one request")
			}
		})
	}
}

func captureCLIStderr(t *testing.T, run func() int) (int, string) {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	old := os.Stderr
	os.Stderr = f
	defer func() { os.Stderr = old }()
	code := run()
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	return code, string(b)
}
