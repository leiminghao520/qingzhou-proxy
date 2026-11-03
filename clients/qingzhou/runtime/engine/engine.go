// Package engine 为桌面服务提供不经过 shell 的内嵌核心。
package engine

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	sj "github.com/sagernet/sing/common/json"
	"io"
	"net"
	"net/http"
	"qingzhou.local/httpcompat/gateway"
	"qingzhou.local/runtime/config"
	"qingzhou.local/runtime/health"
	"strings"
	"sync"
	"time"
)

type Engine struct {
	compat  *gateway.Service
	mu      sync.Mutex
	health  *health.Manager
	box     *box.Box
	cancel  context.CancelFunc
	control config.Control
	request config.Request
}

func (e *Engine) Running() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.box != nil && (e.compat == nil || !e.compat.Failed())
}
func (e *Engine) Start(raw string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.box != nil {
		return errors.New("核心已经运行")
	}
	r, err := config.Decode(raw)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return err
	}
	control := config.Control{Port: port, Secret: hex.EncodeToString(b)}
	if r.HTTPCompatibility {
		if err := config.ExtraPorts(&control, r.Port); err != nil {
			return err
		}
	}
	initial := r
	if len(health.Groups(r)) > 0 {
		initial.Capture = "systemProxy"
	}
	data, err := config.Build(initial, control)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	opts, err := sj.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		cancel()
		return stageError("核心配置解析", err)
	}
	core, err := box.New(box.Options{Context: ctx, Options: opts})
	if err != nil {
		cancel()
		return stageError("核心创建", err)
	}
	if err = core.Start(); err != nil {
		core.Close()
		cancel()
		return stageError("核心启动", err)
	}
	bootstrapCtx, bootstrapCancel := context.WithTimeout(context.Background(), 25*time.Second)
	next, manager, err := health.Bootstrap(bootstrapCtx, r, health.API{Control: control})
	bootstrapCancel()
	if err != nil {
		core.Close()
		cancel()
		return err
	}
	if len(health.Groups(r)) > 0 {
		core.Close()
		cancel()
		ctx, cancel = context.WithCancel(context.Background())
		ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
		data, err = config.Build(next, control)
		if err != nil {
			cancel()
			return err
		}
		opts, err = sj.UnmarshalExtendedContext[option.Options](ctx, data)
		if err != nil {
			cancel()
			return stageError("回退配置解析", err)
		}
		core, err = box.New(box.Options{Context: ctx, Options: opts})
		if err != nil {
			cancel()
			return stageError("回退核心创建", err)
		}
		if err = core.Start(); err != nil {
			core.Close()
			cancel()
			return stageError("回退核心启动", err)
		}
	}
	if r.HTTPCompatibility {
		raw, err := config.Gateway(next, control)
		if err != nil {
			core.Close()
			cancel()
			return err
		}
		compat, err := gateway.Start(raw)
		if err != nil {
			core.Close()
			cancel()
			return stageError("HTTP 兼容入口启动", err)
		}
		e.compat = compat
	}
	e.box = core
	e.cancel = cancel
	e.control = control
	e.request = next
	e.health = manager
	manager.Start(func() { e.Stop() })
	return nil
}
func (e *Engine) Stop() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.health != nil {
		e.health.Stop()
		e.health = nil
	}
	if e.compat != nil {
		e.compat.Close()
		e.compat = nil
	}
	if e.box == nil {
		return nil
	}
	err := e.box.Close()
	e.cancel()
	e.box = nil
	e.request = config.Request{}
	e.control = config.Control{}
	return err
}
func (e *Engine) Query(path string) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.box == nil {
		return "", errors.New("未连接")
	}
	if path != "/connections" && path != "/proxies" && path != "/version" {
		return "", errors.New("查询不支持")
	}
	return e.call("GET", path, "")
}
func (e *Engine) Select(tag string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	valid := tag == "direct" || (tag == "auto" && len(e.request.Nodes) > 0)
	for _, n := range e.request.Nodes {
		valid = valid || tag == (config.Reference{Kind: "node", ID: n.ID}).Tag()
	}
	for _, g := range e.request.Groups {
		valid = valid || tag == (config.Reference{Kind: "group", ID: g.ID}).Tag()
	}
	if !valid {
		return errors.New("策略无效")
	}
	b, _ := json.Marshal(map[string]string{"name": tag})
	_, err := e.call("PUT", "/proxies/proxy", string(b))
	return err
}
func (e *Engine) call(method, path, body string) (string, error) {
	if e.box == nil {
		return "", errors.New("未连接")
	}
	req, _ := http.NewRequest(method, fmt.Sprintf("http://127.0.0.1:%d%s", e.control.Port, path), strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+e.control.Secret)
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", errors.New("核心控制不可用")
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 4*1024*1024+1))
	if err != nil || len(b) > 4*1024*1024 || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", errors.New("核心响应无效")
	}
	if len(b) == 0 {
		return "{}", nil
	}
	return string(b), nil
}

func (e *Engine) Delay(tag string) (int64, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.box == nil {
		return 0, errors.New("代理未连接")
	}
	valid := tag == "proxy" || tag == "direct"
	for _, node := range e.request.Nodes {
		valid = valid || tag == (config.Reference{Kind: "node", ID: node.ID}).Tag()
	}
	if !valid {
		return 0, errors.New("测速节点不存在")
	}
	return (health.API{Control: e.control}).Delay(context.Background(), tag)
}

// Validate 只构造并关闭核心，不启动监听器或修改系统网络。
func Validate(raw string) error {
	r, err := config.Decode(raw)
	if err != nil {
		return err
	}
	control := config.Control{Port: 49237, Secret: strings.Repeat("0", 64)}
	if r.Port == control.Port {
		control.Port++
	}
	if r.HTTPCompatibility {
		if err = config.ExtraPorts(&control, r.Port); err != nil {
			return err
		}
	}
	data, err := config.Build(r, control)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
	opts, err := sj.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		return stageError("核心配置校验解析", err)
	}
	core, err := box.New(box.Options{Context: ctx, Options: opts})
	if err != nil {
		return stageError("核心配置校验创建", err)
	}
	return core.Close()
}

func Probe(raw string) (int64, error) {
	r, err := config.ProbeRequest(raw)
	if err != nil {
		return 0, err
	}
	data, _ := json.Marshal(r)
	var core Engine
	if err = core.Start(string(data)); err != nil {
		return 0, err
	}
	defer core.Stop()
	return core.Delay(r.Selected.Tag())
}
