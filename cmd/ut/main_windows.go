//go:build windows

// Command ut is the Windows drop-in for tmux: it ensures a broker is running on
// this machine, creates or attaches a session (held by the broker, so it
// survives disconnects), and pumps your PowerShell console <-> the session in
// raw VT mode. Detach with Ctrl-] — the session keeps running.
//
//	ut [name]              new session (default: a fresh one named after the dir)
//	ut -L <socket> [name]  reserved for a separate broker (single broker for now)
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/sys/windows"
)

const port = "8722"

// Windows console mode bits (stable values; defined locally to avoid x/sys drift).
const (
	enableProcessedInput  = 0x0001
	enableLineInput       = 0x0002
	enableEchoInput       = 0x0004
	enableWindowInput     = 0x0008
	enableVTInput         = 0x0200
	enableProcessedOutput = 0x0001
	enableVTProcessing    = 0x0004
	disableNLAutoReturn   = 0x0008
)

// exeDir is the directory of this ut.exe — the broker (ut-broker.exe) lives
// beside it, so `ut` works regardless of cwd or which user runs it.
func exeDir() string {
	p, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(p)
}

func brokerLog(name string) string { return filepath.Join(os.TempDir(), name) }

func main() {
	args := os.Args[1:]
	if len(args) >= 2 && args[0] == "-L" { // socket arg is accepted but single-broker for now
		args = args[2:]
	}
	explicit := ""
	if len(args) >= 1 {
		explicit = args[0]
	}

	base := "http://127.0.0.1:" + port
	if !brokerUp(base) {
		if err := startBroker(); err != nil {
			fatal("start broker: %v", err)
		}
		for i := 0; i < 30 && !brokerUp(base); i++ {
			time.Sleep(300 * time.Millisecond)
		}
		if !brokerUp(base) {
			fatal("broker did not come up; see %s", brokerLog("ut-broker.err.log"))
		}
	}

	cwd, _ := os.Getwd()
	var name string
	if explicit != "" { // named: attach-or-create (reconnect to it later)
		name = sanitize(explicit)
	} else { // no name: a NEW session every time, dir-named with a numeric suffix
		base0 := sanitize(filepath.Base(cwd))
		if base0 == "" {
			base0 = "main"
		}
		name = base0
		existing := sessionNames(base)
		for n := 2; contains(existing, name); n++ {
			name = fmt.Sprintf("%s-%d", base0, n)
		}
	}

	createSession(base, name, cwd) // attach-or-create

	if os.Getenv("UT_NO_ATTACH") != "" {
		fmt.Println("session:", name)
		return
	}
	attach(name)
}

// --- broker / session HTTP helpers -----------------------------------------

func brokerUp(base string) bool {
	cl := http.Client{Timeout: 2 * time.Second}
	resp, err := cl.Get(base + "/whoami")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	var v struct {
		Service string `json:"service"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&v)
	return v.Service == "universal-tmux-broker"
}

func startBroker() error {
	exe := filepath.Join(exeDir(), "ut-broker.exe")
	host, _ := os.Hostname()
	out, _ := os.OpenFile(brokerLog("ut-broker.out.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	errf, _ := os.OpenFile(brokerLog("ut-broker.err.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	cmd := exec.Command(exe, "--listen=0.0.0.0:"+port, "--session=", "--name="+host)
	cmd.Stdout, cmd.Stderr = out, errf
	cmd.SysProcAttr = &syscall.SysProcAttr{
		// Detach so the broker outlives this `ut` process and the shell/SSH session.
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | 0x00000008 /*DETACHED_PROCESS*/ | 0x08000000, /*CREATE_NO_WINDOW*/
	}
	return cmd.Start()
}

func sessionNames(base string) []string {
	cl := http.Client{Timeout: 3 * time.Second}
	resp, err := cl.Get(base + "/sessions")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var v struct {
		Sessions []struct {
			Name string `json:"name"`
		} `json:"sessions"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&v)
	out := make([]string, 0, len(v.Sessions))
	for _, s := range v.Sessions {
		out = append(out, s.Name)
	}
	return out
}

