package uttsnet

import (
	"encoding/json"
	"testing"
)

func TestDiscoveryResultDistinguishesEmptySuccessFromFailure(t *testing.T) {
	for _, tc := range []struct {
		name string
		ok   bool
	}{
		{name: "success", ok: true},
		{name: "failure", ok: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got discoveryJSON
			if err := json.Unmarshal([]byte(discoveryResult(tc.ok, nil)), &got); err != nil {
				t.Fatalf("unmarshal discovery result: %v", err)
			}
			if got.OK != tc.ok {
				t.Fatalf("ok = %v, want %v", got.OK, tc.ok)
			}
			if got.Brokers == nil || len(got.Brokers) != 0 {
				t.Fatalf("brokers = %#v, want a non-nil empty array", got.Brokers)
			}
		})
	}
}
