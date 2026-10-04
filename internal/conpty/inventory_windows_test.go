//go:build windows

package conpty

import (
	"context"
	"errors"
	"testing"
)

func TestInMemoryInventoryHonorsCancellationAndRetainsIdentity(t *testing.T) {
	p := NewProvider("")
	p.sessions["restored"] = &winSession{
		name: "restored", dir: `C:\research`, lineageID: "conpty:test-lifetime",
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if list, err := p.ListInventory(ctx); !errors.Is(err, context.Canceled) || list != nil {
		t.Fatalf("cancelled inventory = %#v, %v", list, err)
	}
	list, err := p.ListInventory(context.Background())
	if err != nil || len(list) != 1 || list[0].Name != "restored" || list[0].LineageID != "conpty:test-lifetime" {
		t.Fatalf("in-memory inventory = %#v, %v", list, err)
	}
}
