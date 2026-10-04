package rendersource

import (
	"bytes"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"golang.org/x/net/html"
)

// Matching compares rendered text, not invisible Markdown link destinations or
// titles. Use a Markdown parser so nested labels, reference links, code literals,
// entities and table cells follow the same rules as the rich document renderer.
// The original source is never rewritten or replaced by this matching view.
func visibleMarkdown(source string) string {
	var rendered bytes.Buffer
	md := goldmark.New(goldmark.WithExtensions(extension.Table))
	if err := md.Convert([]byte(source), &rendered); err != nil {
		return source
	}
	var out strings.Builder
	z := html.NewTokenizer(&rendered)
	for {
		switch z.Next() {
		case html.ErrorToken:
			return out.String()
		case html.TextToken:
			out.Write(z.Text())
		case html.StartTagToken, html.EndTagToken, html.SelfClosingTagToken:
			name, _ := z.TagName()
			switch string(name) {
			case "p", "div", "br", "hr", "pre", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "tr":
				out.WriteByte(' ')
			}
		}
	}
}

func candidateScore(candidate message, screen []string, minimumTokens int) float64 {
	screen = withoutRecordedDecorations(screen, candidate.decorations)
	visible := tokenize(visibleMarkdown(candidate.text))
	// Some TUIs display literal Markdown/math instead of consuming it. Retain
	// that representation too, with identical provenance and tail requirements.
	return max(overlapScoreWithMinimum(visible, screen, minimumTokens),
		overlapScoreWithMinimum(tokenize(candidate.text), screen, minimumTokens))
}

// Adapters may identify non-answer text from structured transcript records.
// Only an exact token span of that text is discounted, not an arbitrary suffix
// or a line beginning with a magic word. Unknown/new prose still invalidates a
// stale match. A sentinel prevents a run from bridging the removed span.
func withoutRecordedDecorations(screen []string, decorations []string) []string {
	for _, decoration := range decorations {
		tokens := tokenize(decoration)
		if len(tokens) < matchAnchorTokens {
			continue
		}
		for start := len(screen) - len(tokens); start >= 0; start-- {
			match := true
			for offset, token := range tokens {
				if screen[start+offset] != token {
					match = false
					break
				}
			}
			if match {
				trimmed := make([]string, 0, len(screen)-len(tokens)+1)
				trimmed = append(trimmed, screen[:start]...)
				trimmed = append(trimmed, "\x00decoration")
				trimmed = append(trimmed, screen[start+len(tokens):]...)
				screen = trimmed
				break
			}
		}
	}
	return screen
}
