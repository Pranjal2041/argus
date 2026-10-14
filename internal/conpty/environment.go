package conpty

import (
	"strings"

	"universal-tmux/internal/terminalenv"
)

// Kept platform-independent so the environment supplied to ConPTY is tested on
// every development host, not only hosts with a Windows console.
func sessionEnvironment(base []string, lineageID string) []string {
	environment := terminalenv.Interactive(base)
	out := make([]string, 0, len(environment)+1)
	for _, value := range environment {
		if !strings.HasPrefix(strings.ToUpper(value), "UT_SESSION_LINEAGE_ID=") {
			out = append(out, value)
		}
	}
	return append(out, "UT_SESSION_LINEAGE_ID="+lineageID)
}
