package gateway

import (
	"bufio"
	"context"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func networkGateway(t *testing.T) *httptest.Server {
	t.Helper()
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, `{"mode":"global"}`) }))
	t.Cleanup(control.Close)
	// 合成核心只接受 CONNECT；普通 HTTP 测试使用下方直连传输器。
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			http.Error(w, "CONNECT required", 405)
			return
		}
		upstream, err := net.Dial("tcp", r.Host)
		if err != nil {
			http.Error(w, "unavailable", 502)
			return
		}
		client, buffer, err := w.(http.Hijacker).Hijack()
		if err != nil {
			upstream.Close()
			return
		}
		fmt.Fprint(buffer, "HTTP/1.1 200 Connection Established\r\n\r\n")
		buffer.Flush()
		relay(client, buffer, upstream, upstream)
	}))
	t.Cleanup(proxy.Close)
	c := fixture()
	fmtPort(control.URL, &c.ControlPort)
	fmtPort(proxy.URL, &c.HTTPPort)
	c.Rules = []rule{{Kind: "FINAL", Policy: "PROXY"}}
	c.Rewrites = nil
	c.General = nil
	g, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	g.transports["PROXY"] = &http.Transport{Proxy: nil}
	raw := listenTest(t)
	mixed := newMixedListener(raw, c.CorePort)
	g.connections = mixed
	srv := httptest.NewUnstartedServer(g)
	srv.Listener = mixed
	srv.Start()
	t.Cleanup(func() { mixed.Close(); srv.Close(); mixed.wait(); g.transports["PROXY"].CloseIdleConnections() })
	return srv
}
func TestAddressFamilySelection(t *testing.T) {
	ips := []netip.Addr{netip.MustParseAddr("2001:db8::1"), netip.MustParseAddr("192.0.2.1"), netip.MustParseAddr("2001:db8::2")}
	if got := orderAddresses(ips, "ipv4Only"); len(got) != 1 || !got[0].Is4() {
		t.Fatal(got)
	}
	if got := orderAddresses(ips, "preferIPv4"); len(got) != 3 || !got[0].Is4() || got[1] != ips[0] {
		t.Fatal(got)
	}
	if got := orderAddresses(ips, "dualStack"); len(got) != 3 || got[0] != ips[0] {
		t.Fatal(got)
	}
	if got := orderAddresses(ips[:1], "ipv4Only"); len(got) != 0 {
		t.Fatal(got)
	}
	g, err := prepare(fixture())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = g.pick(context.Background(), "2001:db8::1", "", "global"); !errors.Is(err, errIPv6Unavailable) {
		t.Fatal(err)
	}
	if errorCategory(err, "upstream") != "ipv6Unavailable" {
		t.Fatal(err)
	}
	g.config.AddressFamilyPolicy = "dualStack"
	if _, err = g.pick(context.Background(), "2001:db8::1", "", "global"); err != nil {
		t.Fatal(err)
	}
}
func TestStreamingFlushAndCancellation(t *testing.T) {
	cancelled := make(chan struct{})
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: first\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		close(cancelled)
	}))
	defer origin.Close()
	gateway := networkGateway(t)
	proxy, _ := url.Parse(gateway.URL)
	transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(response.Body).ReadString('\n')
	if err != nil || line != "data: first\n" {
		t.Fatal(line, err)
	}
	response.Body.Close()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("取消未传递到上游")
	}
}
func TestPlainHTTPUpgradeBufferedBytes(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !hasToken(r.Header.Get("Connection"), "upgrade") || r.Header.Get("Upgrade") != "websocket" {
			http.Error(w, "headers missing", 400)
			return
		}
		client, buffer, _ := w.(http.Hijacker).Hijack()
		defer client.Close()
		fmt.Fprint(buffer, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\npreface")
		buffer.Flush()
		data := make([]byte, 4)
		if _, err := io.ReadFull(buffer, data); err == nil {
			client.Write(data)
		}
	}))
	defer origin.Close()
	gateway := networkGateway(t)
	u, _ := url.Parse(gateway.URL)
	c, err := net.Dial("tcp", u.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(c, "GET %s/socket HTTP/1.1\r\nHost: ignored\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\nping", origin.URL)
	reader := bufio.NewReader(c)
	response, err := http.ReadResponse(reader, &http.Request{Method: "GET"})
	if err != nil || response.StatusCode != 101 {
		t.Fatal(response, err)
	}
	data := make([]byte, 11)
	if _, err = io.ReadFull(reader, data); err != nil || string(data) != "prefaceping" {
		t.Fatal(string(data), err)
	}
}
func TestHalfCloseDelayedResponse(t *testing.T) {
	client, left := pairTest(t)
	right, server := pairTest(t)
	defer client.Close()
	defer server.Close()
	done := make(chan struct{})
	go func() { relay(left, left, right, right); close(done) }()
	go func() {
		request, _ := io.ReadAll(server)
		time.Sleep(11 * time.Second)
		server.Write(append([]byte("reply:"), request...))
		server.CloseWrite()
	}()
	client.SetDeadline(time.Now().Add(15 * time.Second))
	client.Write([]byte("request"))
	client.CloseWrite()
	data, err := io.ReadAll(client)
	if err != nil || string(data) != "reply:request" {
		t.Fatal(string(data), err)
	}
	<-done
}
func TestCONNECTHTTP2(t *testing.T) { testTLSStream(t, 0) }
func TestLongTLSStream(t *testing.T) {
	value := os.Getenv("QZ_LONG_STREAM_SECONDS")
	if value == "" {
		t.Skip("显式启用十分钟持续传输验收")
	}
	seconds, err := strconv.Atoi(value)
	if err != nil || seconds < 600 {
		t.Fatal("持续传输至少600秒")
	}
	testTLSStream(t, time.Duration(seconds)*time.Second)
}
func testTLSStream(t *testing.T, duration time.Duration) {
	origin := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Error("HTTP/2 未协商")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "first\n")
		w.(http.Flusher).Flush()
		deadline := time.NewTimer(duration)
		defer deadline.Stop()
		tick := time.NewTicker(200 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-deadline.C:
				fmt.Fprint(w, "done\n")
				return
			case <-tick.C:
				if _, err := fmt.Fprint(w, "tick\n"); err != nil {
					return
				}
				w.(http.Flusher).Flush()
			case <-r.Context().Done():
				return
			}
		}
	}))
	origin.EnableHTTP2 = true
	origin.StartTLS()
	defer origin.Close()
	gateway := networkGateway(t)
	proxy, _ := url.Parse(gateway.URL)
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, ForceAttemptHTTP2: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: duration + 10*time.Second}
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.ProtoMajor != 2 {
		t.Fatal(response.Proto)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil || !strings.HasPrefix(string(body), "first\n") || !strings.HasSuffix(string(body), "done\n") {
		t.Fatal(len(body), err)
	}
}

