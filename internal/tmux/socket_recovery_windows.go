//go:build windows

package tmux

import (
	"context"
	"fmt"
)

func recoverSocket(ctx context.Context, endpoint string) (bool, error) {
	return false, fmt.Errorf("tmux socket recovery is unavailable on Windows: %s", endpoint)
}
