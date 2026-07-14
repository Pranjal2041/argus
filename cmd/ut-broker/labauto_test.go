package main

import (
	"encoding/json"
	"net/url"
	"testing"

	"universal-tmux/internal/broker"
	"universal-tmux/internal/labsvc"
)

func TestAutomationStoreKeyDeduplicatesSharedStores(t *testing.T) {
	if got := automationStoreKey("babel-n5-24", "store-a"); got != "shared:babel" {
		t.Fatalf("Babel key = %q", got)
	}
	if got := automationStoreKey("ut-babel-u5-24", ""); got != "shared:babel" {
		t.Fatalf("prefixed Babel key = %q", got)
	}
	if got := automationStoreKey("worker-a", "same-store"); got != "store:same-store" {
		t.Fatalf("reported store key = %q", got)
	}
	if got := automationStoreKey("worker-a", ""); got != "machine:worker-a" {
		t.Fatalf("machine fallback = %q", got)
	}
}

func TestAutomationStoreIdentityDoesNotProbeBabelReplicas(t *testing.T) {
	called := false
	peer := labAutomationPeer{
		name: "babel-n5-24",
		fetch: func(string, url.Values) ([]byte, error) {
			called = true
			return nil, nil
		},
	}
	if got := automationStoreIdentity(peer); got != "shared:babel" {
		t.Fatalf("identity = %q", got)
	}
	if called {
		t.Fatal("Babel identity unnecessarily fetched the shared store metadata")
	}
}

func TestAutoApprovePeerPostsEveryPendingGateWithAuditNote(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	broker.SetUnattendedMode(true)

	keyBody, _ := json.Marshal(map[string]any{"keys": []labsvc.Key{
		{Key: "pending-key", Status: "pending"},
		{Key: "active-key", Status: "active"},
	}})
	proposalBody, _ := json.Marshal(map[string]any{"proposals": []labsvc.Proposal{
		{Set: "s-one", Run: "R4"},
	}})
	var posts []struct {
		path string
		q    url.Values
	}
	peer := labAutomationPeer{
		name: "worker-a",
		fetch: func(path string, _ url.Values) ([]byte, error) {
			if path == "/lab/keys" {
				return keyBody, nil
			}
			return proposalBody, nil
		},
		post: func(path string, q url.Values) (int, error) {
			posts = append(posts, struct {
				path string
				q    url.Values
			}{path, q})
			return 200, nil
		},
	}

	keys, proposals := autoApprovePeer(peer)
	if keys != 1 || proposals != 1 || len(posts) != 2 {
		t.Fatalf("approved keys=%d proposals=%d posts=%+v", keys, proposals, posts)
	}
	if posts[0].path != "/lab/decide" || posts[0].q.Get("key") != "pending-key" {
		t.Fatalf("key decision = %+v", posts[0])
	}
	if posts[1].path != "/lab/decide-run" || posts[1].q.Get("set") != "s-one" || posts[1].q.Get("run") != "R4" {
		t.Fatalf("run decision = %+v", posts[1])
	}
	for _, post := range posts {
		if post.q.Get("approve") != "1" || post.q.Get("note") != labsvc.UnattendedApprovalNote {
			t.Fatalf("missing approval audit metadata: %+v", post)
		}
	}
}
