package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

func TestAdditionalListenerRecoversWithoutInterruptingPrimary(t *testing.T) {
	for _, failure := range []string{"bind", "accept"} {
		t.Run(failure, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = io.WriteString(w, "available")
			})}
			defer server.Close()
			primary, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer primary.Close()
			go func() { _ = server.Serve(primary) }()

			failed := make(chan struct{})
			recoverNow := make(chan struct{}, 1)
			defer close(recoverNow)
			ready := make(chan net.Listener, 1)
			done := make(chan struct{})
			attempts := 0
			listen := func(network, address string) (net.Listener, error) {
				if network != "tcp" || address != "127.0.0.1:0" {
					t.Errorf("retry broadened requested endpoint: %s %s", network, address)
				}
				attempts++
				if attempts == 1 && failure == "bind" {
					close(failed)
					return nil, errors.New("interface unavailable")
				}
				if attempts > 1 {
					select {
					case <-recoverNow:
					case <-ctx.Done():
						return nil, ctx.Err()
					}
				}
				listener, err := net.Listen(network, address)
				if err == nil && attempts == 1 && failure == "accept" {
					return &failedAcceptListener{Listener: listener, failed: failed}, nil
				}
				if err == nil {
					ready <- listener
				}
				return listener, err
			}
			go func() {
				defer close(done)
				serveRecoveringListener(ctx, "127.0.0.1:0", time.Millisecond, listen, server.Serve)
			}()
			select {
			case <-failed:
			case <-time.After(3 * time.Second):
				t.Fatal("failure was not exercised")
			}
			assertListenerAvailable(t, primary.Addr())
			recoverNow <- struct{}{}
			var recovered net.Listener
			select {
			case recovered = <-ready:
			case <-time.After(3 * time.Second):
				t.Fatal("listener did not recover")
			}
			assertListenerAvailable(t, recovered.Addr())
			assertListenerAvailable(t, primary.Addr())
			cancel()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("listener did not stop on cancellation")
			}
			conn, err := net.DialTimeout("tcp", recovered.Addr().String(), time.Second)
			if err == nil {
				_ = conn.Close()
				t.Fatal("cancelled listener still accepts connections")
			}
		})
	}
}

type failedAcceptListener struct {
	net.Listener
	failed chan struct{}
}

func (l *failedAcceptListener) Accept() (net.Conn, error) {
	close(l.failed)
	return nil, errors.New("accept failed")
}

func assertListenerAvailable(t *testing.T, address net.Addr) {
	t.Helper()
	client := &http.Client{Timeout: 3 * time.Second}
	defer client.CloseIdleConnections()
	response, err := client.Get("http://" + address.String())
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != http.StatusOK || string(body) != "available" {
		t.Fatalf("listener response: status=%d body=%q err=%v", response.StatusCode, body, err)
	}
}

func TestAdditionalListenerCancelsRetryAndHonorsServerShutdown(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel-during-retry", true: "closed-server"}[shutdown], func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			var attempts atomic.Int32
			failed := make(chan struct{})
			done := make(chan struct{})
			server := &http.Server{Handler: http.NotFoundHandler()}
			_ = server.Close()
			listen := func(network, address string) (net.Listener, error) {
				attempts.Add(1)
				if shutdown {
					return net.Listen(network, address)
				}
				close(failed)
				return nil, errors.New("interface unavailable")
			}
			go func() {
				defer close(done)
				serveRecoveringListener(ctx, "127.0.0.1:0", time.Hour, listen, server.Serve)
			}()
			if !shutdown {
				select {
				case <-failed:
				case <-time.After(3 * time.Second):
					t.Fatal("bind was not attempted")
				}
				cancel()
			}
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("shutdown waited for retry delay")
			}
			if got := attempts.Load(); got != 1 {
				t.Fatalf("shutdown should not retry: got %d bind attempts", got)
			}
		})
	}
}
