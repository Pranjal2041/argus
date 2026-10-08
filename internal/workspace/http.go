package workspace

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Public collections are explicit. Runtime metadata can be read but only its
// owning broker writes it; clients cannot manufacture activity revisions.
var writableCollections = map[string]bool{
	"session-backlog": true, "session-read": true,
	"usage": true, "usage-settings": true, "usage-dismissals": true,
	"dashboards": true, "notebooks": true, "artifacts": true,
	"cc-status": true, "cc-overrides": true, "commands": true,
	"journal": true, "migrations": true,
}

func (s *Store) RegisterRoutes(mux *http.ServeMux) {
	s.registerServiceRPC(mux)
	mux.HandleFunc("/workspace/info", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodGet) {
			return
		}
		info, err := s.Info()
		reply(w, info, err)
	})
	mux.HandleFunc("/workspace/enable", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodPost) {
			return
		}
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
			http.Error(w, "workspace enrollment requires the local host", http.StatusForbidden)
			return
		}
		info, err := s.Enable()
		reply(w, info, err)
	})
	mux.HandleFunc("/workspace/snapshot", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodGet) {
			return
		}
		value, err := s.Snapshot(r.URL.Query().Get("collection"))
		reply(w, value, err)
	})
	mux.HandleFunc("/workspace/record", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodGet) {
			return
		}
		q := r.URL.Query()
		if !validKey(q.Get("collection")) || !validKey(q.Get("id")) {
			http.Error(w, "collection and id required", 400)
			return
		}
		value, err := s.Get(q.Get("collection"), q.Get("id"))
		reply(w, value, err)
	})
	mux.HandleFunc("/workspace/mutate", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodPost) {
			return
		}
		var mutation Mutation
		if !decode(w, r, &mutation, 9<<20) {
			return
		}
		if !writableCollections[mutation.Collection] {
			http.Error(w, "unsupported writable collection", 400)
			return
		}
		if err := validateMutation(mutation); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		value, err := s.Mutate(mutation)
		reply(w, value, err)
	})
	mux.HandleFunc("/workspace/changes", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodGet) {
			return
		}
		after, err := strconv.ParseUint(r.URL.Query().Get("after"), 10, 64)
		if err != nil {
			http.Error(w, "after must be an unsigned cursor", 400)
			return
		}
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
		if wait < 0 {
			wait = 0
		}
		if wait > 25 {
			wait = 25
		}
		// Subscribe before reading to avoid losing a commit between the two.
		notify := s.watch()
		page, err := s.Changes(after, limit)
		if err == nil && len(page.Records) == 0 && wait > 0 {
			timer := time.NewTimer(time.Duration(wait) * time.Second)
			defer timer.Stop()
			select {
			case <-r.Context().Done():
				return
			case <-notify:
			case <-timer.C:
			}
			page, err = s.Changes(after, limit)
		}
		reply(w, page, err)
	})
	mux.HandleFunc("/workspace/lease", func(w http.ResponseWriter, r *http.Request) {
		if !method(w, r, http.MethodPost) {
			return
		}
		var request struct {
			Name  string `json:"name"`
			Owner string `json:"owner"`
			TTL   int    `json:"ttlSeconds"`
		}
		if !decode(w, r, &request, 16384) {
			return
		}
		value, err := s.Claim(request.Name, request.Owner, time.Duration(request.TTL)*time.Second)
		reply(w, value, err)
	})
	mux.HandleFunc("/workspace/blobs/", s.blob)
}

func method(w http.ResponseWriter, r *http.Request, want string) bool {
	if r.Method == want {
		return true
	}
	w.Header().Set("Allow", want)
	http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	return false
}

func decode(w http.ResponseWriter, r *http.Request, out any, limit int64) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	d := json.NewDecoder(r.Body)
	if err := d.Decode(out); err != nil {
		http.Error(w, "invalid JSON request", 400)
		return false
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		http.Error(w, "one JSON document required", 400)
		return false
	}
	return true
}

func reply(w http.ResponseWriter, value any, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err != nil {
		status := http.StatusInternalServerError
		body := map[string]any{"error": "storage_error", "message": err.Error()}
		var conflict *Conflict
		switch {
		case errors.As(err, &conflict):
			status = 409
			body["error"] = "conflict"
			body["current"] = conflict.Current
		case errors.Is(err, ErrCursorExpired):
			status = 410
			body["error"] = "cursor_expired"
		case errors.Is(err, ErrLease):
			status = 409
			body["error"] = "lease_lost"
		case errors.Is(err, ErrMutationReuse):
			status = 409
			body["error"] = "mutation_reused"
		}
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(body)
		return
	}
	_ = json.NewEncoder(w).Encode(value)
}

func (s *Store) blob(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/workspace/blobs/")
	decoded, err := hex.DecodeString(name)
	if err != nil || len(decoded) != sha256.Size || name != strings.ToLower(name) {
		http.Error(w, "invalid content hash", 400)
		return
	}
	root := filepath.Join(s.root, "blobs")
	path := filepath.Join(root, name)
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		w.Header().Set("ETag", `"`+name+`"`)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Type", "application/octet-stream")
		http.ServeFile(w, r, path)
	case http.MethodPut:
		if err := os.MkdirAll(root, 0700); err != nil {
			reply(w, nil, err)
			return
		}
		f, err := os.CreateTemp(root, ".upload-*")
		if err != nil {
			reply(w, nil, err)
			return
		}
		tmp := f.Name()
		defer os.Remove(tmp)
		defer f.Close()
		h := sha256.New()
		r.Body = http.MaxBytesReader(w, r.Body, 128<<20)
		_, err = io.Copy(io.MultiWriter(f, h), r.Body)
		if err != nil {
			http.Error(w, "blob transfer failed or exceeds 128 MiB", 413)
			return
		}
		if hex.EncodeToString(h.Sum(nil)) != name {
			http.Error(w, "content hash mismatch", 422)
			return
		}
		if err = f.Sync(); err == nil {
			err = f.Close()
		}
		if err == nil {
			err = os.Rename(tmp, path)
		}
		reply(w, map[string]any{"hash": name}, err)
	default:
		w.Header().Set("Allow", "GET, HEAD, PUT")
		http.Error(w, "method not allowed", 405)
	}
}
