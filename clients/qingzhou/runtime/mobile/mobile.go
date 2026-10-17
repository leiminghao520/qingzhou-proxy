// Package mobile 向平台宿主提供受限运行接口。
package mobile

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/sagernet/sing-box/experimental/libbox"
	"qingzhou.local/httpcompat/gateway"
	"qingzhou.local/runtime/config"
	"qingzhou.local/runtime/health"
)

// Host 只提供隧道和底层网络能力，不接收外部程序路径。
type Host interface {
	OpenTun(options string) (int32, error)
	ProtectSocket(fd int32) error
	Interfaces() (string, error)
	DefaultInterface() (string, error)
	IsExtension() bool
}
type Session struct {
	compat   *gateway.Service
	mu       sync.Mutex
	server   *libbox.CommandServer
	platform *platform
	control  config.Control
	client   *http.Client
	request  config.Request
	health   *health.Manager
	path     string
}

func NewSession(directory string, host Host) (*Session, error) {
	if host == nil {
		return nil, errors.New("平台宿主缺失")
	}
	if e := os.MkdirAll(directory, 0700); e != nil {
		return nil, e
	}
	os.Remove(filepath.Join(directory, "configuration.json"))
	if e := libbox.Setup(&libbox.SetupOptions{BasePath: directory, WorkingPath: directory, TempPath: filepath.Join(directory, "tmp"), LogMaxLines: 500, OomKillerEnabled: host.IsExtension(), CrashReportSource: "tunnel"}); e != nil {
		return nil, e
	}
	// 上游重定向标准错误可能包含核心诊断；目录仅允许当前应用访问。
	if e := os.Chmod(directory, 0700); e != nil {
		return nil, e
	}
	return &Session{path: directory, platform: &platform{host: host}, client: &http.Client{Timeout: 8 * time.Second}}, nil
}
func Version() string { return libbox.Version() }
func Validate(raw string) error {
	r, e := config.Decode(raw)
	if e != nil {
		return e
	}
	control := config.Control{Port: 49237, Secret: strings.Repeat("0", 64)}
	if r.Port == control.Port {
		control.Port++
	}
	if r.HTTPCompatibility {
		if e = config.ExtraPorts(&control, r.Port); e != nil {
			return e
		}
	}
	b, e := config.Build(r, control)
	if e != nil {
		return e
	}
	return libbox.CheckConfig(string(b))
}
func (s *Session) Start(raw string) error { return s.start(raw, false) }
func (s *Session) start(raw string, probe bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.server != nil {
		return errors.New("代理已经运行")
	}
	r, e := config.Decode(raw)
	if e != nil {
		return e
	}
	if !probe && r.Capture != "tun" {
		return errors.New("移动端仅支持 VPN 接管")
	}
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return e
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	secret := make([]byte, 32)
	if _, e = rand.Read(secret); e != nil {
		return e
	}
	s.control = config.Control{Port: port, Secret: hex.EncodeToString(secret)}
	if r.HTTPCompatibility {
		if err := config.ExtraPorts(&s.control, r.Port); err != nil {
			return err
		}
	}
	initial := r
	if len(health.Groups(r)) > 0 {
		initial.Capture = "systemProxy"
	}
	b, e := config.Build(initial, s.control)
	if e != nil {
		return e
	}
	if e = libbox.CheckConfig(string(b)); e != nil {
		return errors.New("核心配置校验失败")
	}
	snapshot := filepath.Join(s.path, "configuration.json")
	if e = os.WriteFile(snapshot, nil, 0600); e != nil {
		return e
	}
	defer os.Remove(snapshot)
	server, e := libbox.NewCommandServer(&handler{}, s.platform)
	if e != nil {
		return e
	}
	if e = server.StartOrReloadService(string(b), &libbox.OverrideOptions{}); e != nil {
		server.Close()
		return errors.New("核心启动失败")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	next, manager, err := health.Bootstrap(ctx, r, health.API{Control: s.control})
	cancel()
	if err != nil {
		server.Close()
		return err
	}
	if len(health.Groups(r)) > 0 {
		final, err := config.Build(next, s.control)
		if err != nil {
			server.Close()
			return err
		}
		if err = server.StartOrReloadService(string(final), &libbox.OverrideOptions{}); err != nil {
			server.Close()
			return errors.New("优先回退接管失败")
		}
	}
	s.health = manager
	if r.HTTPCompatibility {
		raw, err := config.Gateway(next, s.control)
		if err != nil {
			server.Close()
			return err
		}
		compat, err := gateway.Start(raw)
		if err != nil {
			server.Close()
			return errors.New("HTTP 兼容入口启动失败")
		}
		s.compat = compat
	}
	s.server = server
	s.request = next
	manager.Start(func() { s.Stop() })
	return nil
}
func (s *Session) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.health != nil {
		s.health.Stop()
		s.health = nil
	}
	if s.compat != nil {
		s.compat.Close()
		s.compat = nil
	}
	if s.server != nil {
		s.server.Close()
		s.server = nil
	}
	s.control = config.Control{}
	s.request = config.Request{}
	return nil
}
func (s *Session) Running() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.server != nil && (s.compat == nil || !s.compat.Failed())
}
func (s *Session) Query(path string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.server == nil {
		return "", errors.New("代理未连接")
	}
	if path != "/connections" && path != "/proxies" && path != "/version" {
		return "", errors.New("查询不支持")
	}
	req, _ := http.NewRequest("GET", fmt.Sprintf("http://127.0.0.1:%d%s", s.control.Port, path), nil)
	req.Header.Set("Authorization", "Bearer "+s.control.Secret)
	resp, e := s.client.Do(req)
	if e != nil {
		return "", errors.New("监控暂不可用")
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024+1))
	if e != nil || len(b) > 4*1024*1024 || resp.StatusCode != 200 {
		return "", errors.New("监控响应无效")
	}
	return string(b), nil
}
func (s *Session) Select(target string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.server == nil {
		return errors.New("代理未连接")
	}
	valid := target == "direct" || (target == "auto" && len(s.request.Nodes) > 0)
	for _, n := range s.request.Nodes {
		valid = valid || target == (config.Reference{Kind: "node", ID: n.ID}).Tag()
	}
	for _, g := range s.request.Groups {
		valid = valid || target == (config.Reference{Kind: "group", ID: g.ID}).Tag()
	}
	if !valid {
		return errors.New("策略不存在")
	}
	b, _ := json.Marshal(map[string]string{"name": target})
	req, _ := http.NewRequest("PUT", fmt.Sprintf("http://127.0.0.1:%d/proxies/proxy", s.control.Port), strings.NewReader(string(b)))
	req.Header.Set("Authorization", "Bearer "+s.control.Secret)
	req.Header.Set("Content-Type", "application/json")
	resp, e := s.client.Do(req)
	if e != nil {
		return errors.New("切换策略失败")
	}
	resp.Body.Close()
	if resp.StatusCode != 204 {
		return errors.New("切换策略被核心拒绝")
	}
	return nil
}
func TunnelFD() int32 { return tunnelFD() }

func (s *Session) Delay(tag string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.server == nil {
		return 0, errors.New("代理未连接")
	}
	valid := tag == "proxy" || tag == "direct"
	for _, node := range s.request.Nodes {
		valid = valid || tag == (config.Reference{Kind: "node", ID: node.ID}).Tag()
	}
	if !valid {
		return 0, errors.New("测速节点不存在")
	}
	return (health.API{Control: s.control}).Delay(context.Background(), tag)
}

// StartProbe 启动仅监听回环的测速核心，宿主结束测速后必须调用 Stop。
func (s *Session) StartProbe(raw string) error {
	r, e := config.ProbeRequest(raw)
	if e != nil {
		return e
	}
	data, e := json.Marshal(r)
	if e != nil {
		return e
	}
	return s.start(string(data), true)
}
