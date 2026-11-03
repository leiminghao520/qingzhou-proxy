package engine

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"runtime"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"
)

// Check 只包含固定诊断文本，不输出节点、凭据或底层错误中的地址。
type Check struct {
	State        string `json:"state"`
	Code         string `json:"code,omitempty"`
	Message      string `json:"message"`
	Milliseconds int64  `json:"milliseconds,omitempty"`
}

type RuntimeInfo struct {
	CoreRunning bool   `json:"coreRunning"`
	CaptureMode string `json:"captureMode,omitempty"`
	ListenPort  int    `json:"listenPort,omitempty"`
}

func (e *Engine) Info() RuntimeInfo {
	e.mu.Lock()
	defer e.mu.Unlock()
	running := e.box != nil && (e.compat == nil || !e.compat.Failed())
	return RuntimeInfo{running, e.request.Capture, e.request.Port}
}

// StageError 保留可追溯的原因链，向界面只暴露错误类别和数值错误码。
type StageError struct {
	Stage, Code string
	cause       error
}

func (e *StageError) Error() string {
	message := e.Stage + "：" + errorMessage(e.Code) + "（" + e.Code
	var number syscall.Errno
	if errors.As(e.cause, &number) {
		message += fmt.Sprintf("，系统错误 %d", number)
	}
	return message + "）"
}
func (e *StageError) Unwrap() error { return e.cause }

func stageError(stage string, err error) error {
	return &StageError{Stage: stage, Code: errorCode(err), cause: err}
}

func errorCode(err error) string {
	// Windows 的 Winsock 错误码与 Go 的可移植 errno 常量并不相同。
	var number syscall.Errno
	if runtime.GOOS == "windows" && errors.As(err, &number) {
		switch number {
		case 10048:
			return "port_in_use"
		case 5, 10013:
			return "permission_denied"
		case 10061:
			return "connection_refused"
		case 10051, 10065:
			return "network_unreachable"
		case 10060:
			return "timeout"
		case 995:
			return "canceled"
		}
	}
	var dns *net.DNSError
	var unknown x509.UnknownAuthorityError
	var hostname x509.HostnameError
	var invalid x509.CertificateInvalidError
	var record tls.RecordHeaderError
	var network net.Error
	switch {
	case errors.As(err, &dns):
		return "dns_failed"
	case errors.As(err, &unknown), errors.As(err, &hostname), errors.As(err, &invalid), errors.As(err, &record):
		return "tls_failed"
	case errors.Is(err, syscall.EADDRINUSE):
		return "port_in_use"
	case errors.Is(err, syscall.EACCES), errors.Is(err, syscall.EPERM):
		return "permission_denied"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "connection_refused"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "network_unreachable"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &network) && network.Timeout():
		return "timeout"
	case errors.Is(err, context.Canceled):
		return "canceled"
	default:
		return "operation_failed"
	}
}

func errorMessage(code string) string {
	switch code {
	case "dns_failed":
		return "域名解析失败"
	case "tls_failed":
		return "TLS 握手或证书验证失败"
	case "port_in_use":
		return "监听端口已被占用"
	case "permission_denied":
		return "系统拒绝访问，请检查权限或网络防护"
	case "connection_refused":
		return "连接被拒绝"
	case "network_unreachable":
		return "目标网络不可达"
	case "timeout":
		return "请求超时"
	case "canceled":
		return "检查已取消"
	default:
		return "操作失败；无法仅凭此错误确定网络原因"
	}
}

// Diagnose 从实际混合入口发起 HTTPS 请求，不能以核心控制 API 的测速替代。
func (e *Engine) Diagnose(ctx context.Context) map[string]Check {
	info := e.Info()
	if !info.CoreRunning {
		return map[string]Check{"core": {State: "failed", Code: "not_running", Message: "内核未运行"}}
	}
	return checkProxy(ctx, info.ListenPort, "https://www.gstatic.com/generate_204", nil)
}

func checkProxy(ctx context.Context, port int, endpoint string, roots *x509.CertPool) map[string]Check {
	checks := map[string]Check{
		"core":  {State: "passed", Message: "内核运行中"},
		"dns":   {State: "unverified", Message: "代理内部解析结果不能由此请求单独归因"},
		"tls":   {State: "unverified", Message: "尚未完成目标 TLS 握手"},
		"https": {State: "unverified", Message: "尚未完成 HTTPS 检查"},
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	connection, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "tcp", address)
	if err != nil {
		checks["listener"] = Check{State: "failed", Code: errorCode(err), Message: errorMessage(errorCode(err))}
		return checks
	}
	connection.Close()
	checks["listener"] = Check{State: "passed", Message: "本地代理入口接受连接"}
	proxy := &url.URL{Scheme: "http", Host: address}
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{RootCAs: roots}, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	// 目标固定且禁止重定向，避免诊断接口成为任意地址请求入口。
	client := &http.Client{Transport: transport, Timeout: 8 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
	var tlsResult atomic.Pointer[Check]
	trace := &httptrace.ClientTrace{TLSHandshakeDone: func(_ tls.ConnectionState, err error) {
		if err == nil {
			tlsResult.Store(&Check{State: "passed", Message: "目标 TLS 证书验证通过"})
		} else {
			tlsResult.Store(&Check{State: "failed", Code: errorCode(err), Message: errorMessage(errorCode(err))})
		}
	}}
	request, err := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace), http.MethodGet, endpoint, nil)
	if err != nil {
		checks["https"] = Check{State: "failed", Code: "invalid_endpoint", Message: "诊断地址无效"}
		return checks
	}
	started := time.Now()
	response, err := client.Do(request)
	if result := tlsResult.Load(); result != nil {
		checks["tls"] = *result
	}
	if err != nil {
		code := errorCode(err)
		checks["https"] = Check{State: "failed", Code: code, Message: errorMessage(code)}
		if code == "dns_failed" {
			checks["dns"] = checks["https"]
		}
		return checks
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		checks["https"] = Check{State: "failed", Code: "unexpected_http_status", Message: fmt.Sprintf("诊断目标返回 HTTP %d", response.StatusCode)}
		return checks
	}
	checks["https"] = Check{State: "passed", Message: "经本地代理入口的 HTTPS 检查通过", Milliseconds: time.Since(started).Milliseconds()}
	return checks
}
