package labsvc

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// SnapshotCaps bound what the code snapshot archives. A file above PerFile is
// listed with its size and sha256 instead of copied, and the untracked
// archive stops growing at Total. Defaults follow LAB-DESIGN.md.
type SnapshotCaps struct{ PerFile, Total int64 }

var DefaultCaps = SnapshotCaps{PerFile: 25 << 20, Total: 200 << 20}

// SkippedFile names a file the snapshot did not archive, so the record shows
// exactly what is missing and how to recognize the right copy later.
type SkippedFile struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
	Sha  string `json:"sha256,omitempty"`
}

// Snapshot is what CaptureSnapshot records about the code state. Every git
// operation used to build it is a read (LAB-DESIGN.md rule 8): rev-parse,
// diff --binary, status --porcelain. No git object is ever written and the
// repository's index, refs, and working tree are untouched.
type Snapshot struct {
	BaseSha    string        `json:"baseSha,omitempty"`
	NoGit      bool          `json:"noGit,omitempty"`
	PatchBytes int64         `json:"patchBytes,omitempty"`
	Archived   int           `json:"archived,omitempty"`
	Skipped    []SkippedFile `json:"skipped,omitempty"`
}

func gitRO(cwd string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", append([]string{"-C", cwd, "--no-optional-locks"}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return out.Bytes(), err
}

// CaptureSnapshot records the code state of cwd into destDir: diff.patch for
// uncommitted tracked changes and untracked.tar.gz for untracked files that
// are not gitignored. A directory that is not a git repository (or has no
// commits yet) is recorded as NoGit and the run proceeds without a snapshot.
func CaptureSnapshot(cwd, destDir string, caps SnapshotCaps) (Snapshot, error) {
	var sn Snapshot
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return sn, err
	}
	sha, err := gitRO(cwd, "rev-parse", "HEAD")
	if err != nil {
		sn.NoGit = true
		return sn, nil
	}
	sn.BaseSha = strings.TrimSpace(string(sha))

	if patch, err := gitRO(cwd, "diff", "--binary", "HEAD"); err == nil && len(patch) > 0 {
		if err := os.WriteFile(filepath.Join(destDir, "diff.patch"), patch, 0o644); err != nil {
			return sn, err
		}
		sn.PatchBytes = int64(len(patch))
	}

	out, err := gitRO(cwd, "status", "--porcelain", "-z", "-uall")
	if err != nil {
		return sn, nil
	}
	var untracked []string
	for _, rec := range strings.Split(string(out), "\x00") {
		if strings.HasPrefix(rec, "?? ") {
			untracked = append(untracked, rec[3:])
		}
	}
	if len(untracked) == 0 {
		return sn, nil
	}

	tarPath := filepath.Join(destDir, "untracked.tar.gz")
	f, err := os.Create(tarPath)
	if err != nil {
		return sn, err
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	var total int64
	for _, rel := range untracked {
		full := filepath.Join(cwd, rel)
		fi, err := os.Stat(full)
		if err != nil || fi.IsDir() {
			continue
		}
		if fi.Size() > caps.PerFile || total+fi.Size() > caps.Total {
			shaStr, _ := Sha256File(full)
			sn.Skipped = append(sn.Skipped, SkippedFile{Path: rel, Size: fi.Size(), Sha: shaStr})
			continue
		}
		hdr := &tar.Header{Name: rel, Mode: 0o644, Size: fi.Size(), ModTime: fi.ModTime()}
		if err := tw.WriteHeader(hdr); err != nil {
			break
		}
		src, err := os.Open(full)
		if err != nil {
			continue
		}
		_, cpErr := io.Copy(tw, src)
		src.Close()
		if cpErr != nil {
			break
		}
		total += fi.Size()
		sn.Archived++
	}
	tw.Close()
	gz.Close()
	f.Close()
	if sn.Archived == 0 {
		os.Remove(tarPath)
	}
	return sn, nil
}

// Sha256File streams a file through sha256.
func Sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// CaptureEnv best-effort records the interpreter and package environment to
// destPath and returns small facts for the run envelope. Each probe gets a
// five second budget so a broken tool cannot stall the launch.
func CaptureEnv(cwd, destPath string) map[string]any {
	facts := map[string]any{"os": runtime.GOOS, "arch": runtime.GOARCH}
	run := func(name string, args ...string) string {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, name, args...)
		cmd.Dir = cwd
		out, err := cmd.Output()
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}
	var buf bytes.Buffer
	if v := run("python3", "--version"); v != "" {
		facts["python"] = v
		buf.WriteString(v + "\n\n")
	}
	if pkgs := run("uv", "pip", "list", "--format=freeze"); pkgs != "" {
		buf.WriteString(pkgs + "\n")
	} else if pkgs := run("python3", "-m", "pip", "list", "--format=freeze"); pkgs != "" {
		buf.WriteString(pkgs + "\n")
	}
	if g := run("nvidia-smi", "-L"); g != "" {
		facts["gpus"] = g
		buf.WriteString("\n" + g + "\n")
	}
	if buf.Len() > 0 {
		_ = os.WriteFile(destPath, buf.Bytes(), 0o644)
	}
	return facts
}
