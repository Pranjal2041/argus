//go:build !windows

package fsvc

// systemRoots is just the filesystem root on Unix-likes.
func systemRoots() []string { return []string{"/"} }
