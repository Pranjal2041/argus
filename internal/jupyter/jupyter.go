// Package jupyter manages a single JupyterLab server per host for the notebook
// feature (Exp 0): the broker launches `jupyter lab` on a loopback port and hands
// the client its {port, token}. The client reaches that port over the existing
// port-forward tunnel and renders the lab in a webview. The kernel stays on THIS
// host — the GPU node, the right conda env — reached with zero SSH, the same value
// the terminal path already delivers.
//
// The server is launched detached and its {port, token, pid} persisted, so it
// survives a broker restart: the next Ensure re-adopts the still-running server
// instead of orphaning it (and its kernels).
package jupyter

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"
)

// Info is what the broker hands the client: the loopback port + token of a running
// JupyterLab on this host.
type Info struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
}

// state is persisted to disk so a JupyterLab survives a broker restart.
type state struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
}

// Manager owns this host's single JupyterLab server.
type Manager struct {
	mu        sync.Mutex
	statePath string
	logPath   string
}

func NewManager() *Manager {
	u := os.Getenv("USER")
	if u == "" {
		u = "ut"
	}
	// /tmp is NODE-LOCAL on a cluster — so each SLURM node tracks its OWN JupyterLab
	// rather than stomping a shared NFS one — and it's stable across a broker restart
	// (re-adopt). Avoid os.TempDir() (per-login-session on macOS) and the NFS home.
	base := "/tmp"
	if fi, err := os.Stat(base); err != nil || !fi.IsDir() {
		base = os.TempDir()
	}
	return &Manager{
		statePath: filepath.Join(base, "ut-jupyter-"+u+".json"),
		logPath:   filepath.Join(base, "ut-jupyter-"+u+".log"),
	}
}

// Ensure returns a live JupyterLab on this host, launching one if needed (or
// re-adopting one that's still running from before).
func (m *Manager) Ensure() (*Info, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if st := m.readState(); st != nil {
		info := &Info{Port: st.Port, Token: st.Token}
		if alive(info) {
			warmKernelspecs(info) // prime the listing so the notebook pane paints immediately
			return info, nil      // adopt the server still running from a previous broker
		}
	}

	bin, err := findJupyter()
	if err != nil {
		return nil, err
	}
	port, err := freePort()
	if err != nil {
		return nil, err
	}
	token := randHex(24)

	args := []string{
		"lab", "--no-browser",
		"--ip=127.0.0.1",
		"--port=" + strconv.Itoa(port),
		"--ServerApp.allow_origin=*",   // happy behind the localhost tunnel
		"--ServerApp.open_browser=False",
		// Cluster GPU nodes have slow or blocked internet. JupyterLab's DEFAULT extension
		// manager ('pypi') and its update/news checks phone home to pypi.org DURING server
		// startup — on a node whose path to pypi.org is slow this hangs 40s+ (measured on
		// babel), and when it pushes total startup past the readiness timeout the launch
		// "fails" even though Jupyter would have come up. We never install extensions from
		// the UI, so disable both: cold start becomes fast and network-INDEPENDENT
		// (measured ~90s -> ~6s on a babel node). Notebooks/kernels are unaffected.
		"--LabApp.extension_manager=readonly",
		"--LabApp.check_for_updates_class=jupyterlab.handlers.announcements.NeverCheckForUpdate",
	}
	// Root at "/" so a notebook in ANY folder the user picks is openable as
	// /notebooks/<abs-path>. The single-document view exposes no file browser, and
	// this matches the access the terminal already has (the broker's full shell).
	args = append(args, "--ServerApp.root_dir=/", "--ServerApp.preferred_dir="+homeOrRoot())
	cmd := exec.Command(bin, args...)
	cmd.Env = append(os.Environ(), "JUPYTER_TOKEN="+token)
	cmd.SysProcAttr = detachAttr() // own process group → survives broker restart
	if f, e := os.Create(m.logPath); e == nil {
		cmd.Stdout, cmd.Stderr = f, f
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("launch jupyter (%s): %w", bin, err)
	}

	info := &Info{Port: port, Token: token}
	// Cold start on a loaded SLURM node = NFS conda import (~20–40s) + extension load;
	// with the network startup calls above disabled it's well under a minute, but keep
	// generous headroom so a heavily-loaded node never spuriously times out (waitReady
	// returns the instant the server answers, so headroom is free).
	if err := waitReady(info, 180*time.Second); err != nil {
		_ = cmd.Process.Kill()
		killProcessGroup(cmd.Process.Pid) // the `jupyter` launcher spawns jupyter-lab; reap the whole group
		_ = cmd.Wait()                     // reap the killed child so a failed launch leaves no <defunct> jupyter-lab
		return nil, fmt.Errorf("jupyter did not become ready (see %s): %w", m.logPath, err)
	}
	m.writeState(&state{Port: port, Token: token, PID: cmd.Process.Pid})
	_ = cmd.Process.Release() // managed via the state file + liveness, not Wait()
	warmKernelspecs(info)     // pay the one-time cold kernel-spec scan here, not in the pane
	return info, nil
}

