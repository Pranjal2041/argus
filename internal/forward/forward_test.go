package forward

import (
	"net/url"
	"testing"
)

func TestStartViaMeshBuildsLocalBrokerRoute(t *testing.T) {
	m := NewManager()
	f, err := m.StartViaMesh(
		"ut-babel-p9-16.example.ts.net", "ut-babel-p9-16.example.ts.net", "babel-p9-16",
		"https", 5800, 0, "gym", "18722",
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { m.Stop(f.ID) })

	u, err := url.Parse(f.targetURL)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "ws" || u.Host != "127.0.0.1:18722" || u.Path != "/mesh/proxy" {
		t.Fatalf("target URL = %s", f.targetURL)
	}
	q := u.Query()
	if q.Get("_mhost") != "ut-babel-p9-16.example.ts.net" || q.Get("_mpath") != "/forward" || q.Get("port") != "5800" {
		t.Fatalf("target query = %v", q)
	}
	if got := m.Find(f.BrokerHost, f.RemotePort); got != f {
		t.Fatalf("Find() = %#v, want created forward", got)
	}
}

func TestStartViaMeshRejectsBadBrokerPort(t *testing.T) {
	m := NewManager()
	if _, err := m.StartViaMesh("host", "host", "host", "https", 5800, 0, "", "nope"); err == nil {
		t.Fatal("bad broker port was accepted")
	}
}
