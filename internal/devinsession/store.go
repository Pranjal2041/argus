// Package devinsession translates Devin's local session storage into public
// conversation records. Selection, screen matching and rendering belong to the
// consumers, not to this format adapter.
package devinsession

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const (
	MaxPublicBytes = 2 << 20
	maxMessages    = 200
	maxChainNodes  = 8192
	maxExportSize  = 32 << 20
)

var ErrUnavailable = errors.New("Devin conversation is unavailable")
var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`)

func ValidSessionID(id string) bool { return sessionIDPattern.MatchString(id) }

// DataDirectory follows Devin's XDG data layout, including private CLI profiles.
func DataDirectory(home, xdgDataHome string) string {
	if strings.TrimSpace(xdgDataHome) == "" {
		xdgDataHome = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(xdgDataHome, "devin", "cli")
}

type Session struct {
	ID        string
	Directory string
	UpdatedAt time.Time
}

type Message struct {
	Role  string
	Text  string
	Phase string
}

type Conversation struct {
	Session
	Messages []Message // chronological; only public user/assistant content
}

// Exists checks one exact database identity without reading its messages.
func Exists(path, id string) bool {
	if !ValidSessionID(id) {
		return false
	}
	return withDatabase(path, func(ctx context.Context, tx *sql.Tx) error {
		var found int
		return tx.QueryRowContext(ctx, `SELECT 1 FROM sessions WHERE id = ?`, id).Scan(&found)
	}) == nil
}

// withDatabase never creates a database, journal or sidecar. An inactive WAL
// database without sidecars needs SQLite's immutable reader; verify that it
// stayed inactive and unchanged before accepting that snapshot. A live WAL
// database uses normal read-only locking and sees committed WAL contents.
func withDatabase(path string, read func(context.Context, *sql.Tx) error) error {
	before, err := os.Stat(path)
	if err != nil || !before.Mode().IsRegular() {
		return ErrUnavailable
	}
	_, walErr := os.Stat(path + "-wal")
	immutable := os.IsNotExist(walErr)
	if walErr != nil && !immutable {
		return ErrUnavailable
	}
	if !immutable {
		if info, err := os.Stat(path + "-shm"); err != nil || !info.Mode().IsRegular() {
			return ErrUnavailable
		}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(abs)}
	query := url.Values{"mode": {"ro"}, "_pragma": {"query_only(1)", "busy_timeout(100)"}}
	if immutable {
		query.Set("immutable", "1")
	}
	u.RawQuery = query.Encode()
	db, err := sql.Open("sqlite", u.String())
	if err != nil {
		return err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	tx, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := read(ctx, tx); err != nil {
		return err
	}
	if immutable {
		after, err := os.Stat(path)
		_, walErr = os.Stat(path + "-wal")
		if err != nil || !os.IsNotExist(walErr) || !os.SameFile(before, after) ||
			before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
			return fmt.Errorf("%w: storage changed during the read", ErrUnavailable)
		}
	}
	return nil
}

// List returns bounded metadata only; it does not load neighboring conversations.
func List(path string, limit int) ([]Session, error) {
	limit = min(256, max(1, limit))
	var sessions []Session
	err := withDatabase(path, func(ctx context.Context, tx *sql.Tx) error {
		rows, err := tx.QueryContext(ctx, `SELECT id, working_directory, last_activity_at
			FROM sessions WHERE hidden = 0 ORDER BY last_activity_at DESC LIMIT ?`, limit)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var session Session
			var timestamp int64
			if err := rows.Scan(&session.ID, &session.Directory, &timestamp); err != nil {
				return err
			}
			if !ValidSessionID(session.ID) {
				continue
			}
			session.UpdatedAt = time.Unix(timestamp, 0)
			sessions = append(sessions, session)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, err
	}
	return sessions, nil
}

// Read follows the active main-chain head. Row order, recency, abandoned retry
// branches and subagent heads cannot choose a different conversation branch.
func Read(path, id string) (Conversation, error) {
	if !ValidSessionID(id) {
		return Conversation{}, ErrUnavailable
	}
	if strings.EqualFold(filepath.Ext(path), ".json") {
		conversation, err := ReadExport(path)
		if err == nil && conversation.ID != id {
			err = ErrUnavailable
		}
		return conversation, err
	}
	conversation := Conversation{Session: Session{ID: id}}
	err := withDatabase(path, func(ctx context.Context, tx *sql.Tx) error {
		var head sql.NullInt64
		var timestamp int64
		if err := tx.QueryRowContext(ctx, `SELECT working_directory, main_chain_id, last_activity_at
			FROM sessions WHERE id = ?`, id).Scan(&conversation.Directory, &head, &timestamp); err != nil {
			return err
		}
		conversation.UpdatedAt = time.Unix(timestamp, 0)
		if !head.Valid {
			return ErrUnavailable
		}
		rows, err := tx.QueryContext(ctx, `WITH RECURSIVE chain AS (
			SELECT node_id, parent_node_id, chat_message, 0 AS depth
			FROM message_nodes WHERE session_id = ? AND node_id = ?
			UNION ALL
			SELECT m.node_id, m.parent_node_id, m.chat_message, c.depth + 1
			FROM message_nodes m JOIN chain c ON m.node_id = c.parent_node_id
			WHERE m.session_id = ? AND c.depth < ?
		) SELECT node_id, depth, json_extract(chat_message, '$.role'),
			COALESCE(json_extract(chat_message, '$.phase'), ''),
			CASE WHEN json_extract(chat_message, '$.role') IN ('user', 'assistant')
				AND COALESCE(json_extract(chat_message, '$.phase'), '') NOT IN ('analysis', 'reasoning')
				AND json_type(chat_message, '$.content') = 'text'
				AND length(json_extract(chat_message, '$.content')) <= ?
				THEN json_extract(chat_message, '$.content') ELSE NULL END,
			COALESCE(json_array_length(chat_message, '$.tool_calls'), 0)
		FROM chain ORDER BY depth`, id, head.Int64, id, maxChainNodes, MaxPublicBytes)
		if err != nil {
			return err
		}
		defer rows.Close()
		total := 0
		seen := map[int64]bool{}
		for rows.Next() {
			var message Message
			var content sql.NullString
			var node int64
			var depth, toolCalls int
			if err := rows.Scan(&node, &depth, &message.Role, &message.Phase, &content, &toolCalls); err != nil {
				return err
			}
			if seen[node] || depth >= maxChainNodes {
				return ErrUnavailable
			}
			seen[node] = true
			if (message.Role != "user" && message.Role != "assistant") || message.Phase == "analysis" || message.Phase == "reasoning" {
				continue
			}
			if !content.Valid {
				// Do not step past an unrenderable newest answer and substitute an old one.
				if len(conversation.Messages) == 0 {
					return ErrUnavailable
				}
				break
			}
			message.Text = content.String
			if message.Role == "assistant" && message.Phase == "" && toolCalls == 0 {
				message.Phase = "final_answer"
			}
			if total+len(message.Text) > MaxPublicBytes {
				break
			}
			total += len(message.Text)
			conversation.Messages = append(conversation.Messages, message)
			if len(conversation.Messages) == maxMessages {
				break
			}
		}
		if len(seen) == 0 {
			return ErrUnavailable
		}
		return rows.Err()
	})
	if err != nil {
		return Conversation{}, err
	}
	for i, j := 0, len(conversation.Messages)-1; i < j; i, j = i+1, j-1 {
		conversation.Messages[i], conversation.Messages[j] = conversation.Messages[j], conversation.Messages[i]
	}
	return conversation, nil
}

// ReadExport accepts Devin's ATIF export without retaining system instructions,
// reasoning_content, observations, tool arguments/results, or agent metadata.
func ReadExport(path string) (Conversation, error) {
	f, err := os.Open(path)
	if err != nil {
		return Conversation{}, err
	}
	defer f.Close()
	body, err := io.ReadAll(io.LimitReader(f, maxExportSize+1))
	if err != nil || len(body) > maxExportSize {
		return Conversation{}, ErrUnavailable
	}
	var export struct {
		Schema string `json:"schema_version"`
		ID     string `json:"session_id"`
		Steps  []struct {
			Source    string            `json:"source"`
			Message   string            `json:"message"`
			ToolCalls []json.RawMessage `json:"tool_calls"`
		} `json:"steps"`
	}
	if err := json.Unmarshal(body, &export); err != nil || !strings.HasPrefix(export.Schema, "ATIF-") || !ValidSessionID(export.ID) {
		return Conversation{}, ErrUnavailable
	}
	conversation := Conversation{Session: Session{ID: export.ID}}
	total := 0
	for index := len(export.Steps) - 1; index >= 0 && len(conversation.Messages) < maxMessages; index-- {
		step := export.Steps[index]
		message := Message{Role: step.Source, Text: step.Message}
		switch step.Source {
		case "user":
		case "agent":
			message.Role = "assistant"
			if len(step.ToolCalls) == 0 {
				message.Phase = "final_answer"
			}
		default:
			continue
		}
		if total+len(message.Text) > MaxPublicBytes {
			if len(conversation.Messages) == 0 {
				return Conversation{}, ErrUnavailable
			}
			break
		}
		total += len(message.Text)
		conversation.Messages = append(conversation.Messages, message)
	}
	for i, j := 0, len(conversation.Messages)-1; i < j; i, j = i+1, j-1 {
		conversation.Messages[i], conversation.Messages[j] = conversation.Messages[j], conversation.Messages[i]
	}
	return conversation, nil
}
