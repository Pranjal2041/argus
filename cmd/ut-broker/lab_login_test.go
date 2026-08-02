package main

import (
	"testing"
	"time"

	"universal-tmux/internal/labsvc"
)

func TestWaitForLabKeyDecisionObservesApproval(t *testing.T) {
	t.Setenv("UT_LAB_ROOT", t.TempDir())
	store, err := labsvc.Open()
	if err != nil {
		t.Fatal(err)
	}
	request, err := store.CreateKeyRequest("project", "/tmp/project", "agent")
	if err != nil {
		t.Fatal(err)
	}

	decision := make(chan error, 1)
	go func() {
		time.Sleep(20 * time.Millisecond)
		_, err := store.Decide(request.Key, true, "", labsvc.UnattendedApprovalNote)
		decision <- err
	}()

	key, err := waitForLabKeyDecision(store, request.Key, time.Second, 5*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if err := <-decision; err != nil {
		t.Fatal(err)
	}
	if key.Status != "active" || key.Set == "" || key.Note != labsvc.UnattendedApprovalNote {
		t.Fatalf("observed key = %+v, want unattended approval", key)
	}
}

func TestWaitForLabKeyDecisionReturnsPendingAtDeadline(t *testing.T) {
	t.Setenv("UT_LAB_ROOT", t.TempDir())
	store, err := labsvc.Open()
	if err != nil {
		t.Fatal(err)
	}
	request, err := store.CreateKeyRequest("project", "/tmp/project", "agent")
	if err != nil {
		t.Fatal(err)
	}

	started := time.Now()
	key, err := waitForLabKeyDecision(store, request.Key, 30*time.Millisecond, 5*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if key.Status != "pending" {
		t.Fatalf("status = %q, want pending", key.Status)
	}
	if elapsed := time.Since(started); elapsed < 25*time.Millisecond || elapsed > 500*time.Millisecond {
		t.Fatalf("wait returned after %s, want the bounded deadline", elapsed)
	}
}
