package main

// Unattended Mode is broker-side, not view-side: the Mac hub keeps resolving
// Lab gates even if neither native app nor the Lab pane is open. It uses the
// existing Lab HTTP protocol, so older peer brokers and CLIs participate too.

import (
	"context"
	"encoding/json"
	"log"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"universal-tmux/internal/broker"
	"universal-tmux/internal/labsvc"
)

type labAutomationPost func(path string, q url.Values) (int, error)

type labAutomationPeer struct {
	name  string
	fetch peerFetch
	post  labAutomationPost
}

var labUnattendedSweepMu sync.Mutex

const labUnattendedInterval = 5 * time.Second

func labUnattendedLoop(ctx context.Context) {
	ticker := time.NewTicker(labUnattendedInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if broker.UnattendedMode().Enabled {
				labUnattendedSweep()
			}
		}
	}
}

func labUnattendedSweep() {
	if !broker.UnattendedMode().Enabled || !labUnattendedSweepMu.TryLock() {
		return
	}
	defer labUnattendedSweepMu.Unlock()

	seenStores := map[string]bool{}
	if store, err := labsvc.Open(); err == nil {
		seenStores["store:"+store.StoreID()] = true
		result, err := store.AutoApprovePending()
		if err != nil {
			log.Printf("unattended mode: local Lab approval sweep: %v", err)
		}
		logAutoApprovals("this machine", result.Keys, result.Proposals)
	}

	// One request stream per physical store. Babel brokers intentionally expose
	// the same NFS files, and approving a key through two nodes concurrently can
	// otherwise allocate two sets before one key write wins.
	for _, peer := range labAutomationPeers() {
		if !broker.UnattendedMode().Enabled {
			return
		}
		identity := automationStoreIdentity(peer)
		if seenStores[identity] {
			continue
		}
		seenStores[identity] = true
		keys, proposals := autoApprovePeer(peer)
		logAutoApprovals(peer.name, keys, proposals)
	}
}

func logAutoApprovals(where string, keys, proposals int) {
	if keys+proposals == 0 {
		return
	}
	log.Printf("unattended mode: auto-approved %d Lab access request(s) and %d run proposal(s) on %s",
		keys, proposals, where)
}

func labAutomationPeers() []labAutomationPeer {
	var peers []labAutomationPeer
	if override := labsvc.MirrorPeersOverride(); override != nil {
		for name, base := range override {
			base := strings.TrimRight(base, "/")
			peers = append(peers, labAutomationPeer{
				name: name, fetch: directFetcher(base), post: directAutomationPoster(base),
			})
		}
	} else {
		body, code, err := httpGet(localBase()+"/mesh/peers", 15*time.Second)
		if err != nil || code != 200 {
			return nil
		}
		var response struct {
			Peers []struct {
				Name string `json:"name"`
			} `json:"peers"`
		}
		if json.Unmarshal(body, &response) != nil {
			return nil
		}
		for _, item := range response.Peers {
			peers = append(peers, labAutomationPeer{
				name: item.Name, fetch: proxyFetcher(item.Name), post: proxyAutomationPoster(item.Name),
			})
		}
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].name < peers[j].name })
	return peers
}

func directAutomationPoster(base string) labAutomationPost {
	return func(path string, q url.Values) (int, error) {
		target := base + path
		if len(q) > 0 {
			target += "?" + q.Encode()
		}
		_, code, err := httpPost(target, nil, 8*time.Second)
		return code, err
	}
}

func proxyAutomationPoster(name string) labAutomationPost {
	return func(path string, q url.Values) (int, error) {
		mq := url.Values{"_mhost": {name}, "_mpath": {path}}
		for key, values := range q {
			for _, value := range values {
				mq.Add(key, value)
			}
		}
		_, code, err := httpPost(localBase()+"/mesh/proxy?"+mq.Encode(), nil, 10*time.Second)
		return code, err
	}
}

func automationStoreKey(machine, reported string) string {
	name := strings.TrimPrefix(strings.ToLower(strings.TrimSpace(machine)), "ut-")
	if strings.HasPrefix(name, "babel-") {
		return "shared:babel"
	}
	if id := strings.TrimSpace(reported); id != "" {
		return "store:" + id
	}
	return "machine:" + name
}

func automationStoreIdentity(peer labAutomationPeer) string {
	// Babel's node name is already a stronger identity signal than another
	// network request: every babel-* broker exposes the same NFS store. Avoid a
	// full mesh resolution for every replica on every automation sweep.
	if fallback := automationStoreKey(peer.name, ""); fallback == "shared:babel" {
		return fallback
	}
	var reported string
	if body, err := peer.fetch("/lab/notes", nil); err == nil {
		var response struct {
			Store string `json:"store"`
		}
		if json.Unmarshal(body, &response) == nil {
			reported = response.Store
		}
	}
	return automationStoreKey(peer.name, reported)
}

func autoApprovePeer(peer labAutomationPeer) (approvedKeys, approvedProposals int) {
	if body, err := peer.fetch("/lab/keys", nil); err == nil {
		var response struct {
			Keys []labsvc.Key `json:"keys"`
		}
		if json.Unmarshal(body, &response) == nil {
			for _, key := range response.Keys {
				if key.Status != "pending" || !broker.UnattendedMode().Enabled {
					continue
				}
				query := url.Values{
					"key":     {key.Key},
					"approve": {"1"},
					"note":    {labsvc.UnattendedApprovalNote},
				}
				if code, err := peer.post("/lab/decide", query); err == nil && code == 200 {
					approvedKeys++
				}
			}
		}
	}

	if body, err := peer.fetch("/lab/proposals", nil); err == nil {
		var response struct {
			Proposals []labsvc.Proposal `json:"proposals"`
		}
		if json.Unmarshal(body, &response) == nil {
			for _, proposal := range response.Proposals {
				if !broker.UnattendedMode().Enabled {
					continue
				}
				query := url.Values{
					"set":     {proposal.Set},
					"run":     {proposal.Run},
					"approve": {"1"},
					"note":    {labsvc.UnattendedApprovalNote},
				}
				if code, err := peer.post("/lab/decide-run", query); err == nil && code == 200 {
					approvedProposals++
				}
			}
		}
	}
	return
}
