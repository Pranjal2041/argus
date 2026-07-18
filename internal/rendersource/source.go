// Package rendersource recovers the authoritative rich-text output behind a
// terminal-rendered agent response. Terminal TUIs consume Markdown before they
// paint: escapes, table delimiters, and even TeX operator lines can disappear
// from capture-pane. The transcript is therefore the source of truth, but only
// when its visible text can be matched back to the requested terminal screen.
package rendersource

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
)

const (
	maxCandidateFiles  = 48
	maxMessagesPerFile = 8
	maxTranscriptTail  = 8 << 20
	maxSourceBytes     = 2 << 20
	candidateMaxAge    = 30 * 24 * time.Hour
	minimumConfidence  = 0.58
)

var ErrNoMatch = errors.New("no authoritative agent source matches this terminal")

// Result is safe to hand to a Markdown renderer: Source came from an agent's
// structured transcript, while Confidence records the combined screen-overlap
// and on-screen-position score.
type Result struct {
	Source     string  `json:"source"`
	Format     string  `json:"format"`
	Origin     string  `json:"origin"`
	Confidence float64 `json:"confidence"`
}

type candidateFile struct {
	path     string
	provider string
	mtime    time.Time
}

type message struct {
	text     string
	cwd      string
	provider string
}

// Resolve searches the standard Codex and Claude transcript stores on this
// host. It never trusts recency alone: a candidate must strongly overlap the
// captured screen, preventing two agents in the same folder from crossing.
func Resolve(home, cwd, screen string) (Result, error) {
	screenTokens := tokenize(screen)
	if len(screenTokens) < 8 {
		return Result{}, ErrNoMatch
	}

	best := Result{}
	// Try Codex first. A strong screen match already identifies the authored
	// response; walking a second provider's potentially very large history adds
	// latency without increasing confidence. A miss then searches Claude.
	best = bestFromFiles(
		discover(filepath.Join(home, ".codex", "sessions"), "codex", cwd),
		cwd, screenTokens, best,
	)
	if best.Confidence < minimumConfidence {
		best = bestFromFiles(
			discover(filepath.Join(home, ".claude", "projects"), "claude", cwd),
			cwd, screenTokens, best,
		)
	}

	// Three-word shingles and a conservative combined threshold tolerate lost
	// punctuation/formatting while rejecting unrelated prose and older responses
	// much farther from the terminal prompt.
	if best.Confidence < minimumConfidence {
		return Result{}, ErrNoMatch
	}
	return best, nil
}

func bestFromFiles(files []candidateFile, cwd string, screenTokens []string, best Result) Result {
	for _, file := range files {
		var messages []message
		switch file.provider {
		case "codex":
			messages = codexMessages(file.path)
		case "claude":
			messages = claudeMessages(file.path)
		}
		for _, candidate := range messages {
			if cwd != "" && candidate.cwd != "" && !samePath(candidate.cwd, cwd) {
				continue
			}
			if len(candidate.text) > maxSourceBytes {
				continue
			}
			score := overlapScore(tokenize(candidate.text), screenTokens)
			if score > best.Confidence {
				best = Result{
					Source: candidate.text, Format: "markdown",
					Origin: candidate.provider + "-transcript", Confidence: score,
				}
			}
		}
	}
	return best
}

func discover(root, provider, cwd string) []candidateFile {
	cutoff := time.Now().Add(-candidateMaxAge)
	searchRoot := root
	trustedProjectScope := false
	if provider == "claude" && cwd != "" {
		if projectRoot, ok := claudeProjectRoot(root, cwd); ok {
			searchRoot = projectRoot
			trustedProjectScope = true
		}
	}
	var files []candidateFile
	_ = filepath.WalkDir(searchRoot, func(path string, entry os.DirEntry, err error) error {
		if err != nil || entry == nil {
			return nil
		}
		if entry.IsDir() {
			return nil
		}
		if !strings.HasSuffix(strings.ToLower(entry.Name()), ".jsonl") {
			return nil
		}
		info, err := entry.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		files = append(files, candidateFile{path: path, provider: provider, mtime: info.ModTime()})
		return nil
	})
	sort.SliceStable(files, func(i, j int) bool { return files[i].mtime.After(files[j].mtime) })

	// Scope before parsing file contents, then inspect newest-first until enough
	// matching sessions are found. Claude's project directory already encodes
	// the cwd, which avoids opening thousands of unrelated JSONL files.
	filtered := make([]candidateFile, 0, min(maxCandidateFiles, len(files)))
	for _, file := range files {
		if cwd != "" && !trustedProjectScope {
			var transcriptCWD string
			var ok bool
			if provider == "codex" {
				transcriptCWD, ok = codexSessionCWD(file.path)
			} else if provider == "claude" {
				transcriptCWD, ok = claudeSessionCWD(file.path)
			}
			if ok && !samePath(transcriptCWD, cwd) {
				continue
			}
		}
		filtered = append(filtered, file)
		if len(filtered) == maxCandidateFiles {
			break
		}
	}
	return filtered
}

// Claude stores sessions under ~/.claude/projects/<sanitized-cwd>: separators,
// underscores, spaces, and other punctuation become dashes (without collapsing).
// Choose the nearest existing project directory so a pane currently in a repo
// subdirectory can still find a session that began at the repo root.
func claudeProjectRoot(root, cwd string) (string, bool) {
	path := filepath.Clean(cwd)
	for {
		candidate := filepath.Join(root, claudeProjectKey(path))
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate, true
		}
		parent := filepath.Dir(path)
		if parent == path {
			return "", false
		}
		path = parent
	}
}

func claudeProjectKey(path string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || r == '-' {
			return r
		}
		return '-'
	}, path)
}

