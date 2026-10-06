package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type interruptedFileBody struct{ sent bool }

func (b *interruptedFileBody) Read(p []byte) (int, error) {
	if b.sent {
		return 0, io.ErrUnexpectedEOF
	}
	b.sent = true
	return copy(p, "partial"), nil
}

func TestFileWriteRejectsIncompleteBodiesWithoutChangingDestination(t *testing.T) {
	for _, exists := range []bool{false, true} {
		for _, kind := range []string{"read-error", "length-mismatch"} {
			t.Run(fmt.Sprintf("exists=%t/%s", exists, kind), func(t *testing.T) {
				path := filepath.Join(t.TempDir(), "document.txt")
				if exists {
					if err := os.WriteFile(path, []byte("previous contents"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				var body io.Reader = &interruptedFileBody{}
				if kind == "length-mismatch" {
					body = strings.NewReader("partial")
				}
				req := httptest.NewRequest(http.MethodPost, "/fs/write?path="+url.QueryEscape(path), body)
				req.ContentLength = 100
				w := httptest.NewRecorder()
				serveFileWrite(w, req)
				if w.Code != http.StatusBadRequest {
					t.Fatalf("status %d: %s", w.Code, w.Body.String())
				}
				data, err := os.ReadFile(path)
				if exists && (err != nil || string(data) != "previous contents") {
					t.Fatalf("destination changed: %q %v", data, err)
				}
				if !exists && !os.IsNotExist(err) {
					t.Fatalf("partial destination created: %q %v", data, err)
				}
			})
		}
	}
}

func TestFileWriteSupportsCompleteAndChunkedBodies(t *testing.T) {
	for _, length := range []int64{0, 8, -1} {
		path := filepath.Join(t.TempDir(), "document.txt")
		body := "complete"
		if length == 0 {
			body = ""
		}
		req := httptest.NewRequest(http.MethodPost, "/fs/write?path="+url.QueryEscape(path), strings.NewReader(body))
		req.ContentLength = length
		w := httptest.NewRecorder()
		serveFileWrite(w, req)
		data, err := os.ReadFile(path)
		if w.Code != http.StatusOK || err != nil || string(data) != body {
			t.Fatalf("length=%d: status=%d data=%q err=%v", length, w.Code, data, err)
		}
	}
}

func TestFileWriteRejectsDisconnectedHTTPUpload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "document.txt")
	if err := os.WriteFile(path, []byte("preserved"), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(serveFileWrite))
	defer server.Close()
	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := fmt.Fprintf(conn, "POST /fs/write?path=%s HTTP/1.1\r\nHost: test\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial", url.QueryEscape(path)); err != nil {
		t.Fatal(err)
	}
	if err := conn.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status %d", response.StatusCode)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "preserved" {
		t.Fatalf("upload replaced destination: %q %v", data, err)
	}
}