func TestProxyDNSAddressFamilies(t *testing.T) {
	for _, policy := range []string{"ipv4Only", "preferIPv4", "dualStack"} {
		t.Run(policy, func(t *testing.T) {
			var mu sync.Mutex
			var queries []string
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				kind := r.URL.Query().Get("type")
				mu.Lock()
				queries = append(queries, kind)
				mu.Unlock()
				if r.URL.Query().Get("name") == "only-v6.example" && kind == "A" {
					io.WriteString(w, `{"Status":0,"Answer":[]}`)
					return
				}
				if kind == "A" {
					io.WriteString(w, `{"Status":0,"Answer":[{"Type":1,"Data":"192.0.2.4"}]}`)
				} else {
					io.WriteString(w, `{"Status":0,"Answer":[{"Type":28,"Data":"2001:db8::4"}]}`)
				}
			}))
			defer origin.Close()
			c := fixture()
			c.DNSPreference = "httpsProxy"
			fmtPort(origin.URL, &c.ControlPort)
			c.AddressFamilyPolicy = policy
			g, err := prepare(c)
			if err != nil {
				t.Fatal(err)
			}
			ips, err := g.resolve(context.Background(), "dual.example")
			if err != nil || len(ips) == 0 || (policy != "dualStack" && !ips[0].Is4()) {
				t.Fatal(ips, err)
			}
			mu.Lock()
			count := len(queries)
			mu.Unlock()
			if policy == "ipv4Only" && count != 1 {
				t.Fatal(queries)
			}
			if policy != "ipv4Only" && count != 2 {
				t.Fatal(queries)
			}
			_, err = g.resolve(context.Background(), "only-v6.example")
			if policy == "ipv4Only" && err == nil {
				t.Fatal("仅 AAAA 的域名不能隐式回退 IPv6")
			}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if _, err = g.resolve(ctx, "cancel.example"); err == nil {
				t.Fatal("取消未传播到 DNS")
			}
		})
	}
	for _, policy := range []string{"wrong", "ipv4-only"} {
		c := fixture()
		c.AddressFamilyPolicy = policy
		if _, err := prepare(c); err == nil {
			t.Fatal("接受了未知策略")
		}
	}
}
func TestCONNECTWebSocketFrames(t *testing.T) {
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" {
			http.Error(w, "upgrade required", 400)
			return
		}
		c, b, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer c.Close()
		digest := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
		fmt.Fprintf(b, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(digest[:]))
		b.Flush()
		frame := make([]byte, 10)
		if _, err = io.ReadFull(b, frame); err != nil {
			return
		}
		if frame[0] != 0x81 || frame[1] != 0x84 {
			t.Error("WebSocket 帧被修改")
			return
		}
		for i := 0; i < 4; i++ {
			frame[6+i] ^= frame[2+i]
		}
		c.Write(append([]byte{0x81, 4}, frame[6:]...))
	}))
	defer origin.Close()
	gateway := networkGateway(t)
	proxy, _ := url.Parse(gateway.URL)
	target, _ := url.Parse(origin.URL)
	raw, err := net.Dial("tcp", proxy.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	raw.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(raw, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target.Host, target.Host)
	reader := bufio.NewReader(raw)
	response, err := http.ReadResponse(reader, &http.Request{Method: "CONNECT"})
	if err != nil || response.StatusCode != 200 {
		t.Fatal(response, err)
	}
	c := tls.Client(&bufferedConnection{raw, reader}, &tls.Config{InsecureSkipVerify: true})
	defer c.Close()
	if err = c.Handshake(); err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(c, "GET /socket HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: c3ludGhldGljLXRlc3QhIQ==\r\n\r\n", target.Host)
	wsReader := bufio.NewReader(c)
	response, err = http.ReadResponse(wsReader, &http.Request{Method: "GET"})
	if err != nil || response.StatusCode != 101 {
		t.Fatal(response, err)
	}
	mask := []byte{1, 2, 3, 4}
	frame := []byte{0x81, 0x84, 1, 2, 3, 4}
	for i, b := range []byte("ping") {
		frame = append(frame, b^mask[i%4])
	}
	c.Write(frame)
	echo := make([]byte, 6)
	if _, err = io.ReadFull(wsReader, echo); err != nil || string(echo[2:]) != "ping" || echo[0] != 0x81 {
		t.Fatal(echo, err)
	}
}
func TestProxyDNSFailure(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { json.NewEncoder(w).Encode(map[string]any{"Status": 3}) }))
	defer origin.Close()
	c := fixture()
	fmtPort(origin.URL, &c.ControlPort)
	g, err := prepare(c)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = g.lookupProxy(context.Background(), "missing.example", "ip4"); err == nil {
		t.Fatal("DNS 失败未返回")
	}
}