func claudeSessionCWD(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 256<<10))
	if err != nil {
		return "", false
	}
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		b = b[:i]
	}
	var envelope struct {
		CWD string `json:"cwd"`
	}
	if json.Unmarshal(b, &envelope) != nil || envelope.CWD == "" {
		return "", false
	}
	return envelope.CWD, true
}

func codexSessionCWD(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, 256<<10))
	if err != nil {
		return "", false
	}
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		b = b[:i]
	}
	var envelope struct {
		Type    string `json:"type"`
		Payload struct {
			CWD string `json:"cwd"`
		} `json:"payload"`
	}
	if json.Unmarshal(b, &envelope) != nil || envelope.Type != "session_meta" || envelope.Payload.CWD == "" {
		return "", false
	}
	return envelope.Payload.CWD, true
}

func codexMessages(path string) []message {
	lines := tailLines(path, maxTranscriptTail)
	out := make([]message, 0, maxMessagesPerFile)
	for i := len(lines) - 1; i >= 0 && len(out) < maxMessagesPerFile; i-- {
		var envelope struct {
			Type    string `json:"type"`
			Payload struct {
				Type    string `json:"type"`
				Role    string `json:"role"`
				Content []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			} `json:"payload"`
		}
		if json.Unmarshal(lines[i], &envelope) != nil || envelope.Type != "response_item" ||
			envelope.Payload.Type != "message" || envelope.Payload.Role != "assistant" {
			continue
		}
		var parts []string
		for _, content := range envelope.Payload.Content {
			if content.Type == "output_text" && strings.TrimSpace(content.Text) != "" {
				parts = append(parts, content.Text)
			}
		}
		if text := strings.TrimSpace(strings.Join(parts, "\n\n")); text != "" {
			out = append(out, message{text: text, provider: "codex"})
		}
	}
	return out
}

func claudeMessages(path string) []message {
	lines := tailLines(path, maxTranscriptTail)
	out := make([]message, 0, maxMessagesPerFile)
	for i := len(lines) - 1; i >= 0 && len(out) < maxMessagesPerFile; i-- {
		var envelope struct {
			Type    string `json:"type"`
			CWD     string `json:"cwd"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		}
		if json.Unmarshal(lines[i], &envelope) != nil || envelope.Type != "assistant" ||
			envelope.Message.Role != "assistant" {
			continue
		}
		var blocks []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		var parts []string
		if json.Unmarshal(envelope.Message.Content, &blocks) == nil {
			for _, block := range blocks {
				if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
					parts = append(parts, block.Text)
				}
			}
		} else {
			var plain string
			if json.Unmarshal(envelope.Message.Content, &plain) == nil && strings.TrimSpace(plain) != "" {
				parts = append(parts, plain)
			}
		}
		if text := strings.TrimSpace(strings.Join(parts, "\n\n")); text != "" {
			out = append(out, message{text: text, cwd: envelope.CWD, provider: "claude"})
		}
	}
	return out
}

func tailLines(path string, maxBytes int64) [][]byte {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil
	}
	offset := info.Size() - maxBytes
	if offset < 0 {
		offset = 0
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil
	}
	b, err := io.ReadAll(io.LimitReader(f, maxBytes))
	if err != nil {
		return nil
	}
	if offset > 0 {
		if firstNewline := bytes.IndexByte(b, '\n'); firstNewline >= 0 {
			b = b[firstNewline+1:]
		} else {
			return nil
		}
	}
	return bytes.Split(bytes.TrimSpace(b), []byte{'\n'})
}

func tokenize(text string) []string {
	var tokens []string
	var current []rune
	flush := func() {
		if len(current) == 0 {
			return
		}
		tokens = append(tokens, strings.ToLower(string(current)))
		current = current[:0]
	}
	for _, r := range text {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			current = append(current, r)
		} else {
			flush()
		}
	}
	flush()
	return tokens
}

func overlapScore(source, screen []string) float64 {
	if len(source) < 8 || len(screen) < 8 {
		return 0
	}
	const gramSize = 3
	// Keep the LAST position of each shingle. The response nearest the terminal
	// prompt is the current one; earlier progress updates can also be present in
	// the same capture and sometimes have deceptively perfect short-text overlap.
	screenGrams := make(map[string]int, len(screen))
	for i := 0; i+gramSize <= len(screen); i++ {
		screenGrams[strings.Join(screen[i:i+gramSize], "\x1f")] = i
	}

	// The end of an answer is the strongest anchor because it sits immediately
	// above the terminal prompt even when a very long response has scrolled.
	start := 0
	if len(source) > 240 {
		start = len(source) - 240
	}
	total, matched := 0, 0
	var positions []int
	for i := start; i+gramSize <= len(source); i++ {
		total++
		if position, ok := screenGrams[strings.Join(source[i:i+gramSize], "\x1f")]; ok {
			matched++
			positions = append(positions, position)
		}
	}
	if total == 0 || matched < 4 {
		return 0
	}
	coverage := float64(matched) / float64(total)
	if coverage < 0.58 {
		return 0
	}
	// One generic shingle can repeat near the prompt. The median position tracks
	// the candidate's actual contiguous cluster instead of being hijacked by that
	// outlier (the earlier furthest-match rule selected progress commentary).
	sort.Ints(positions)
	middle := positions[len(positions)/2]
	position := float64(middle+gramSize) / float64(len(screen))
	return 0.55*coverage + 0.45*position
}

func samePath(a, b string) bool {
	normalize := func(value string) string {
		value = strings.ReplaceAll(strings.TrimSpace(value), "\\", "/")
		value = strings.TrimRight(filepath.Clean(value), "/")
		if len(value) >= 2 && value[1] == ':' {
			value = strings.ToLower(value)
		}
		return value
	}
	return normalize(a) == normalize(b)
}
