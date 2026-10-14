package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync"
	"testing"
	"time"
)

func TestCoreDNSHealthyFamilySurvives(t *testing.T) {
	var mu sync.Mutex
	queried := map[string]int{}
	core := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dns/query" || r.Header.Get("Authorization") != "Bearer synthetic" {
			t.Error("核心解析必须使用带认证的本地接口")
		}
		kind := r.URL.Query().Get("type")
		mu.Lock()
		queried[kind]++
		mu.Unlock()
		if kind == "AAAA" {
			http.Error(w, "synthetic", 500)
			return
		}
		fmt.Fprint(w, `{"Status":0,"Answer":[{"type":1,"data":"192.0.2.1"}]}`)
	}))
	defer core.Close()
	c := fixture()
	fmtPort(core.URL, &c.ControlPort)
	c.AddressFamilyPolicy = "preferIPv4"
	g, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	ips, err := g.resolve(context.Background(), "example.test")
	if err != nil || len(ips) != 1 || ips[0] != netip.MustParseAddr("192.0.2.1") {
		t.Fatal(ips, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if queried["A"] != 1 || queried["AAAA"] != 1 {
		t.Fatal(queried)
	}
}

func TestCoreDNSCancellationAndNoFallback(t *testing.T) {
	core := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(time.Second):
			http.Error(w, "synthetic", 500)
		}
	}))
	defer core.Close()
	c := fixture()
	fmtPort(core.URL, &c.ControlPort)
	c.AddressFamilyPolicy = "dualStack"
	g, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	start := time.Now()
	ips, err := g.resolve(ctx, "example.test")
	if err == nil || len(ips) != 0 || time.Since(start) > time.Second {
		t.Fatal(ips, err)
	}
}

func TestNoResolveDoesNotCallDNS(t *testing.T) {
	c := fixture()
	c.General = nil
	c.Rules = []rule{{Kind: "IP-CIDR", Value: "192.0.2.0/24", Policy: "DIRECT", NoResolve: true}, {Kind: "FINAL", Policy: "PROXY"}}
	g, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	g.resolve = func(context.Context, string) ([]netip.Addr, error) {
		t.Fatal("no-resolve 不得调用解析器")
		return nil, nil
	}
	policy, err := g.pick(context.Background(), "example.test", "", "rule")
	if err != nil || policy != "PROXY" {
		t.Fatal(policy, err)
	}
}