func createSession(base, name, dir string) {
	cl := http.Client{Timeout: 8 * time.Second}
	u := base + "/control?action=create&session=" + url.QueryEscape(name) + "&dir=" + url.QueryEscape(dir)
	resp, err := cl.Post(u, "", nil)
	if err == nil {
		resp.Body.Close()
	}
}

// --- console attach ---------------------------------------------------------

func attach(name string) {
	ctx := context.Background()
	wsURL := "ws://127.0.0.1:" + port + "/ws?session=" + url.QueryEscape(name)
	c, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		fatal("attach %q: %v", name, err)
	}
	c.SetReadLimit(-1)

	stdin := windows.Handle(os.Stdin.Fd())
	stdout := windows.Handle(os.Stdout.Fd())
	var inMode, outMode uint32
	_ = windows.GetConsoleMode(stdin, &inMode)
	_ = windows.GetConsoleMode(stdout, &outMode)

	var once sync.Once
	restore := func() {
		_ = windows.SetConsoleMode(stdin, inMode)
		_ = windows.SetConsoleMode(stdout, outMode)
	}
	exit := func(code int) {
		once.Do(restore)
		_ = c.Close(websocket.StatusNormalClosure, "")
		os.Exit(code)
	}

	_ = windows.SetConsoleMode(stdin, (inMode&^(enableLineInput|enableEchoInput|enableProcessedInput))|enableVTInput|enableWindowInput)
	_ = windows.SetConsoleMode(stdout, outMode|enableProcessedOutput|enableVTProcessing|disableNLAutoReturn)

	fmt.Fprint(os.Stdout, "\x1b[2J\x1b[H") // clear; the snapshot redraws

	// WS output -> console
	go func() {
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				exit(0) // session/broker ended
			}
			if len(data) >= 2 && data[0] == 1 { // opOutput
				paneLen := int(data[1])
				if len(data) >= 2+paneLen {
					os.Stdout.Write(data[2+paneLen:])
				}
			}
		}
	}()

	// console size -> resize
	go func() {
		var lc, lr int
		for {
			cols, rows := consoleSize(stdout)
			if cols > 0 && (cols != lc || rows != lr) {
				lc, lr = cols, rows
				p := []byte{0, 0, 0, 0}
				binary.BigEndian.PutUint16(p[0:2], uint16(cols))
				binary.BigEndian.PutUint16(p[2:4], uint16(rows))
				_ = c.Write(ctx, websocket.MessageBinary, append([]byte{3, 0}, p...))
			}
			time.Sleep(400 * time.Millisecond)
		}
	}()

	// console input -> WS (Ctrl-] detaches, leaving the session running)
	buf := make([]byte, 4096)
	for {
		n, err := os.Stdin.Read(buf)
		if err != nil {
			exit(0)
		}
		if n == 0 {
			continue
		}
		for _, b := range buf[:n] {
			if b == 0x1d { // Ctrl-]
				exit(0)
			}
		}
		if err := c.Write(ctx, websocket.MessageBinary, append([]byte{2, 0}, buf[:n]...)); err != nil {
			exit(0)
		}
	}
}

func consoleSize(h windows.Handle) (int, int) {
	var info windows.ConsoleScreenBufferInfo
	if err := windows.GetConsoleScreenBufferInfo(h, &info); err != nil {
		return 0, 0
	}
	return int(info.Window.Right-info.Window.Left) + 1, int(info.Window.Bottom-info.Window.Top) + 1
}

// --- misc -------------------------------------------------------------------

func sanitize(s string) string { return strings.NewReplacer(":", "_", ".", "_").Replace(s) }

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

func fatal(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "ut: "+f+"\n", a...)
	os.Exit(1)
}
