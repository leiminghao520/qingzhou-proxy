package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fixture() configuration {
	return configuration{Version: 1, Secret: "synthetic", Policies: []string{"DIRECT", "PROXY"}, Rules: []rule{{Kind: "DOMAIN", Value: "direct.example", Policy: "DIRECT"}, {Kind: "USER-AGENT", Value: "Line*", Policy: "PROXY"}, {Kind: "IP-ASN", Value: "132203", Policy: "DIRECT", NoResolve: true}, {Kind: "GEOIP", Value: "CN", Policy: "DIRECT"}, {Kind: "FINAL", Policy: "PROXY"}}, Assets: map[string][]string{"IP-ASN:132203": {"192.0.2.0/24"}, "GEOIP:CN": {"198.51.100.0/24"}}, General: map[string]string{"skip-proxy": "localhost,*.tongdun.cn,10.0.0.0/8"}, Rewrites: []rewrite{{Pattern: `^http://g.cn($|/.*)`, Replacement: "https://www.google.com$1", Status: 302}}}
}
func TestOrderedPolicies(t *testing.T) {
	g, e := prepare(fixture())
	if e != nil {
		t.Fatal(e)
	}
	calls := 0
	g.resolve = func(context.Context, string) ([]netip.Addr, error) {
		calls++
		return []netip.Addr{netip.MustParseAddr("198.51.100.5")}, nil
	}
	for _, c := range []struct{ host, agent, mode, want string }{{"direct.example", "Line/1", "rule", "DIRECT"}, {"other.example", "Line/1", "rule", "PROXY"}, {"192.0.2.4", "", "rule", "DIRECT"}, {"other.example", "", "rule", "DIRECT"}, {"8.8.8.8", "", "rule", "PROXY"}, {"maven.tongdun.cn", "", "global", "PROXY"}, {"10.1.2.3", "", "global", "PROXY"}, {"else.example", "", "global", "PROXY"}, {"else.example", "", "direct", "DIRECT"}} {
		p, e := g.pick(context.Background(), c.host, c.agent, c.mode)
		if e != nil || p != c.want {
			t.Fatalf("%+v %s %v", c, p, e)
		}
	}
	if calls != 1 {
		t.Fatal(calls)
	}
}
func TestHTTPRewriteAndForward(t *testing.T) {
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer synthetic" {
			t.Error("missing auth")
		}
		io.WriteString(w, `{"mode":"rule"}`)
	}))
	defer control.Close()
	var port int
	fmtPort(control.URL, &port)
	c := fixture()
	c.ControlPort = port
	c.General["skip-proxy"] = ""
	g, e := prepare(c)
	if e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("GET", "http://g.cn/path", nil)
	w := httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 302 || w.Header().Get("Location") != "https://www.google.com/path" {
		t.Fatal(w.Code, w.Header())
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Proxy-Authorization") != "" {
			t.Error("leaked auth")
		}
		w.Header().Set("Connection", "close")
		io.WriteString(w, "forwarded")
	}))
	defer upstream.Close()
	g.transports["DIRECT"] = &http.Transport{Proxy: nil}
	g.transports["PROXY"] = &http.Transport{Proxy: nil}
	r = httptest.NewRequest("GET", upstream.URL, nil)
	r.Header.Set("Proxy-Authorization", "private")
	g.resolve = func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("198.51.100.1")}, nil
	}
	w = httptest.NewRecorder()
	g.ServeHTTP(w, r)
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != "forwarded" {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestInvalidConfig(t *testing.T) {
	for _, change := range []func(*configuration){func(c *configuration) { c.Version = 9 }, func(c *configuration) { c.Secret = "" }, func(c *configuration) { c.Rules[0].Kind = "UNKNOWN" }, func(c *configuration) { c.Rules[0].Policy = "OTHER" }, func(c *configuration) { c.Assets = nil }, func(c *configuration) { c.Rewrites[0].Pattern = "[" }, func(c *configuration) { c.Rewrites[0].Status = 200 }} {
		c := fixture()
		change(&c)
		if _, e := prepare(c); e == nil {
			t.Fatal("invalid accepted")
		}
	}
}

func fmtPort(raw string, port *int) { u, _ := url.Parse(raw); *port, _ = strconv.Atoi(u.Port()) }

func TestIdleDoesNotBlockHTTP(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	listener := newMixedListener(raw, 1)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })}
	go server.Serve(listener)
	idle, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	defer server.Close()
	time.Sleep(30 * time.Millisecond)
	client := &http.Client{Timeout: time.Second}
	response, err := client.Get("http://" + raw.Addr().String())
	if err != nil {
		t.Fatalf("空闲连接阻塞其他请求: %v", err)
	}
	response.Body.Close()
	if response.StatusCode != 204 {
		t.Fatal(response.StatusCode)
	}
}

func TestDomesticFallbackPreservesExplicitPriority(t *testing.T) {
	c := fixture()
	c.Rules = []rule{{Kind: "DOMAIN", Value: "qq.com", Policy: "PROXY"}, {Kind: "DOMAIN-SUFFIX", Value: "baidu.com", Policy: "DIRECT"}, {Kind: "DOMAIN-REGEX", Value: `^cn[0-9]+\.example$`, Policy: "DIRECT"}, {Kind: "GEOIP", Value: "CN", Policy: "DIRECT"}, {Kind: "FINAL", Policy: "PROXY"}}
	g, e := prepare(c)
	if e != nil {
		t.Fatal(e)
	}
	g.resolve = func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("203.0.113.2")}, nil
	}
	for _, item := range []struct{ host, want string }{{"qq.com", "PROXY"}, {"www.baidu.com", "DIRECT"}, {"cn12.example", "DIRECT"}, {"baidu.com.attacker.test", "PROXY"}, {"foreign.test", "PROXY"}} {
		got, e := g.pick(context.Background(), item.host, "", "rule")
		if e != nil || got != item.want {
			t.Fatalf("%s: %s %v", item.host, got, e)
		}
	}
	c.Rules[2].Value = "["
	if _, e := prepare(c); e == nil {
		t.Fatal("接受了损坏的国内正则")
	}
}
