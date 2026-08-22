package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func TestParseAPIKeyRequestHasNoDiscoveryCommand(t *testing.T) {
	if got, err := parseAPIKeyRequest([]string{"request", "daytona"}); err != nil || got != "daytona" {
		t.Fatalf("request = %q, %v", got, err)
	}
	if got, err := parseAPIKeyRequest([]string{"request", " OpenAI research "}); err != nil || got != "OpenAI research" {
		t.Fatalf("spaced request = %q, %v", got, err)
	}
	for _, args := range [][]string{{"list"}, {"request", "bad\nname"}, {"daytona"}} {
		if _, err := parseAPIKeyRequest(args); err == nil {
			t.Fatalf("parseAPIKeyRequest(%q) unexpectedly succeeded", args)
		}
	}
}

func TestDotenvVariableCatalogContainsNamesButNeverValues(t *testing.T) {
	data := []byte("# ignored\nexport OPENAI_API_KEY=sk-secret\nPORT = 8000\nnot an assignment\n")
	got := dotenvVariablesFromData(data)
	if strings.Join(got, ",") != "OPENAI_API_KEY,PORT" {
		t.Fatalf("variables = %q", got)
	}
	if strings.Contains(strings.Join(got, ","), "sk-secret") {
		t.Fatal("dotenv value escaped into variable catalog")
	}
}

func TestDotenvDetectionIsExactAndUnderstandsExport(t *testing.T) {
	data := []byte("# OPENAI_API_KEY=commented\nOPENAI_API_KEY_OLD=old\n export OPENAI_API_KEY = current\n")
	if !dotenvDataHasKey(data, "OPENAI_API_KEY") {
		t.Fatal("exact exported key was not detected")
	}
	if dotenvDataHasKey(data, "ANTHROPIC_API_KEY") {
		t.Fatal("missing key was detected")
	}
}

func TestAppendDotenvKeyPreservesFileAndDoesNotOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	original := "# project settings\nPORT=8000"
	if err := os.WriteFile(path, []byte(original), 0o640); err != nil {
		t.Fatal(err)
	}
	added, err := appendDotenvKey(path, "OPENAI_API_KEY", `sk-value with $dollar`)
	if err != nil || !added {
		t.Fatalf("append = %v, %v", added, err)
	}
	contents, _ := os.ReadFile(path)
	want := original + "\nOPENAI_API_KEY=\"sk-value with \\$dollar\"\n"
	if string(contents) != want {
		t.Fatalf("contents = %q, want %q", contents, want)
	}
	if runtime.GOOS != "windows" {
		if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o640 {
			t.Fatalf("existing permissions changed: %v, %v", info, err)
		}
	}
	added, err = appendDotenvKey(path, "OPENAI_API_KEY", "replacement")
	if err != nil || added {
		t.Fatalf("duplicate append = %v, %v", added, err)
	}
	contents, _ = os.ReadFile(path)
	if strings.Contains(string(contents), "replacement") {
		t.Fatal("existing value was overwritten")
	}
}

func TestAppendDotenvKeyCreatesPrivateFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	if added, err := appendDotenvKey(path, "OPENAI_API_KEY", "sk-private"); err != nil || !added {
		t.Fatalf("append = %v, %v", added, err)
	}
	if runtime.GOOS != "windows" {
		if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("new .env permissions = %v, %v", info, err)
		}
	}
}

func TestConcurrentDotenvWritesAddVariableOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	var wait sync.WaitGroup
	results := make(chan bool, 8)
	for range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			added, err := appendDotenvKey(path, "OPENAI_API_KEY", "sk-shared")
			if err != nil {
				t.Errorf("append: %v", err)
			}
			results <- added
		}()
	}
	wait.Wait()
	close(results)
	addedCount := 0
	for added := range results {
		if added {
			addedCount++
		}
	}
	if addedCount != 1 {
		t.Fatalf("added count = %d, want 1", addedCount)
	}
}
