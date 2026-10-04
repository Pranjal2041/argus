// Package toolcommand resolves the broker's host tools without letting a
// stalled PATH entry block the caller indefinitely. User commands still run
// with their original environment; only the broker's tool lookup is bounded.
package toolcommand

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const (
	lookupTimeout = 2 * time.Second
	probeTimeout  = 100 * time.Millisecond
	maxProbes     = 16
)

type probe struct {
	done   chan struct{}
	path   string
	err    error
	warned bool // protected by resolver.mu
}

type resolver struct {
	mu       sync.Mutex
	resolved map[string]string
	pending  map[string]*probe
	slots    chan struct{}
	check    func(string) (string, error)
	warn     func(string, ...any)
	wait     time.Duration
}

func newResolver() *resolver {
	return &resolver{
		resolved: make(map[string]string), pending: make(map[string]*probe),
		slots: make(chan struct{}, maxProbes), check: exec.LookPath,
		warn: log.Printf, wait: probeTimeout,
	}
}

var host = newResolver()

// LookPath preserves healthy PATH precedence and pins a successful absolute
// executable for that search configuration. A stalled candidate is skipped
// with a diagnostic. Explicit paths never fall back to another executable.
// Relative PATH entries are excluded: service tools must not come from cwd.
// Conventional system locations are fallbacks for GUI/service environments
// whose PATH omits installed tools (for example Homebrew on macOS).
func LookPath(name string) (string, error) {
	return host.lookPath(context.Background(), name)
}

func (r *resolver) lookPath(parent context.Context, name string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, lookupTimeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if name == "" {
		return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
	}
	path := os.Getenv("PATH")
	key := name + "\x00" + path + "\x00" + os.Getenv("PATHEXT")
	explicit := strings.ContainsAny(name, `/\`)
	r.mu.Lock()
	cached := r.resolved[key]
	r.mu.Unlock()
	if cached != "" {
		return cached, nil
	}
	var candidates []string
	if explicit {
		// Resolve explicit relative paths inside the bounded probe too: Getwd
		// and filesystem canonicalization do not belong on the caller's path.
		candidates = []string{name}
	} else {
		directories := filepath.SplitList(path)
		if runtime.GOOS != "windows" {
			directories = append(directories, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")
		}
		seen := make(map[string]bool)
		for _, directory := range directories {
			if !filepath.IsAbs(directory) || seen[directory] {
				continue
			}
			seen[directory] = true
			candidates = append(candidates, filepath.Join(directory, name))
		}
	}
	var stalled error
	for _, candidate := range candidates {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		resolved, err := r.probe(ctx, candidate)
		if err != nil {
			if ctx.Err() != nil {
				return "", ctx.Err()
			}
			if errors.Is(err, context.DeadlineExceeded) {
				stalled = err
			}
			continue
		}
		// Explicit paths are also used by recovery preflight: revalidate them
		// so a removed executable cannot continue to appear available.
		if !explicit {
			r.mu.Lock()
			r.resolved[key] = resolved
			r.mu.Unlock()
		}
		return resolved, nil
	}
	if stalled != nil {
		return "", fmt.Errorf("resolve %q: %w", name, stalled)
	}
	return "", &exec.Error{Name: name, Err: exec.ErrNotFound}
}

func (r *resolver) probe(ctx context.Context, candidate string) (string, error) {
	r.mu.Lock()
	p := r.pending[candidate]
	if p == nil {
		// A kernel filesystem syscall cannot always be cancelled. Coalesce
		// callers and cap outstanding probes so a dead mount cannot leak an
		// unbounded number of goroutines/OS threads on subsequent refreshes.
		select {
		case r.slots <- struct{}{}:
		default:
			r.mu.Unlock()
			return "", fmt.Errorf("executable probes are occupied: %w", context.DeadlineExceeded)
		}
		p = &probe{done: make(chan struct{})}
		r.pending[candidate] = p
		go func() {
			p.path, p.err = r.check(candidate)
			if p.err == nil {
				p.path, p.err = filepath.Abs(p.path)
			}
			r.mu.Lock()
			delete(r.pending, candidate)
			<-r.slots
			close(p.done)
			r.mu.Unlock()
		}()
	}
	r.mu.Unlock()
	timer := time.NewTimer(r.wait)
	defer timer.Stop()
	select {
	case <-p.done:
		return p.path, p.err
	case <-ctx.Done():
		return "", ctx.Err()
	case <-timer.C:
		r.mu.Lock()
		warn := !p.warned
		p.warned = true
		r.mu.Unlock()
		if warn {
			r.warn("executable lookup: skipping unresponsive candidate %q", candidate)
		}
		return "", context.DeadlineExceeded
	}
}

// CommandContext includes executable lookup in the caller's deadline. In
// os/exec.CommandContext the implicit LookPath happens before Run/Start and is
// not cancelled by the context. Always pass os/exec a resolved absolute path.
func CommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	return host.commandContext(ctx, name, args...)
}

func (r *resolver) commandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	path, err := r.lookPath(ctx, name)
	if err != nil {
		return &exec.Cmd{Path: name, Args: append([]string{name}, args...), Err: err}
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Args[0] = name
	return cmd
}

func Command(name string, args ...string) *exec.Cmd {
	return CommandContext(context.Background(), name, args...)
}
