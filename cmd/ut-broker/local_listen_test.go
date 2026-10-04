package main

import "testing"

func TestResolveLocalListenSeparatesControlPortFromTailnetPort(t *testing.T) {
	cases := []struct {
		name, explicit, listen, env, want string
	}{
		{"tsnet default follows tailnet port", "", ":8722", "", "127.0.0.1:8722"},
		{"loopback primary is reused unchanged", "", "127.0.0.1:8722", "", "127.0.0.1:8722"},
		{"env moves only the control port", "", ":8722", "8732", "127.0.0.1:8732"},
		{"native loopback primary with env", "", "127.0.0.1:8722", "8732", "127.0.0.1:8732"},
		{"explicit flag wins over env", "127.0.0.1:8742", ":8722", "8732", "127.0.0.1:8742"},
		{"ipv6 loopback", "[::1]:8742", ":8722", "", "[::1]:8742"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveLocalListen(tc.explicit, tc.listen, tc.env)
			if err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestResolveLocalListenRejectsNonLoopbackAndInvalidPorts(t *testing.T) {
	for _, tc := range []struct{ explicit, env string }{
		{"0.0.0.0:8732", ""},
		{"100.64.0.8:8732", ""},
		{"localhost:8732", ""}, // a name can resolve off-host; require a loopback IP
		{"127.0.0.1", ""},
		{"", "0"},
		{"", "70000"},
		{"", "port"},
	} {
		if got, err := resolveLocalListen(tc.explicit, ":8722", tc.env); err == nil {
			t.Errorf("resolveLocalListen(%q, env %q) = %q, want error", tc.explicit, tc.env, got)
		}
	}
}

func TestLocalPortPrefersServingBrokerThenLocalThenTailnetPort(t *testing.T) {
	defer func(previous string) { servingLocalPort = previous }(servingLocalPort)

	servingLocalPort = ""
	t.Setenv("UT_LOCAL_PORT", "")
	t.Setenv("UT_PORT", "")
	if got := localPort(); got != "8722" {
		t.Fatalf("default = %q, want 8722", got)
	}
	t.Setenv("UT_PORT", "8723")
	if got := localPort(); got != "8723" {
		t.Fatalf("UT_PORT only = %q, want 8723", got)
	}
	t.Setenv("UT_LOCAL_PORT", "8732")
	if got := localPort(); got != "8732" {
		t.Fatalf("UT_LOCAL_PORT = %q, want 8732", got)
	}
	// A running broker's own in-process clients must reach that broker, never
	// a neighbour selected by the inherited environment.
	servingLocalPort = "8742"
	if got := localBase(); got != "http://127.0.0.1:8742" {
		t.Fatalf("serving broker base = %q", got)
	}
}
