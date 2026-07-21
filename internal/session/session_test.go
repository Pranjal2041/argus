package session

import "testing"

func TestAgentSessionExpired(t *testing.T) {
	now := int64(2_000_000_000)
	cases := []struct {
		name         string
		lastActivity int64
		finishedAt   int64
		idleSec      int
		want         bool
	}{
		{"live job is never reaped", now - MaxAgentRetentionSec - 1, 0, DefaultReapIdleSec, false},
		{"default idle window still open", now - DefaultReapIdleSec + 1, now - DefaultReapIdleSec + 1, DefaultReapIdleSec, false},
		{"default idle window expired", now - DefaultReapIdleSec, now - DefaultReapIdleSec, DefaultReapIdleSec, true},
		{"zero idle keeps a recent finished shell", now - DefaultReapIdleSec - 1, now - DefaultReapIdleSec - 1, 0, false},
		{"zero idle cannot exceed seven days", now - MaxAgentRetentionSec, now - MaxAgentRetentionSec, 0, true},
		{"recent activity cannot extend hard maximum", now, now - MaxAgentRetentionSec, DefaultReapIdleSec, true},
		{"long custom idle is capped", now - 60, now - MaxAgentRetentionSec, 30 * 24 * 3600, true},
		{"future completion timestamp is ignored", now, now + 1, DefaultReapIdleSec, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := AgentSessionExpired(now, tc.lastActivity, tc.finishedAt, tc.idleSec); got != tc.want {
				t.Fatalf("AgentSessionExpired() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAgentShellExpired(t *testing.T) {
	now := int64(2_000_000_000)
	cases := []struct {
		name         string
		lastActivity int64
		want         bool
	}{
		{"missing activity is retained", 0, false},
		{"recent shell is retained", now - MaxAgentRetentionSec + 1, false},
		{"seven idle days expires", now - MaxAgentRetentionSec, true},
		{"older shell expires", now - MaxAgentRetentionSec - 1, true},
		{"future activity is retained", now + 1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := AgentShellExpired(now, tc.lastActivity); got != tc.want {
				t.Fatalf("AgentShellExpired() = %v, want %v", got, tc.want)
			}
		})
	}
}