// warmKernelspecs primes the kernel-spec listing. The FIRST /api/kernelspecs after a
// launch costs a one-time ~5–6s on this cluster (cold NFS metadata for the kernel
// directories — repeat calls are ~50ms). JupyterLab's shell AWAITS that fetch
// (serviceManager.ready) before it attaches, so if the client's notebook page is the
// one to trigger it, the pane sits BLANK the whole time. Doing it here — behind the
// client's "starting JupyterLab…" spinner — moves that wait somewhere honest and lets
// the notebook paint immediately. Best-effort: a generous timeout, result discarded.
func warmKernelspecs(info *Info) {
	c := &http.Client{Timeout: 60 * time.Second}
	req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/api/kernelspecs", info.Port), nil)
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "token "+info.Token)
	if resp, err := c.Do(req); err == nil {
		resp.Body.Close()
	}
}

func (m *Manager) readState() *state {
	b, err := os.ReadFile(m.statePath)
	if err != nil {
		return nil
	}
	var st state
	if json.Unmarshal(b, &st) != nil || st.Port == 0 {
		return nil
	}
	return &st
}

func (m *Manager) writeState(st *state) {
	if b, err := json.Marshal(st); err == nil {
		_ = os.WriteFile(m.statePath, b, 0o600)
	}
}

// alive reports whether a JupyterLab is answering on the port with this token.
func alive(info *Info) bool {
	c := &http.Client{Timeout: 2 * time.Second}
	req, err := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d/api/status", info.Port), nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "token "+info.Token)
	resp, err := c.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func waitReady(info *Info, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if alive(info) {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timeout after %s", timeout)
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func randHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// findJupyter resolves the `jupyter` launcher: PATH first, then common conda/venv
// locations (the broker's own PATH may not have conda activated, e.g. on a SLURM
// node). Override with UT_JUPYTER=/abs/path/to/jupyter.
func findJupyter() (string, error) {
	if p := os.Getenv("UT_JUPYTER"); p != "" && isExec(p) {
		return p, nil
	}
	if p, err := exec.LookPath("jupyter"); err == nil {
		return p, nil
	}
	home, _ := os.UserHomeDir()
	var cands []string
	if cp := os.Getenv("CONDA_PREFIX"); cp != "" {
		cands = append(cands, filepath.Join(cp, "bin", "jupyter"))
	}
	for _, base := range []string{
		filepath.Join(home, "miniconda3"),
		filepath.Join(home, "scratch", "miniconda3"),
		filepath.Join(home, "anaconda3"),
		"/opt/miniconda3", "/opt/anaconda3", "/opt/conda",
	} {
		cands = append(cands, filepath.Join(base, "bin", "jupyter"))
	}
	for _, c := range cands {
		if isExec(c) {
			return c, nil
		}
	}
	return "", fmt.Errorf("jupyter not found on PATH or common conda locations; set UT_JUPYTER=/path/to/jupyter")
}

func isExec(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
}

// homeOrRoot is the directory the file browser / new-file dialogs default to (the
// user's home), falling back to "/". Must stay under root_dir ("/").
func homeOrRoot() string {
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return home
	}
	return "/"
}
