package rendersource

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"universal-tmux/internal/session"
)

func editorScreen(body, prompt, border, footer string) session.ScreenSnapshot {
	lines := strings.Split(body, "\n")
	lines = append(lines, border, prompt, border)
	cursor := len(lines) - 2
	lines = append(lines, strings.Split(footer, "\n")...)
	lines = append(lines, "", "")
	return session.ScreenSnapshot{Lines: lines, Cols: 80, Rows: len(lines), CursorX: 2, CursorY: cursor, CursorVisible: true}
}

func TestEditorRegionDoesNotDependOnProviderOrStatusWordCount(t *testing.T) {
	source := "The current answer preserves the complete authored result with enough distinctive visible evidence to identify this response."
	for _, provider := range []string{"claude", "codex"} {
		for _, layout := range []struct{ prompt, border string }{
			{"❯ ", strings.Repeat("─", 80)},
			{"› draft input", "╭" + strings.Repeat("─", 78) + "╮"},
			{"> ", "+" + strings.Repeat("-", 78) + "+"},
		} {
			for _, count := range []int{0, 67, 250, 1000} {
				t.Run(fmt.Sprintf("%s/%s/%d", provider, layout.prompt, count), func(t *testing.T) {
					home := t.TempDir()
					path := writeProviderTurns(t, home, provider, source)
					// Status text is arbitrary. Matching must never depend on
					// agent names, badges, a particular footer vocabulary or size.
					screen := editorScreen(source, layout.prompt, layout.border, strings.Repeat("unfamiliar ", count))
					for _, exact := range []bool{false, true} {
						ref := TranscriptRef{}
						if exact {
							ref = TranscriptRef{Provider: provider, Path: path}
						}
						if count > 64 {
							if _, err := ResolveWithTranscript(home, "", strings.Join(screen.Lines, "\n"), ref); !errors.Is(err, ErrNoMatch) {
								t.Fatalf("fixture must reproduce unsegmented status rejection: %v", err)
							}
						}
						got, err := ResolveWithTranscript(home, "", MatchingScreen(screen), ref)
						if err != nil || got.Source != source {
							t.Fatalf("exact=%t: %+v %v", exact, got, err)
						}
					}
				})
			}
		}
	}
}

func TestEditorBoundaryRetainsHistoryAndMultilineInputGeometry(t *testing.T) {
	s := editorScreen("answer\n\x1b[2mfaint text\ncontinued\x1b[0m\nlast answer row", "> draft", strings.Repeat("─", 80), "status panel")
	top := s.CursorY - 1
	s.Lines = append(s.Lines[:s.CursorY+1], append([]string{"  continuation"}, s.Lines[s.CursorY+1:]...)...)
	s.Rows++
	s.CursorY++
	s.CursorX = 14
	s.Lines = append([]string{"history", "", "earlier response"}, s.Lines...)
	boundary, ok := editorBoundary(s)
	if !ok || boundary != top+3 {
		t.Fatalf("history/wrapped editor: boundary=%d ok=%t", boundary, ok)
	}
	got := MatchingScreen(s)
	if !strings.Contains(got, "history") || !strings.Contains(got, "last answer row") || strings.Contains(got, "continuation") || strings.Contains(got, "status") {
		t.Fatalf("wrong matching view: %q", got)
	}
}

func TestMissingOrAmbiguousEditorGeometryKeepsAllText(t *testing.T) {
	for name, mutate := range map[string]func(*session.ScreenSnapshot){
		"hidden cursor":          func(s *session.ScreenSnapshot) { s.CursorVisible = false },
		"cursor outside editor":  func(s *session.ScreenSnapshot) { s.CursorY = 0 },
		"cursor outside frame":   func(s *session.ScreenSnapshot) { s.CursorX = 80 },
		"cursor before prompt":   func(s *session.ScreenSnapshot) { s.CursorX = 0 },
		"no lower boundary":      func(s *session.ScreenSnapshot) { s.Lines[s.CursorY+1] = "another paragraph" },
		"mismatched borders":     func(s *session.ScreenSnapshot) { s.Lines[s.CursorY+1] = strings.Repeat("─", 65) },
		"narrow rules":           func(s *session.ScreenSnapshot) { s.Lines[s.CursorY-1] = "---"; s.Lines[s.CursorY+1] = "---" },
		"box is a table":         func(s *session.ScreenSnapshot) { s.Lines[s.CursorY] = "| Product | Count |" },
		"prompt-like prose":      func(s *session.ScreenSnapshot) { s.Lines[s.CursorY] = "›This is not a prompt field" },
		"missing physical rows":  func(s *session.ScreenSnapshot) { s.Rows += 10 },
		"border only in history": func(s *session.ScreenSnapshot) { s.Rows -= 2; s.CursorY -= 2 },
	} {
		t.Run(name, func(t *testing.T) {
			s := editorScreen("answer", "> ", strings.Repeat("─", 80), "unknown newer prose must stay visible")
			mutate(&s)
			want := strings.Join(s.Lines, "\n")
			if got := MatchingScreen(s); got != want {
				t.Fatalf("ambiguous screen was cropped: %q", got)
			}
		})
	}
}

func TestEditorRegionCannotHideNewAnswersOrSupplyMatchingEvidence(t *testing.T) {
	previous := "The previous answer remains fully visible with enough distinctive language to satisfy the transcript overlap threshold."
	newer := strings.Repeat("A separate investigation now explains a completely different result not yet flushed to the transcript. ", 12)
	for _, provider := range []string{"claude", "codex"} {
		for _, exact := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/exact=%t", provider, exact), func(t *testing.T) {
				home := t.TempDir()
				path := writeProviderTurns(t, home, provider, previous)
				ref := TranscriptRef{}
				if exact {
					ref = TranscriptRef{Provider: provider, Path: path}
				}
				for name, screen := range map[string]session.ScreenSnapshot{
					"new prose before editor": editorScreen(previous+"\n"+newer, "> ", strings.Repeat("─", 80), "status"),
					"match only in draft":     editorScreen("unrelated visible conversation without this transcript's answer", "> "+previous, strings.Repeat("─", 80), "status"),
					"match only in footer":    editorScreen("unrelated visible conversation without this transcript's answer", "> ", strings.Repeat("─", 80), previous),
				} {
					if _, err := ResolveWithTranscript(home, "", MatchingScreen(screen), ref); !errors.Is(err, ErrNoMatch) {
						t.Fatalf("%s accepted stale/misplaced match: %v", name, err)
					}
				}
				writeProviderTurns(t, home, provider, previous, "")
				screen := editorScreen(previous, "> ", strings.Repeat("─", 80), strings.Repeat("status ", 100))
				if _, err := ResolveWithTranscript(home, "", MatchingScreen(screen), ref); !errors.Is(err, ErrNoMatch) {
					t.Fatalf("unanswered turn resurrected old answer: %v", err)
				}
			})
		}
	}
}
