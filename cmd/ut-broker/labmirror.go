package main

// The Argus Lab mirror (LAB-DESIGN.md, Storage and syncing): the hub machine
// keeps a permanent copy of every lab store it can see, so records survive
// the machine that produced them going away. The Mac broker runs the loop by
// default because the Mac is the hub; UT_LAB_MIRROR=1/0 forces it on or off,
// and UT_LAB_MIRROR_PEERS substitutes fixed peers for mesh discovery in
// tests. Peers are reached through this broker's own mesh relay, so tsnet
// and IP-bound brokers work alike.

import (
	"context"
	"encoding/json"
	"net/url"
	"os"
	"runtime"
	"time"

	"universal-tmux/internal/labsvc"
)

func labMirrorEnabled() bool {
	switch os.Getenv("UT_LAB_MIRROR") {
	case "1":
		return true
	case "0":
		return false
	}
	return runtime.GOOS == "darwin"
}

// labMirrorLoop sweeps shortly after start (the listener must be up first,
// since peers are reached through our own /mesh/proxy) and then every five
// minutes.
func labMirrorLoop(ctx context.Context) {
	select {
	case <-ctx.Done():
		return
	case <-time.After(mirrorFirstDelay()):
	}
	for {
		labMirrorSweep()
		select {
		case <-ctx.Done():
			return
		case <-time.After(5 * time.Minute):
		}
	}
}

func mirrorFirstDelay() time.Duration {
	if v := os.Getenv("UT_LAB_MIRROR_DELAY"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			return d
		}
	}
	return 20 * time.Second
}

// peerFetch fetches a lab route from one peer, either directly (test
// override) or through the local mesh relay.
type peerFetch func(path string, q url.Values) ([]byte, error)

func directFetcher(base string) peerFetch {
	return func(path string, q url.Values) ([]byte, error) {
		u := base + path
		if len(q) > 0 {
			u += "?" + q.Encode()
		}
		b, _, err := httpGet(u, 15*time.Second)
		return b, err
	}
}

func proxyFetcher(name string) peerFetch {
	return func(path string, q url.Values) ([]byte, error) {
		mq := url.Values{"_mhost": {name}, "_mpath": {path}}
		for k, vs := range q {
			for _, v := range vs {
				mq.Add(k, v)
			}
		}
		b, _, err := httpGet(localBase()+"/mesh/proxy?"+mq.Encode(), 20*time.Second)
		return b, err
	}
}

func labMirrorSweep() {
	st, err := labsvc.Open()
	if err != nil {
		return
	}
	fetchers := map[string]peerFetch{}
	if override := labsvc.MirrorPeersOverride(); override != nil {
		for name, base := range override {
			fetchers[name] = directFetcher(base)
		}
	} else {
		b, code, err := httpGet(localBase()+"/mesh/peers", 30*time.Second)
		if err != nil || code != 200 {
			return
		}
		var pr struct {
			Peers []struct {
				Name string `json:"name"`
			} `json:"peers"`
		}
		if json.Unmarshal(b, &pr) != nil {
			return
		}
		for _, p := range pr.Peers {
			fetchers[p.Name] = proxyFetcher(p.Name)
		}
	}
	for _, fetch := range fetchers {
		mirrorPeer(st, fetch)
	}
}

// mirrorPeer copies one peer's sets: the latest brief (overwritten, a
// derived view) and every event not yet mirrored (append-only by id). A peer
// on an old binary without /lab routes just yields no sets.
func mirrorPeer(st *labsvc.Store, fetch peerFetch) {
	b, err := fetch("/lab/sets", nil)
	if err != nil {
		return
	}
	var sr struct {
		Sets []labsvc.SetMeta `json:"sets"`
	}
	if json.Unmarshal(b, &sr) != nil {
		return
	}
	for _, meta := range sr.Sets {
		bb, err := fetch("/lab/brief", url.Values{"set": {meta.ID}})
		if err != nil || !json.Valid(bb) {
			continue
		}
		if err := st.WriteMirrorBrief(meta.Machine, meta.ID, bb); err != nil {
			continue
		}
		mirrorEvents(st, fetch, meta.Machine, meta.ID, "")
		var br struct {
			Runs []struct {
				ID string `json:"id"`
			} `json:"runs"`
		}
		if json.Unmarshal(bb, &br) == nil {
			for _, r := range br.Runs {
				mirrorEvents(st, fetch, meta.Machine, meta.ID, r.ID)
			}
		}
	}
}

func mirrorEvents(st *labsvc.Store, fetch peerFetch, machine, set, run string) {
	q := url.Values{"set": {set}}
	if run != "" {
		q.Set("run", run)
	}
	eb, err := fetch("/lab/events", q)
	if err != nil {
		return
	}
	var er struct {
		Events []labsvc.Event `json:"events"`
	}
	if json.Unmarshal(eb, &er) != nil {
		return
	}
	_, _ = st.WriteMirrorEvents(machine, set, run, er.Events)
}
