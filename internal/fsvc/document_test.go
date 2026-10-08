package fsvc

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestConditionalDocumentSavePreservesConcurrentEdits(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(path, []byte("original"), 0640); err != nil {
		t.Fatal(err)
	}
	base, err := ReadDocument(path)
	if err != nil {
		t.Fatal(err)
	}
	first, err := WriteDocument(path, base.Revision, []byte("Mac edit"))
	if err != nil {
		t.Fatal(err)
	}
	current, err := WriteDocument(path, base.Revision, []byte("Android edit"))
	if !errors.Is(err, ErrRevisionConflict) || current.Revision != first.Revision {
		t.Fatalf("expected preserved conflict: %+v %v", current, err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != "Mac edit" {
		t.Fatal("stale writer replaced file")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0640 {
		t.Fatal("save changed file permissions")
	}
}

func TestOnlyOneConcurrentDocumentWriterWins(t *testing.T) {
	path := filepath.Join(t.TempDir(), "code.txt")
	_ = os.WriteFile(path, []byte("base"), 0600)
	base, _ := ReadDocument(path)
	var wg sync.WaitGroup
	var mu sync.Mutex
	successes := 0
	for _, text := range []string{"first", "second"} {
		wg.Add(1)
		go func(text string) {
			defer wg.Done()
			_, err := WriteDocument(path, base.Revision, []byte(text))
			if err == nil {
				mu.Lock()
				successes++
				mu.Unlock()
			} else if !errors.Is(err, ErrRevisionConflict) {
				t.Error(err)
			}
		}(text)
	}
	wg.Wait()
	if successes != 1 {
		t.Fatalf("successful writers = %d", successes)
	}
}
