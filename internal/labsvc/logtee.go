package labsvc

import (
	"fmt"
	"os"
	"regexp"
	"sync"
)

// CappedLogWriter tees a job's output to a file, keeping the head and the
// tail when the total exceeds the cap so a runaway log cannot fill the disk
// (LAB-DESIGN.md: 50 MB default, beginning and end kept on truncation). It
// also keeps a small in-memory preview of the most recent output for the
// run-end event.
type CappedLogWriter struct {
	mu        sync.Mutex
	f         *os.File
	headMax   int64
	written   int64
	tail      []byte
	tailMax   int
	preview   []byte
	truncated int64
}

const previewBytes = 4096

func NewCappedLogWriter(path string, capBytes int64) (*CappedLogWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &CappedLogWriter{f: f, headMax: capBytes / 2, tailMax: int(capBytes / 2)}, nil
}

func (w *CappedLogWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n := len(p)
	w.preview = append(w.preview, p...)
	if len(w.preview) > previewBytes {
		w.preview = w.preview[len(w.preview)-previewBytes:]
	}
	if w.written < w.headMax {
		room := w.headMax - w.written
		if int64(n) <= room {
			w.f.Write(p)
			w.written += int64(n)
			return n, nil
		}
		w.f.Write(p[:room])
		w.written += room
		p = p[room:]
	}
	w.truncated += int64(len(p))
	w.tail = append(w.tail, p...)
	if len(w.tail) > w.tailMax {
		w.tail = w.tail[len(w.tail)-w.tailMax:]
	}
	return n, nil
}

// Close flushes the kept tail (with a marker naming how many bytes were
// dropped) and closes the file.
func (w *CappedLogWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.tail) > 0 {
		if dropped := w.truncated - int64(len(w.tail)); dropped > 0 {
			fmt.Fprintf(w.f, "\n... lab: %d bytes truncated here ...\n", dropped)
		}
		w.f.Write(w.tail)
	}
	return w.f.Close()
}

// Preview returns the most recent output seen, for the run-end event.
func (w *CappedLogWriter) Preview() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return string(w.preview)
}

// ansiRe strips ANSI escape sequences before URL matching, because progress
// bars weave color codes through URLs.
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

// wandbRunRe matches a W&B run URL. The id charset and minimum length mirror
// the validation the macOS client applies (Wandb.swift): the id is cut at the
// first character outside [A-Za-z0-9_-] and must be at least 8 long.
var wandbRunRe = regexp.MustCompile(`wandb\.ai/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.~-]+)/runs/([A-Za-z0-9_-]{8,})`)

// WandbScanner watches an output stream for W&B run URLs. It keeps a small
// overlap buffer so a URL split across two writes still matches.
type WandbScanner struct {
	mu   sync.Mutex
	buf  []byte
	seen map[string]bool
	runs []string
}

func (w *WandbScanner) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.buf = append(w.buf, p...)
	clean := ansiRe.ReplaceAll(w.buf, nil)
	for _, m := range wandbRunRe.FindAllSubmatch(clean, -1) {
		id := string(m[1]) + "/" + string(m[2]) + "/runs/" + string(m[3])
		if w.seen == nil {
			w.seen = map[string]bool{}
		}
		if !w.seen[id] {
			w.seen[id] = true
			w.runs = append(w.runs, id)
		}
	}
	if len(w.buf) > 8192 {
		w.buf = w.buf[len(w.buf)-8192:]
	}
	return len(p), nil
}

// Runs returns the unique runs seen so far, in first-seen order.
func (w *WandbScanner) Runs() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]string(nil), w.runs...)
}
