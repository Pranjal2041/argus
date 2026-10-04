package rendersource

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
)

// HistoryEntry is public, authored conversation text. Tool payloads, reasoning,
// and system/developer instructions are not displayable terminal history.
type HistoryEntry struct {
	Role string `json:"role"`
	Text string `json:"text"`
}

// History reads only a transcript whose ownership the host provider has proved.
// Unlike Render, history has no "currently visible answer" selection: all
// public messages in the bounded tail remain in chronological order. A missing
// or unsupported exact source falls back to terminal output at the caller,
// never to a guessed neighboring conversation.
func History(ref TranscriptRef) ([]HistoryEntry, error) {
	return HistoryWithScreen(ref, "")
}

// HistoryWithScreen corroborates launch-time references with public text on the
// current terminal. Live process-owned references do not need a visible match.
func HistoryWithScreen(ref TranscriptRef, screen string) ([]HistoryEntry, error) {
	if ref.Path == "" {
		return nil, ErrNoMatch
	}
	var decode func([]byte) (HistoryEntry, bool)
	switch ref.Provider {
	case "codex":
		decode = codexHistoryEntry
	case "claude":
		decode = claudeHistoryEntry
	default:
		return nil, ErrNoMatch
	}
	entries := readHistoryTail(ref.Path, decode)
	if len(entries) == 0 {
		return nil, ErrNoMatch
	}
	if ref.RequireScreenMatch {
		screenTokens := tokenize(screen)
		matched := false
		for _, entry := range entries {
			tokens := tokenize(entry.Text)
			// Short generic replies cannot corroborate a potentially stale launch
			// selector, even if they appear in both conversations.
			if len(tokens) >= exactTranscriptMinimumMatchTokens &&
				overlapScoreWithMinimum(tokens, screenTokens, exactTranscriptMinimumMatchTokens) >= minimumConfidence {
				matched = true
				break
			}
		}
		if !matched {
			return nil, ErrNoMatch
		}
	}
	return entries, nil
}

// Scan backward by record, not by a small fixed byte tail: screenshots and tool
// responses may occupy many megabytes between two public messages. Both I/O and
// memory are bounded, and oversized private records are skipped without keeping
// their full contents in memory. The resulting document is chronological.
func readHistoryTail(path string, decode func([]byte) (HistoryEntry, bool)) []HistoryEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil
	}
	const maxScanBytes = 256 << 20
	const maxRecordBytes = 8 << 20
	const maxEntries = 200
	offset := info.Size()
	floor := max(int64(0), offset-maxScanBytes)
	var entries []HistoryEntry
	var pending []byte
	oversized, stopped, total := false, false, 0
	consume := func(line []byte) {
		entry, ok := decode(line)
		if !ok || strings.TrimSpace(entry.Text) == "" {
			return
		}
		if total+len(entry.Text) > maxSourceBytes {
			stopped = true
			return
		}
		entries = append(entries, entry)
		total += len(entry.Text)
		stopped = len(entries) >= maxEntries
	}
	buffer := make([]byte, 1<<20)
	for offset > floor && !stopped {
		n := int(min(int64(len(buffer)), offset-floor))
		offset -= int64(n)
		if _, err := f.ReadAt(buffer[:n], offset); err != nil {
			break
		}
		for end := n; end > 0 && !stopped; {
			separator := bytes.LastIndexByte(buffer[:end], '\n')
			part := buffer[separator+1 : end]
			if len(part)+len(pending) > maxRecordBytes {
				oversized = true
				pending = nil
			}
			if !oversized {
				if len(pending) == 0 && separator >= 0 {
					consume(part)
				} else {
					line := make([]byte, 0, len(part)+len(pending))
					line = append(line, part...)
					line = append(line, pending...)
					if separator >= 0 {
						consume(line)
					} else {
						pending = line
					}
				}
			}
			if separator >= 0 {
				pending = nil
				oversized = false
			}
			end = separator
		}
	}
	if offset == 0 && !stopped && !oversized && len(pending) > 0 {
		consume(pending)
	}
	for i, j := 0, len(entries)-1; i < j; i, j = i+1, j-1 {
		entries[i], entries[j] = entries[j], entries[i]
	}
	return entries
}

func codexHistoryEntry(line []byte) (HistoryEntry, bool) {
	var record struct {
		Type    string `json:"type"`
		Payload struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Channel string `json:"channel"`
			Phase   string `json:"phase"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"payload"`
	}
	if json.Unmarshal(line, &record) != nil || record.Type != "response_item" || record.Payload.Type != "message" {
		return HistoryEntry{}, false
	}
	p := record.Payload
	if (p.Role != "user" && p.Role != "assistant") || p.Channel == "analysis" || p.Phase == "analysis" {
		return HistoryEntry{}, false
	}
	var parts []string
	for _, block := range p.Content {
		if (p.Role == "user" && block.Type == "input_text") || (p.Role == "assistant" && block.Type == "output_text") {
			parts = append(parts, block.Text)
		}
	}
	return HistoryEntry{Role: p.Role, Text: strings.Join(parts, "\n\n")}, true
}

func claudeHistoryEntry(line []byte) (HistoryEntry, bool) {
	var record struct {
		Type        string `json:"type"`
		IsSidechain bool   `json:"isSidechain"`
		Message     struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &record) != nil || record.IsSidechain ||
		(record.Type != "user" && record.Type != "assistant") || record.Type != record.Message.Role {
		return HistoryEntry{}, false
	}
	var plain string
	if json.Unmarshal(record.Message.Content, &plain) == nil {
		return HistoryEntry{Role: record.Message.Role, Text: plain}, true
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(record.Message.Content, &blocks) != nil {
		return HistoryEntry{}, false
	}
	var parts []string
	for _, block := range blocks {
		if block.Type == "text" {
			parts = append(parts, block.Text)
		}
	}
	return HistoryEntry{Role: record.Message.Role, Text: strings.Join(parts, "\n\n")}, true
}
