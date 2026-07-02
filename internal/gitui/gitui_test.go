package gitui

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestAssetName(t *testing.T) {
	cases := []struct {
		goos, goarch, want string
	}{
		{"darwin", "arm64", "lazygit_0.62.2_darwin_arm64.tar.gz"},
		{"darwin", "amd64", "lazygit_0.62.2_darwin_x86_64.tar.gz"},
		{"linux", "amd64", "lazygit_0.62.2_linux_x86_64.tar.gz"},
		{"windows", "amd64", "lazygit_0.62.2_windows_x86_64.zip"},
		{"windows", "arm64", "lazygit_0.62.2_windows_arm64.zip"},
	}
	for _, c := range cases {
		got, err := assetName(c.goos, c.goarch, "0.62.2")
		if err != nil || got != c.want {
			t.Errorf("assetName(%s,%s) = %q, %v; want %q", c.goos, c.goarch, got, err, c.want)
		}
	}
	if _, err := assetName("plan9", "amd64", "0.62.2"); err == nil {
		t.Error("expected error for unsupported OS")
	}
}

// TestExtractTarGz round-trips a synthetic release tarball.
func TestExtractTarGz(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("tar asset applies to unix")
	}
	payload := []byte("#!/bin/sh\necho fake-lazygit\n")
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	// a stray file first, then the binary — extract must pick the right entry
	_ = tw.WriteHeader(&tar.Header{Name: "LICENSE", Mode: 0o644, Size: 3, Typeflag: tar.TypeReg})
	_, _ = tw.Write([]byte("MIT"))
	_ = tw.WriteHeader(&tar.Header{Name: "lazygit", Mode: 0o755, Size: int64(len(payload)), Typeflag: tar.TypeReg})
	_, _ = tw.Write(payload)
	tw.Close()
	gz.Close()

	got, err := extract(buf.Bytes(), "lazygit_0.62.2_linux_x86_64.tar.gz")
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("extracted %d bytes, want %d", len(got), len(payload))
	}
}

// TestExtractZip round-trips a synthetic windows asset.
func TestExtractZip(t *testing.T) {
	payload := []byte("MZfake")
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w1, _ := zw.Create("LICENSE")
	_, _ = w1.Write([]byte("MIT"))
	name := "lazygit"
	if runtime.GOOS == "windows" {
		name = "lazygit.exe"
	}
	w2, _ := zw.Create(name)
	_, _ = w2.Write(payload)
	zw.Close()

	got, err := extract(buf.Bytes(), "lazygit_0.62.2_windows_x86_64.zip")
	if err != nil {
		t.Fatalf("extract: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Errorf("extracted %q, want %q", got, payload)
	}
}

// TestResolveOrder: UT_LAZYGIT env wins, then an installed UT_HOME binary —
// without hitting the network.
func TestResolveOrder(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("exec-bit semantics differ")
	}
	dir := t.TempDir()

	// 1. env override wins
	envBin := filepath.Join(dir, "custom-lazygit")
	if err := os.WriteFile(envBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("UT_LAZYGIT", envBin)
	t.Setenv("UT_HOME", filepath.Join(dir, "uthome"))
	t.Setenv("PATH", dir) // no real lazygit findable
	if got, err := Resolve(); err != nil || got != envBin {
		t.Fatalf("Resolve with env = %q, %v; want %q", got, err, envBin)
	}

	// 2. UT_HOME install found when env unset
	t.Setenv("UT_LAZYGIT", "")
	home := filepath.Join(dir, "uthome")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	installed := filepath.Join(home, "lazygit")
	if err := os.WriteFile(installed, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, err := Resolve(); err != nil || got != installed {
		t.Fatalf("Resolve with UT_HOME = %q, %v; want %q", got, err, installed)
	}
}
