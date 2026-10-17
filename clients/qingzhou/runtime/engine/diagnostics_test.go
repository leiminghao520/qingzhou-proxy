package engine

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"qingzhou.local/runtime/config"
	"strings"
	"syscall"
	"testing"
)

func TestHTTPSDiagnosticsUseActualProxyEntry(t *testing.T) {
	for _, compat := range []bool{false, true} {
		t.Run(fmt.Sprint(compat), func(t *testing.T) {
			upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
			defer upstream.Close()
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			port := listener.Addr().(*net.TCPAddr).Port
			listener.Close()
			request := config.Request{Selected: config.Reference{Kind: "direct"}, Final: config.Reference{Kind: "direct"}, Mode: "direct", Capture: "systemProxy", DNS: "system", Port: port, Credentials: map[string]string{}, HTTPCompatibility: compat}
			if compat {
				request.Compatibility = &config.Compatibility{}
			}
			raw, _ := json.Marshal(request)
			var core Engine
			if err := core.Start(string(raw)); err != nil {
				t.Fatal(err)
			}
			defer core.Stop()
			roots := x509.NewCertPool()
			roots.AddCert(upstream.Certificate())
			checks := checkProxy(context.Background(), port, upstream.URL, roots)
			for _, stage := range []string{"listener", "tls", "https"} {
				if checks[stage].State != "passed" {
					t.Fatalf("%s: %+v", stage, checks[stage])
				}
			}
			if checks["dns"].State != "unverified" {
				t.Fatal("错误地宣称验证代理内部 DNS")
			}
			checks = checkProxy(context.Background(), port, upstream.URL, nil)
			if checks["tls"].State != "failed" || checks["https"].Code != "tls_failed" {
				t.Fatalf("不可信证书未归因: %+v", checks)
			}
			if err := core.Stop(); err != nil {
				t.Fatal(err)
			}
			checks = checkProxy(context.Background(), port, upstream.URL, roots)
			if checks["listener"].State != "failed" || checks["https"].State != "unverified" {
				t.Fatal("入口关闭仍宣称连通", checks)
			}
		})
	}
}

func TestDiagnosticsNeverTreatHTTPErrorAsSuccess(t *testing.T) {
	// 此代理只返回错误，不连接任何真实外部地址。
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusBadGateway) }))
	defer proxy.Close()
	_, portText, _ := net.SplitHostPort(strings.TrimPrefix(proxy.URL, "http://"))
	port := 0
	fmt.Sscan(portText, &port)
	checks := checkProxy(context.Background(), port, "https://example.invalid/", nil)
	if checks["listener"].State != "passed" || checks["https"].State != "failed" {
		t.Fatal(checks)
	}
	var core Engine
	if core.Diagnose(context.Background())["core"].State != "failed" {
		t.Fatal("未启动却通过检查")
	}
}

func TestOccupiedPortHasSafeActionableError(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	request := config.Request{Selected: config.Reference{Kind: "direct"}, Final: config.Reference{Kind: "direct"}, Mode: "direct", Capture: "systemProxy", DNS: "system", Port: listener.Addr().(*net.TCPAddr).Port, Credentials: map[string]string{}}
	raw, _ := json.Marshal(request)
	var core Engine
	err = core.Start(string(raw))
	defer core.Stop()
	var staged *StageError
	if !errors.As(err, &staged) || staged.Code != "port_in_use" || core.Running() {
		t.Fatal("端口占用未准确上报或清理", err)
	}
}

func TestErrorClassificationDoesNotExposeTarget(t *testing.T) {
	for _, item := range []struct {
		err  error
		code string
	}{
		{&net.DNSError{Name: "secret-node.example", Err: "private-password"}, "dns_failed"},
		{fmt.Errorf("private-password: %w", syscall.ECONNREFUSED), "connection_refused"},
		{syscall.EACCES, "permission_denied"},
		{context.DeadlineExceeded, "timeout"},
		{errors.New("https://private:password@secret-node.example/subscription"), "operation_failed"},
	} {
		err := stageError("连接检查", item.err)
		if errorCode(item.err) != item.code || !errors.Is(err, item.err) {
			t.Fatal(item.code, err)
		}
		for _, secret := range []string{"secret-node", "private-password", "subscription", "password@"} {
			if strings.Contains(err.Error(), secret) {
				t.Fatal("诊断泄露敏感字段", err)
			}
		}
	}
}
