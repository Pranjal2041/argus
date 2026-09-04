package main

import (
	"context"
	"errors"
	"log"
	"net"
	"net/http"
	"time"
)

// Each additional listener has its own lifecycle. A bind failure or a failed
// accept loop must not permanently remove an endpoint from a healthy broker.
// Always retry the same explicit address; never broaden to a wildcard bind.
func serveRecoveringListener(
	ctx context.Context,
	address string,
	retryDelay time.Duration,
	listen func(string, string) (net.Listener, error),
	serve func(net.Listener) error,
) {
	lastError := ""
	for ctx.Err() == nil {
		listener, err := listen("tcp", address)
		if err == nil {
			if ctx.Err() != nil {
				_ = listener.Close()
				return
			}
			log.Printf("also serving on http://%s", address)
			lastError = ""
			stop := context.AfterFunc(ctx, func() { _ = listener.Close() })
			err = serve(listener)
			stop()
			_ = listener.Close()
			if errors.Is(err, http.ErrServerClosed) {
				return
			}
		}
		if ctx.Err() != nil {
			return
		}
		message := "listener stopped"
		if err != nil {
			message = err.Error()
		}
		if message != lastError {
			log.Printf("warn: listener %s unavailable: %s; retrying every %s", address, message, retryDelay)
			lastError = message
		}
		timer := time.NewTimer(retryDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}
