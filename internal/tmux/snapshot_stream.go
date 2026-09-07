package tmux

import (
	"fmt"
	"strconv"
	"strings"
)

const snapshotMetadata = "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{alternate_on} #{cursor_flag} #{wrap_flag} #{insert_flag} #{origin_flag} #{scroll_region_upper} #{scroll_region_lower}"

type snapshotReply struct {
	id            uint64
	header        string
	body          strings.Builder
	end           string
	expectCapture bool
	invalid       bool
}

// Capture through the SAME control connection as %output. tmux queues command
// responses among its output blocks, so the result is an ordered stream cut,
// not a subprocess snapshot racing independently with live output.
func (c *Client) RequestSnapshot(id uint64) error {
	if id == 0 {
		return fmt.Errorf("snapshot ID must be nonzero")
	}
	return c.send(fmt.Sprintf("display-message -p -t %s \"ARGUS_SNAPSHOT_BEGIN:%d %s\" ; capture-pane -p -e -N -S -10000 -t %s ; display-message -p \"ARGUS_SNAPSHOT_END:%d\"", c.primary, id, snapshotMetadata, c.primary, id))
}

func (c *Client) collectSnapshotLine(line string) bool {
	s := &c.snapshotReply
	if s.end != "" {
		if line == s.end || line == strings.Replace(s.end, "%end ", "%error ", 1) {
			if strings.HasPrefix(line, "%error ") {
				s.invalid = true
			}
			s.end = ""
		} else if s.body.Len()+len(line)+1 <= 32*1024*1024 {
			s.body.WriteString(line)
			s.body.WriteByte('\n')
		} else {
			s.invalid = true
		}
		return true // Captured text is data, even when it resembles control messages.
	}
	if strings.HasPrefix(line, "ARGUS_SNAPSHOT_BEGIN:") {
		id, header, ok := strings.Cut(strings.TrimPrefix(line, "ARGUS_SNAPSHOT_BEGIN:"), " ")
		n, err := strconv.ParseUint(id, 10, 64)
		if !ok || err != nil || n == 0 {
			return true
		}
		*s = snapshotReply{id: n, header: header, expectCapture: true}
		return true
	}
	if s.id != 0 && s.expectCapture && strings.HasPrefix(line, "%begin ") {
		s.expectCapture = false
		s.end = strings.Replace(line, "%begin ", "%end ", 1)
		return true
	}
	if s.id != 0 && line == fmt.Sprintf("ARGUS_SNAPSHOT_END:%d", s.id) {
		capture := decodeScreenSnapshot([]byte(s.header + "\n" + s.body.String()))
		var data []byte
		if !s.invalid {
			data = capture.ANSI()
		}
		c.outCh <- Output{Pane: c.primary, Data: data, Cols: capture.Cols, Rows: capture.Rows, SnapshotID: s.id}
		*s = snapshotReply{}
		return true
	}
	return false
}
