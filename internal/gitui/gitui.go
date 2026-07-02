// Package gitui resolves the lazygit binary for the Git panel feature: the broker
// runs lazygit (a full terminal git UI — status, diffs, log graph, blame, checkout,
// rebase, stash) in a hidden agent session in a session's folder, and the client
// attaches to it like any terminal. lazygit is a single ~6MB static binary with no
// runtime deps beyond git itself, so the broker fetches it ONCE per host into
// UT_HOME (~/.universal-tmux — NFS-shared on the cluster, so one download serves
// every node) and reuses it forever.
package gitui

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

// Version is the pinned lazygit release. Bump deliberately; the download URL and
// asset naming are stable across releases.
const Version = "0.62.2"

// binName is the installed binary's file name inside UT_HOME.
func binName() string {
	if runtime.GOOS == "windows" {
		return "lazygit.exe"
	}
	return "lazygit"
}

// utHome is where ut keeps shared per-user state (the broker binary, the authkey).
// Mirrors the `ut` script's UT_HOME default.
func utHome() string {
	if h := os.Getenv("UT_HOME"); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = os.TempDir()
	}
	return filepath.Join(home, ".universal-tmux")
}

func isExec(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true // no exec bit on Windows; existing file is enough
	}
	return fi.Mode()&0o111 != 0
}

// Resolve returns a runnable lazygit path: $UT_LAZYGIT → PATH → UT_HOME →
// one-time download into UT_HOME. The download is the only network call and
// happens at most once per host (per version).
func Resolve() (string, error) {
	if p := os.Getenv("UT_LAZYGIT"); p != "" && isExec(p) {
		return p, nil
	}
	if p, err := exec.LookPath("lazygit"); err == nil {
		return p, nil
	}
	installed := filepath.Join(utHome(), binName())
	if isExec(installed) {
		return installed, nil
	}
	if err := download(installed); err != nil {
		return "", fmt.Errorf("lazygit not on PATH and download failed (install it or set UT_LAZYGIT): %w", err)
	}
	return installed, nil
}

// assetName maps GOOS/GOARCH to the lazygit release asset file name, e.g.
// lazygit_0.62.2_darwin_arm64.tar.gz / lazygit_0.62.2_windows_x86_64.zip.
func assetName(goos, goarch, version string) (string, error) {
	arch, ok := map[string]string{"amd64": "x86_64", "arm64": "arm64", "386": "32-bit"}[goarch]
	if !ok {
		return "", fmt.Errorf("unsupported arch %q", goarch)
	}
	switch goos {
	case "darwin", "linux", "freebsd":
		return fmt.Sprintf("lazygit_%s_%s_%s.tar.gz", version, goos, arch), nil
	case "windows":
		return fmt.Sprintf("lazygit_%s_windows_%s.zip", version, arch), nil
	}
	return "", fmt.Errorf("unsupported OS %q", goos)
}

// download fetches the pinned release asset, extracts the lazygit binary, and
// atomically installs it at dest. ~6MB; generous timeout for slow cluster egress.
func download(dest string) error {
	asset, err := assetName(runtime.GOOS, runtime.GOARCH, Version)
	if err != nil {
		return err
	}
	url := "https://github.com/jesseduffield/lazygit/releases/download/v" + Version + "/" + asset
	client := &http.Client{Timeout: 3 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("fetch %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetch %s: HTTP %d", url, resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return fmt.Errorf("read asset: %w", err)
	}
	bin, err := extract(raw, asset)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	// Write to a temp file in the same dir, then rename: atomic on POSIX, and on
	// the NFS cluster it prevents two nodes racing a partial binary into place.
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".lazygit-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(bin); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	tmp.Close()
	if err := os.Chmod(tmpName, 0o755); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, dest); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// extract pulls the lazygit binary entry out of a .tar.gz or .zip release asset.
func extract(raw []byte, asset string) ([]byte, error) {
	want := binName()
	if filepath.Ext(asset) == ".zip" {
		zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
		if err != nil {
			return nil, fmt.Errorf("zip: %w", err)
		}
		for _, f := range zr.File {
			if filepath.Base(f.Name) == want {
				rc, err := f.Open()
				if err != nil {
					return nil, err
				}
				defer rc.Close()
				return io.ReadAll(io.LimitReader(rc, 128<<20))
			}
		}
		return nil, fmt.Errorf("%s not found in %s", want, asset)
	}
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		return nil, fmt.Errorf("gzip: %w", err)
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("tar: %w", err)
		}
		if hdr.Typeflag == tar.TypeReg && filepath.Base(hdr.Name) == want {
			return io.ReadAll(io.LimitReader(tr, 128<<20))
		}
	}
	return nil, fmt.Errorf("%s not found in %s", want, asset)
}
