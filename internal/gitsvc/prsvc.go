package gitsvc

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"time"
)

// Pull-request review via the `gh` CLI (the machine that owns the repo runs it,
// so its gh auth is used). All read paths are safe; the write paths (review,
// merge, comment) are explicit user actions from the UI. Everything degrades
// gracefully when gh is missing, unauthenticated, or the repo has no GitHub
// remote — the client shows the reason instead of a dead panel.

const ghTimeout = 25 * time.Second

// PRError classifies why PR features are unavailable, so the UI can guide.
type PRError struct {
	Error     string `json:"error"`
	NeedsAuth bool   `json:"needsAuth,omitempty"`
	NoGH      bool   `json:"noGH,omitempty"`
	NotRepo   bool   `json:"notRepo,omitempty"`
}

func ghRun(dir string, args ...string) ([]byte, *PRError) {
	if _, err := exec.LookPath("gh"); err != nil {
		return nil, &PRError{Error: "the GitHub CLI (gh) is not installed on this machine", NoGH: true}
	}
	ctx, cancel := context.WithTimeout(context.Background(), ghTimeout)
	defer cancel()
	// gh has no -C flag; it uses the working directory to find the repo/remote.
	cmd := exec.CommandContext(ctx, "gh", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		stderr := ""
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = strings.TrimSpace(string(ee.Stderr))
		}
		low := strings.ToLower(stderr)
		switch {
		case strings.Contains(low, "not logged") || strings.Contains(low, "authentication") || strings.Contains(low, "gh auth login"):
			return nil, &PRError{Error: "not authenticated to GitHub on this machine — run `gh auth login`", NeedsAuth: true}
		case strings.Contains(low, "no git remotes") || strings.Contains(low, "not a git repository") || strings.Contains(low, "could not determine") || strings.Contains(low, "none of the git remotes"):
			return nil, &PRError{Error: "this folder has no GitHub remote", NotRepo: true}
		case stderr != "":
			return nil, &PRError{Error: stderr}
		default:
			return nil, &PRError{Error: err.Error()}
		}
	}
	return out, nil
}

const prListFields = "number,title,author,headRefName,baseRefName,state,isDraft,createdAt,updatedAt,additions,deletions,changedFiles,url,mergeable,reviewDecision"

// ListPRs returns PRs for the repo at dir. state = open | closed | merged | all
// (default open). Raw gh JSON passed through.
func ListPRs(dir, state string) (json.RawMessage, *PRError) {
	switch state {
	case "open", "closed", "merged", "all":
	default:
		state = "open"
	}
	out, e := ghRun(dir, "pr", "list", "--state", state, "--limit", "50", "--json", prListFields)
	if e != nil {
		return nil, e
	}
	return json.RawMessage(out), nil
}

const prViewFields = prListFields + ",body,commits,files,statusCheckRollup,reviews,comments,labels"

// ViewPR returns full detail for one PR plus its diff (as a second field the
// handler merges), all via gh.
func ViewPR(dir, num string) (json.RawMessage, *PRError) {
	out, e := ghRun(dir, "pr", "view", num, "--json", prViewFields)
	if e != nil {
		return nil, e
	}
	return json.RawMessage(out), nil
}

// PRDiff returns the unified diff for a PR (capped like every other diff so the
// renderer never chokes).
func PRDiff(dir, num string) ([]byte, *PRError) {
	out, e := ghRun(dir, "pr", "diff", num)
	if e != nil {
		return nil, e
	}
	return capDiff(out), nil
}

// ReviewPR submits a review: event = APPROVE | REQUEST_CHANGES | COMMENT.
func ReviewPR(dir, num, event, body string) *PRError {
	var flag string
	switch event {
	case "APPROVE":
		flag = "--approve"
	case "REQUEST_CHANGES":
		flag = "--request-changes"
	case "COMMENT":
		flag = "--comment"
	default:
		return &PRError{Error: "unknown review event"}
	}
	args := []string{"pr", "review", num, flag}
	// approve with no body is allowed; request-changes/comment need a body
	if strings.TrimSpace(body) != "" {
		args = append(args, "--body", body)
	} else if event != "APPROVE" {
		return &PRError{Error: "a comment is required for this review action"}
	}
	_, e := ghRun(dir, args...)
	return e
}

// MergePR merges a PR. method = merge | squash | rebase.
func MergePR(dir, num, method string) *PRError {
	flag := "--squash"
	switch method {
	case "merge":
		flag = "--merge"
	case "rebase":
		flag = "--rebase"
	}
	_, e := ghRun(dir, "pr", "merge", num, flag)
	return e
}

// CommentPR adds an issue-style comment (not a review).
func CommentPR(dir, num, body string) *PRError {
	if strings.TrimSpace(body) == "" {
		return &PRError{Error: "empty comment"}
	}
	_, e := ghRun(dir, "pr", "comment", num, "--body", body)
	return e
}
