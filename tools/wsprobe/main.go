package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/coder/websocket"
)

func main() {
	url := os.Args[1]
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cl := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	t0 := time.Now()
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{HTTPClient: cl})
	if err != nil {
		fmt.Println("DIAL ERR:", err)
		return
	}
	defer c.Close(websocket.StatusNormalClosure, "")
	c.SetReadLimit(64 << 20)
	rctx, rcancel := context.WithTimeout(context.Background(), 8*time.Second)
	_, data, rerr := c.Read(rctx)
	rcancel()
	if rerr != nil {
		fmt.Printf("dial %v, NO FRAMES in 8s\n", time.Since(t0).Round(time.Millisecond))
		return
	}
	fmt.Printf("dial+first-frame %v (%dB)\n", time.Since(t0).Round(time.Millisecond), len(data))
}
