package engine

import (
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"qingzhou.local/runtime/config"
	"strconv"
	"testing"
	"time"
)

func TestLoopbackHTTPSAndLifecycle(t *testing.T) {
	for _, compat := range []bool{false, true} {
		t.Run(strconv.FormatBool(compat), func(t *testing.T) { testLoopback(t, compat) })
	}
}
func testLoopback(t *testing.T, compat bool) {
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("qingzhou-loopback-ok")) }))
	defer upstream.Close()
	request := config.Request{Selected: config.Reference{Kind: "direct"}, Final: config.Reference{Kind: "direct"}, Mode: "direct", Capture: "systemProxy", DNS: "system", Port: port, Credentials: map[string]string{}}
	request.HTTPCompatibility = compat
	if compat {
		request.Compatibility = &config.Compatibility{}
	}
	raw, _ := json.Marshal(request)
	var core Engine
	if e = core.Start(string(raw)); e != nil {
		t.Fatal(e)
	}
	defer core.Stop()
	if !core.Running() {
		t.Fatal("启动状态无效")
	}
	if core.Start(string(raw)) == nil {
		t.Fatal("重复启动未拒绝")
	}
	proxy, _ := url.Parse("http://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	// 测试服务器使用临时自签名证书，仅限隔离回环测试。
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 8 * time.Second}
	resp, e := client.Get(upstream.URL)
	if e != nil {
		t.Fatal(e)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(body) != "qingzhou-loopback-ok" {
		t.Fatal("HTTPS 转发内容错误")
	}
	if _, e = core.Query("/version"); e != nil {
		t.Fatal(e)
	}
	if _, e = core.Query("/configs"); e == nil {
		t.Fatal("接受任意核心 API")
	}
	if core.Select("nonexistent") == nil {
		t.Fatal("接受未知策略")
	}
	if e = core.Stop(); e != nil {
		t.Fatal(e)
	}
	if core.Running() {
		t.Fatal("停止状态无效")
	}
	if _, e = core.Query("/version"); e == nil {
		t.Fatal("断开后仍允许监控")
	}
}
