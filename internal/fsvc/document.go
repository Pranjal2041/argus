package fsvc

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"
)

var fileWrites sync.Mutex
var ErrRevisionConflict = errors.New("file changed since it was opened; the draft has not been written")

type Document struct {
	Path     string `json:"path"`
	Text     string `json:"text"`
	Revision string `json:"revision"`
}

func contentRevision(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func ReadDocument(path string) (Document, error) {
	fileWrites.Lock()
	defer fileWrites.Unlock()
	return readDocument(path)
}

func readDocument(path string) (Document, error) {
	if strings.TrimSpace(path) == "" {
		return Document{}, errors.New("missing path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Document{}, err
	}
	f, err := os.Open(abs)
	if err != nil {
		return Document{}, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, (8<<20)+1))
	if err != nil {
		return Document{}, err
	}
	if len(data) > 8<<20 || !utf8.Valid(data) {
		return Document{}, errors.New("document is not UTF-8 text or exceeds 8 MiB")
	}
	return Document{Path: abs, Text: string(data), Revision: contentRevision(data)}, nil
}

func WriteDocument(path, revision string, data []byte) (Document, error) {
	if revision == "" {
		return Document{}, errors.New("a base file revision is required")
	}
	if len(data) > 8<<20 || !utf8.Valid(data) {
		return Document{}, errors.New("document is not UTF-8 text or exceeds 8 MiB")
	}
	fileWrites.Lock()
	defer fileWrites.Unlock()
	current, err := readDocument(path)
	if err != nil {
		return Document{}, err
	}
	if current.Revision != revision {
		if current.Revision == contentRevision(data) { return current, nil } // retry after a lost acknowledgment
		return current, ErrRevisionConflict
	}
	if err := writeFile(path, data); err != nil {
		return Document{}, err
	}
	return Document{Path: current.Path, Text: string(data), Revision: contentRevision(data)}, nil
}

// ServeDocument makes conditional save a common filesystem contract. Both
// native clients use the same content revision; neither guesses from mtime.
func ServeDocument(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	var document Document
	var err error
	switch r.Method {
	case http.MethodGet:
		document, err = ReadDocument(r.URL.Query().Get("path"))
	case http.MethodPost:
		var data []byte
		data, err = io.ReadAll(http.MaxBytesReader(w, r.Body, 8<<20))
		if err == nil {
			document, err = WriteDocument(r.URL.Query().Get("path"), strings.Trim(r.Header.Get("If-Match"), `"`), data)
		}
	default:
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", 405)
		return
	}
	if err != nil {
		code := http.StatusBadRequest
		if errors.Is(err, os.ErrNotExist) {
			code = 404
		}
		if errors.Is(err, ErrRevisionConflict) {
			code = 409
		}
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(map[string]any{"error": err.Error(), "current": document})
		return
	}
	w.Header().Set("ETag", `"`+document.Revision+`"`)
	_ = json.NewEncoder(w).Encode(document)
}
