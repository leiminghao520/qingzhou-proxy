package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
	"time"
)

func listenTest(t *testing.T) net.Listener {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	return l
}
func dialTest(t *testing.T, address string) net.Conn {
	t.Helper()
	c, e := net.Dial("tcp", address)
	if e != nil {
		t.Fatal(e)
	}
	return c
}
func waitTest(t *testing.T, predicate func() bool) {
	t.Helper()
	end := time.Now().Add(2 * time.Second)
	for !predicate() {
		if time.Now().After(end) {
			t.Fatal("等待条件超时")
		}
		time.Sleep(time.Millisecond)
	}
}
func muxTest(t *testing.T, corePort int, handler http.Handler) (*mixedListener, string) {
	t.Helper()
	raw := listenTest(t)
	mux := newMixedListener(raw, corePort)
	server := &http.Server{Handler: handler}
	go server.Serve(mux)
	t.Cleanup(func() { server.Close(); mux.Close(); mux.wait() })
	return mux, raw.Addr().String()
}
func TestMultipleIdleSlowAndBufferedHTTP(t *testing.T) {
	_, address := muxTest(t, 1, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	idle := []net.Conn{}
	for i := 0; i < 32; i++ {
		idle = append(idle, dialTest(t, address))
	}
	defer func() {
		for _, c := range idle {
			c.Close()
		}
	}()
	c := dialTest(t, address)
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	time.Sleep(100 * time.Millisecond)
	// 一次发送多个请求，识别时预读的全部字节必须保留。
	io.WriteString(c, "GET /a HTTP/1.1\r\nHost: local\r\n\r\nGET /b HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
	reader := bufio.NewReader(c)
	for i := 0; i < 2; i++ {
		r, e := http.ReadResponse(reader, nil)
		if e != nil {
			t.Fatal(e)
		}
		r.Body.Close()
		if r.StatusCode != 204 {
			t.Fatal(r.StatusCode)
		}
	}
}
func TestSOCKSAndHTTPParallel(t *testing.T) {
	core := listenTest(t)
	defer core.Close()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		c, e := core.Accept()
		if e != nil {
			return
		}
		defer c.Close()
		io.Copy(c, c)
	}()
	_, address := muxTest(t, core.Addr().(*net.TCPAddr).Port, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	socks := dialTest(t, address)
	defer socks.Close()
	socks.SetDeadline(time.Now().Add(time.Second))
	payload := append([]byte{5}, bytes.Repeat([]byte("synthetic"), 32768)...)
	go socks.Write(payload)
	received := make([]byte, len(payload))
	if _, e := io.ReadFull(socks, received); e != nil {
		t.Fatal(e)
	}
	if !bytes.Equal(payload, received) {
		t.Fatal("SOCKS 缓冲数据丢失")
	}
	response, e := (&http.Client{Timeout: time.Second}).Get("http://" + address)
	if e != nil {
		t.Fatal(e)
	}
	response.Body.Close()
	socks.Close()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("SOCKS 隧道未取消")
	}
}
func TestIdentificationLimitAndShutdownRelease(t *testing.T) {
	raw := listenTest(t)
	address := raw.Addr().String()
	mux := newMixedListener(raw, 1)
	defer func() { mux.Close(); mux.wait() }()
	clients := []net.Conn{}
	defer func() {
		for _, c := range clients {
			c.Close()
		}
	}()
	for i := 0; i < 256; i++ {
		clients = append(clients, dialTest(t, address))
	}
	waitTest(t, func() bool { return len(mux.slots) == 256 })
	rejected := dialTest(t, address)
	defer rejected.Close()
	rejected.SetReadDeadline(time.Now().Add(time.Second))
	if _, e := rejected.Read(make([]byte, 1)); e == nil {
		t.Fatal("超出并发上限未关闭")
	} else if timed, ok := e.(net.Error); ok && timed.Timeout() {
		t.Fatal("超出并发上限仍在等待，未及时关闭")
	}
	mux.Close()
	mux.wait()
	for _, c := range clients {
		c.SetReadDeadline(time.Now().Add(time.Second))
		if _, e := c.Read(make([]byte, 1)); e == nil {
			t.Fatal("空闲连接未关闭")
		}
	}
	replacement, e := net.Listen("tcp", address)
	if e != nil {
		t.Fatal("端口未释放", e)
	}
	replacement.Close()
	if _, e := mux.Accept(); e == nil {
		t.Fatal("关闭后仍接受连接")
	}
}
func TestFirstByteTimeout(t *testing.T) {
	raw := listenTest(t)
	mux := newMixedListener(raw, 1)
	defer func() { mux.Close(); mux.wait() }()
	c := dialTest(t, raw.Addr().String())
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(12 * time.Second))
	start := time.Now()
	_, err := c.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("未关闭超时连接")
	}
	if elapsed := time.Since(start); elapsed < 9*time.Second || elapsed > 11*time.Second {
		t.Fatal(elapsed)
	}
}
func pairTest(t *testing.T) (*net.TCPConn, *net.TCPConn) {
	l := listenTest(t)
	defer l.Close()
	left := dialTest(t, l.Addr().String())
	right, e := l.Accept()
	if e != nil {
		t.Fatal(e)
	}
	return left.(*net.TCPConn), right.(*net.TCPConn)
}
func TestRelayHalfCloseAndCancellation(t *testing.T) {
	client, left := pairTest(t)
	right, server := pairTest(t)
	done := make(chan struct{})
	go func() { relay(left, left, right, right); close(done) }()
	go func(server *net.TCPConn) {
		defer server.Close()
		body, _ := io.ReadAll(server)
		time.Sleep(100 * time.Millisecond)
		server.Write(append([]byte("reply:"), body...))
		server.CloseWrite()
	}(server)
	client.SetDeadline(time.Now().Add(time.Second))
	client.Write([]byte("request"))
	client.CloseWrite()
	reply, e := io.ReadAll(client)
	client.Close()
	if e != nil || string(reply) != "reply:request" {
		t.Fatal(string(reply), e)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("半关闭转发未退出")
	}
	client, left = pairTest(t)
	right, server = pairTest(t)
	done = make(chan struct{})
	go func() { relay(left, left, right, right); close(done) }()
	client.SetLinger(0)
	client.Close()
	defer server.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("客户端取消未退出")
	}
}
func TestTLSLargeBidirectionalAndActiveShutdown(t *testing.T) {
	payload := bytes.Repeat([]byte("TLS synthetic payload"), 100000)
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, e := io.ReadAll(r.Body)
		if e != nil {
			return
		}
		w.Write(body)
	}))
	defer origin.Close()
	proxy := listenTest(t)
	defer proxy.Close()
	var tunnels sync.WaitGroup
	go func() {
		for {
			conn, e := proxy.Accept()
			if e != nil {
				return
			}
			tunnels.Add(1)
			go func() {
				defer tunnels.Done()
				defer conn.Close()
				reader := bufio.NewReader(conn)
				r, e := http.ReadRequest(reader)
				if e != nil {
					return
				}
				upstream, e := net.Dial("tcp", r.Host)
				if e != nil {
					return
				}
				defer upstream.Close()
				io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n")
				relay(conn, reader, upstream, upstream)
			}()
		}
	}()
	control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, `{"mode":"rule"}`) }))
	defer control.Close()
	config := fixture()
	config.HTTPPort = proxy.Addr().(*net.TCPAddr).Port
	fmtPort(control.URL, &config.ControlPort)
	config.Rules = []rule{{Kind: "FINAL", Policy: "DIRECT"}}
	config.General = map[string]string{}
	gateway, e := prepare(config)
	if e != nil {
		t.Fatal(e)
	}
	mux, address := muxTest(t, 1, gateway)
	gateway.connections = mux
	proxyURL, _ := url.Parse("http://" + address)
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{RootCAs: origin.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	r, e := client.Post(origin.URL, "application/octet-stream", bytes.NewReader(payload))
	if e != nil {
		t.Fatal(e)
	}
	body, e := io.ReadAll(r.Body)
	r.Body.Close()
	if e != nil || !bytes.Equal(body, payload) {
		t.Fatal("TLS 双向大数据失败", e, len(body))
	}
	tunnel := dialTest(t, address)
	defer tunnel.Close()
	tunnel.SetDeadline(time.Now().Add(time.Second))
	io.WriteString(tunnel, "CONNECT "+origin.Listener.Addr().String()+" HTTP/1.1\r\nHost: "+origin.Listener.Addr().String()+"\r\n\r\n")
	response, e := http.ReadResponse(bufio.NewReader(tunnel), nil)
	if e != nil || response.StatusCode != 200 {
		t.Fatal(e)
	}
	mux.Close()
	mux.wait()
	if _, e := tunnel.Read(make([]byte, 1)); e == nil {
		t.Fatal("活动 CONNECT 未关闭")
	}
	transport.CloseIdleConnections()
	proxy.Close()
	tunnels.Wait()
}
func TestErrorCategories(t *testing.T) {
	for _, c := range []struct {
		err  error
		want string
	}{{context.Canceled, "cancelled"}, {&net.DNSError{IsTimeout: true}, "timeout"}, {&net.DNSError{}, "dns"}, {controlStatusError(401), "auth"}, {controlStatusError(500), "control"}, {nil, "control"}} {
		if got := errorCategory(c.err, "control"); got != c.want {
			t.Fatal(got, c.want)
		}
	}
}

func TestQueuedConnectionsCloseOnShutdown(t *testing.T) {
	raw := listenTest(t)
	mux := newMixedListener(raw, 1)
	conn := dialTest(t, raw.Addr().String())
	defer conn.Close()
	io.WriteString(conn, "GET / HTTP/1.1\r\nHost: local\r\n\r\n")
	waitTest(t, func() bool { return len(mux.ready) == 1 })
	mux.Close()
	mux.wait()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("排队连接未关闭")
	} else if e, ok := err.(net.Error); ok && e.Timeout() {
		t.Fatal("排队连接清理超时")
	}
	incoming, peer := net.Pipe()
	defer peer.Close()
	if tracked, ok := mux.track(incoming); ok || tracked != nil {
		t.Fatal("关闭后接纳了上游连接")
	}
	if _, err := peer.Read(make([]byte, 1)); err == nil {
		t.Fatal("关闭后注册的连接未释放")
	}
}
