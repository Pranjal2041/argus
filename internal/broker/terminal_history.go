package broker

import (
	"fmt"
	"strings"

	"universal-tmux/internal/rendersource"
)

// TerminalHistory is a read-only document, separate from the terminal input
// stream and live screen. Fetching it must not send keys, resize, or enter a
// backend's interactive copy mode.
type TerminalHistory struct {
	Text   string `json:"text"`
	Origin string `json:"origin"`
}

type historyCapturer interface {
	CaptureHistory(name string, lines int) (string, error)
}

func (m *Manager) TerminalHistory(name string) (TerminalHistory, error) {
	resolved, ok := m.resolveTarget(name)
	if !ok {
		return TerminalHistory{}, fmt.Errorf("no such session: %q", name)
	}
	name = resolved
	if !m.prov.Has(name) {
		return TerminalHistory{}, fmt.Errorf("no such session: %q", name)
	}
	if provider, ok := m.prov.(agentTranscriptProvider); ok {
		if ref, err := provider.AgentTranscript(name); err == nil {
			var screen string
			if ref.RequireScreenMatch {
				screen, _ = m.Recent(name, 0)
			}
			if entries, err := rendersource.HistoryWithScreen(ref, screen); err == nil {
				var text strings.Builder
				for i, entry := range entries {
					if i > 0 {
						text.WriteString("\n\n")
					}
					if entry.Role == "user" {
						text.WriteString("You\n")
					} else {
						text.WriteString("Assistant\n")
					}
					text.WriteString(entry.Text)
				}
				return TerminalHistory{Text: text.String(), Origin: "conversation"}, nil
			}
		}
	}
	var text string
	var err error
	if provider, ok := m.prov.(historyCapturer); ok {
		text, err = provider.CaptureHistory(name, 10000)
	} else {
		text, err = m.Recent(name, 10000)
	}
	return TerminalHistory{Text: text, Origin: "terminal"}, err
}
