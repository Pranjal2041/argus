package tmux

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func inventoryToolFixture(t *testing.T, script string) *Provider {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("tmux is a Unix backend")
	}
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte("#!/bin/sh\n"+script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	return NewProvider("inventory-test")
}

func TestInventoryToolFailureIsNotAnEmptyWorkspace(t *testing.T) {
	p := inventoryToolFixture(t, "echo 'backend temporarily unavailable' >&2\nexit 42\n")
	list, err := p.ListInventory(context.Background())
	if err == nil || list != nil {
		t.Fatalf("failed backend returned a successful empty workspace: %#v, %v", list, err)
	}
}

func TestInventoryToolHonorsCallerDeadline(t *testing.T) {
	p := inventoryToolFixture(t, "exec /bin/sleep 30\n")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := p.ListInventory(ctx); err == nil {
		t.Fatal("expected timed-out inventory read")
	}
	if time.Since(start) > time.Second {
		t.Fatal("inventory tool ignored the caller's deadline")
	}
}

func TestInventoryMissingServerIsAuthoritativeEmptyWorkspace(t *testing.T) {
	p := inventoryToolFixture(t, "echo 'no server running on /tmp/test-socket' >&2\nexit 1\n")
	list, err := p.ListInventory(context.Background())
	if err != nil || len(list) != 0 {
		t.Fatalf("missing server = %#v, %v", list, err)
	}
}

func TestInventoryFindsExplicitlyConfiguredTool(t *testing.T) {
	p := inventoryToolFixture(t, "printf 'restored\\t1\\t0\\t1\\t/project\\t$2\\ttmux:1:2:$2\\t\\t1\\n'\n")
	list, err := p.ListInventory(context.Background())
	if err != nil || len(list) != 1 || list[0].Name != "restored" || list[0].Agent {
		t.Fatalf("custom PATH tool inventory = %#v, %v", list, err)
	}
	if !strings.HasPrefix(list[0].LineageID, "tmux:") {
		t.Fatal("inventory lost session lineage")
	}
}
