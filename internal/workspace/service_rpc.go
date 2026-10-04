package workspace

// Private service calls are deliberately NOT mutations: credentials and login
// codes must never enter the durable record, receipt, event, or backup stores.
import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"sync"
	"time"

	bolt "go.etcd.io/bbolt"
)

type serviceCall struct {
	ID      string          `json:"id"`
	Body    json.RawMessage `json:"body"`
	reply   chan json.RawMessage
	claimed bool
	owner   string
	fence   uint64
}

func (s *Store) serviceLease(lease Lease) bool {
	valid := false
	_ = s.db.View(func(tx *bolt.Tx) error {
		var current Lease
		valid = json.Unmarshal(tx.Bucket([]byte("leases")).Get([]byte(lease.Name)), &current) == nil &&
			current.Owner == lease.Owner && current.Fence == lease.Fence && current.ExpiresAt > s.now().UnixMilli()
		return nil
	})
	return valid
}

func (s *Store) registerServiceRPC(mux *http.ServeMux) {
	var mu sync.Mutex
	calls := map[string]*serviceCall{}
	mux.HandleFunc("/workspace/service/usage", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if !method(w, r, http.MethodPost) {
			return
		}
		info, err := s.Info()
		if err != nil || !info.Enabled {
			http.Error(w, "workspace unavailable", 503)
			return
		}
		var body json.RawMessage
		if !decode(w, r, &body, 64<<10) {
			return
		}
		token := make([]byte, 16)
		if _, err := rand.Read(token); err != nil {
			http.Error(w, "request unavailable", 503)
			return
		}
		call := &serviceCall{ID: hex.EncodeToString(token), Body: body, reply: make(chan json.RawMessage, 1)}
		mu.Lock()
		if len(calls) >= 32 {
			mu.Unlock()
			http.Error(w, "collector busy", 503)
			return
		}
		calls[call.ID] = call
		mu.Unlock()
		defer func() { mu.Lock(); delete(calls, call.ID); call.Body = nil; mu.Unlock() }()
		timer := time.NewTimer(45 * time.Second)
		defer timer.Stop()
		select {
		case result := <-call.reply:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(result)
		case <-r.Context().Done():
		case <-timer.C:
			http.Error(w, "collector did not acknowledge; check connection state before retrying", 504)
		}
	})
	worker := func(w http.ResponseWriter, r *http.Request) bool {
		w.Header().Set("Cache-Control", "no-store")
		if !method(w, r, http.MethodPost) {
			return false
		}
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			http.Error(w, "local collector required", 403)
			return false
		}
		return true
	}
	mux.HandleFunc("/workspace/service/usage/take", func(w http.ResponseWriter, r *http.Request) {
		if !worker(w, r) {
			return
		}
		var lease Lease
		if !decode(w, r, &lease, 4096) {
			return
		}
		if lease.Name != "usage" || !s.serviceLease(lease) {
			http.Error(w, "collector lease lost", 409)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		for _, call := range calls {
			if !call.claimed {
				call.claimed = true
				call.owner = lease.Owner
				call.fence = lease.Fence
				reply(w, call, nil)
				call.Body = nil // No retained copy after delivery to the collector.
				return
			}
		}
		reply(w, map[string]any{}, nil)
	})
	mux.HandleFunc("/workspace/service/usage/reply", func(w http.ResponseWriter, r *http.Request) {
		if !worker(w, r) {
			return
		}
		var result struct {
			ID    string          `json:"id"`
			Lease Lease           `json:"lease"`
			Body  json.RawMessage `json:"body"`
		}
		if !decode(w, r, &result, 256<<10) {
			return
		}
		if result.Lease.Name != "usage" || !s.serviceLease(result.Lease) {
			http.Error(w, "collector lease lost", 409)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		call := calls[result.ID]
		if call == nil {
			http.Error(w, "request expired", 410)
			return
		}
		if !call.claimed || call.owner != result.Lease.Owner || call.fence != result.Lease.Fence {
			http.Error(w, "request owner changed", 409)
			return
		}
		select {
		case call.reply <- result.Body:
		default:
		}
		reply(w, map[string]bool{"ok": true}, nil)
	})
}
