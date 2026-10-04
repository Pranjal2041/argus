package rendersource

import (
	"strings"
	"unicode/utf8"

	"universal-tmux/internal/session"
	"universal-tmux/internal/terminaltext"
)

// MatchingScreen keeps transcript evidence in the conversation region of a
// coherent terminal capture. An active, visibly focused prompt enclosed by two
// aligned horizontal borders separates conversation from editor/status UI.
// Neither the provider nor words in the status panel determine that boundary.
// Without that geometry, preserve the entire capture and the conservative
// unmatched-prose guard. This is ONLY a matching view: source and terminal
// snapshots handed to the renderer are never cropped or rewritten.
func MatchingScreen(screen session.ScreenSnapshot) string {
	end := len(screen.Lines)
	if boundary, ok := editorBoundary(screen); ok {
		end = boundary
	}
	return terminaltext.Plain([]byte(strings.Join(screen.Lines[:end], "\n")), true)
}

func editorBoundary(s session.ScreenSnapshot) (int, bool) {
	if !s.CursorVisible || s.Cols < 12 || s.Rows < 3 || len(s.Lines) < s.Rows ||
		s.CursorY < 0 || s.CursorY >= s.Rows || s.CursorX < 0 || s.CursorX >= s.Cols {
		return 0, false
	}
	first := len(s.Lines) - s.Rows
	cursor := first + s.CursorY
	// Retain faint text while finding physical rows. Removing it can also
	// remove newlines; layout and text normalization must be separate steps.
	rows := strings.Split(terminaltext.Plain([]byte(strings.Join(s.Lines, "\n")), false), "\n")
	if len(rows) != len(s.Lines) {
		return 0, false
	}
	top, bottom := cursor-1, cursor+1
	var left, right int
	for ; top >= first; top-- {
		if l, r, ok := horizontalBorder(rows[top], s.Cols); ok {
			left, right = l, r
			break
		}
	}
	if top < first || s.CursorX < left || s.CursorX >= right {
		return 0, false
	}
	for ; bottom < len(rows); bottom++ {
		if l, r, ok := horizontalBorder(rows[bottom], s.Cols); ok {
			if l != left || r != right {
				return 0, false
			}
			break
		}
	}
	if bottom == len(rows) {
		return 0, false
	}
	// Borders alone could be a data table or a code listing. Require the
	// enclosed field to start with a terminal input prompt, with the visible
	// editing cursor inside it. Wrapped input can occupy several rows.
	line := strings.TrimLeft(rows[top+1], " \t│┃║|\u00a0")
	prompt, n := utf8.DecodeRuneInString(line)
	if prompt != '❯' && prompt != '›' && prompt != '>' {
		return 0, false
	}
	if len(line) > n && line[n] != ' ' && !strings.HasPrefix(line[n:], "\u00a0") {
		return 0, false
	}
	if cursor == top+1 {
		prefix := utf8.RuneCountInString(rows[top+1]) - utf8.RuneCountInString(line)
		if s.CursorX <= prefix {
			return 0, false
		}
	}
	return top, true
}

func horizontalBorder(row string, cols int) (left, right int, ok bool) {
	runes := []rune(strings.TrimRight(row, " \t\u00a0"))
	for left < len(runes) && (runes[left] == ' ' || runes[left] == '\u00a0') {
		left++
	}
	right = len(runes)
	if right > cols || right-left < max(12, cols*3/4) {
		return 0, 0, false
	}
	for i, r := range runes[left:] {
		if strings.ContainsRune("─━═-", r) {
			continue
		}
		if (i == 0 || left+i == right-1) && strings.ContainsRune("┌┐└┘╭╮╰╯╔╗╚╝+", r) {
			continue
		}
		return 0, 0, false
	}
	return left, right, true
}
