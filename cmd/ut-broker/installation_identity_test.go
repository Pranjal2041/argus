package main

import (
	"context"
	"testing"

	"tailscale.com/ipn/ipnstate"
)

func TestTailnetInstallationIdentityUsesStableID(t *testing.T) {
	status := &ipnstate.Status{Self: &ipnstate.PeerStatus{ID: "installation-a", HostName: "first", DNSName: "first.example."}}
	first, err := tailnetInstallationIdentity(status)
	if err != nil {
		t.Fatal(err)
	}
	status.Self.HostName, status.Self.DNSName = "renamed", "renamed.example."
	again, err := tailnetInstallationIdentity(status)
	if err != nil || first != again {
		t.Fatalf("rename changed identity: %q %q %v", first, again, err)
	}
	status.Self.ID = "installation-b"
	other, err := tailnetInstallationIdentity(status)
	if err != nil || first == other {
		t.Fatalf("distinct installations share identity: %q %q %v", first, other, err)
	}
}

func TestTailnetInstallationIdentityDoesNotFallbackToNames(t *testing.T) {
	for _, status := range []*ipnstate.Status{nil, {}, {Self: &ipnstate.PeerStatus{HostName: "named", DNSName: "named.example."}}} {
		if _, err := tailnetInstallationIdentity(status); err == nil {
			t.Fatal("missing stable identity accepted")
		}
	}
}

func TestLocalListenerKeepsOSIdentitySelection(t *testing.T) {
	ln, _, ts, installationID, err := listener(context.Background(), "127.0.0.1:0", "", "")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if ts != nil || installationID != "" {
		t.Fatal("local listener unexpectedly changed its identity source")
	}
}
