//go:build windows

// Windows 服务仅接受受限模型，所有网络操作串行执行。
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"github.com/tailscale/go-winio"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
	"golang.org/x/sys/windows/svc"
	"io"
	"net"
	"os"
	"path/filepath"
	"qingzhou.local/runtime/config"
	"qingzhou.local/runtime/engine"
	"qingzhou.local/runtime/systemproxy"
	"runtime/debug"
	"strconv"
	"sync"
	"time"
)

const pipeName = `\\.\pipe\cn.qingzhou.proxy.v1`

type owner struct {
	SID string `json:"sid"`
}
type message struct {
	Method    string `json:"method"`
	Arguments string `json:"arguments"`
}
type response struct {
	Value string `json:"value,omitempty"`
	Error string `json:"error,omitempty"`
}
type proxyValues = systemproxy.Values
type service struct {
	mu          sync.Mutex
	core        engine.Engine
	sid, dir    string
	last        time.Time
	listener    net.Listener
	recoveryErr bool
	diagnostics map[string]engine.Check
	checkedAt   string
}

func main() {
	exe, e := os.Executable()
	if e != nil {
		os.Exit(1)
	}
	dir := filepath.Dir(exe)
	if len(os.Args) == 3 && os.Args[1] == "--configure-owner" {
		sid, e := windows.StringToSid(os.Args[2])
		if e != nil || sid.String() != os.Args[2] {
			os.Exit(2)
		}
		b, _ := json.Marshal(owner{SID: os.Args[2]})
		if os.WriteFile(filepath.Join(dir, "owner.json"), b, 0600) != nil {
			os.Exit(3)
		}
		return
	}
	b, e := os.ReadFile(filepath.Join(dir, "owner.json"))
	if e != nil {
		os.Exit(4)
	}
	var o owner
	if json.Unmarshal(b, &o) != nil {
		os.Exit(5)
	}
	if _, e = windows.StringToSid(o.SID); e != nil {
		os.Exit(6)
	}
	if svc.Run("QingzhouProxy", &service{sid: o.SID, dir: dir}) != nil {
		os.Exit(7)
	}
}
func (s *service) Execute(_ []string, requests <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	if e := s.recover(); e != nil {
		s.recoveryErr = true
	}
	listener, e := winio.ListenPipe(pipeName, &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;" + s.sid + ")", MessageMode: false, InputBufferSize: 65536, OutputBufferSize: 65536})
	if e != nil {
		return false, 1
	}
	s.listener = listener
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			go s.handle(c)
		}
	}()
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case req := <-requests:
			switch req.Cmd {
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				listener.Close()
				s.mu.Lock()
				s.recoveryErr = s.recover() != nil
				s.core.Stop()
				s.mu.Unlock()
				return false, 0
			case svc.Interrogate:
				status <- req.CurrentStatus
			}
		case <-ticker.C:
			s.mu.Lock()
			if !s.core.Running() {
				if _, err := os.Stat(filepath.Join(s.dir, "recovery.json")); err == nil {
					s.recoveryErr = s.recover() != nil
				}
				// 兼容入口异常退出后也要释放核心，避免下一次连接被残留实例阻挡。
				s.core.Stop()
			}
			if s.core.Running() && time.Since(s.last) > 20*time.Second {
				s.recoveryErr = s.recover() != nil
				s.core.Stop()
			}
			s.mu.Unlock()
		}
	}
}
func (s *service) handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(40 * time.Second))
	var size uint32
	if binary.Read(c, binary.LittleEndian, &size) != nil || size > 4*1024*1024 {
		return
	}
	b := make([]byte, size)
	if _, e := io.ReadFull(c, b); e != nil {
		return
	}
	var m message
	decoder := json.NewDecoder(bytes.NewReader(b))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&m) != nil {
		return
	}
	s.mu.Lock()
	value, e := s.call(m)
	s.last = time.Now()
	s.mu.Unlock()
	reply := response{Value: value}
	if e != nil {
		reply = response{Error: e.Error()}
	}
	data, _ := json.Marshal(reply)
	if len(data) > 4*1024*1024 {
		return
	}
	binary.Write(c, binary.LittleEndian, uint32(len(data)))
	c.Write(data)
}
func (s *service) call(m message) (string, error) {
	s.last = time.Now()
	switch m.Method {
	case "capabilities":
		build := map[string]string{}
		if info, ok := debug.ReadBuildInfo(); ok {
			build["goVersion"] = info.GoVersion
			for _, setting := range info.Settings {
				if setting.Key == "vcs.revision" || setting.Key == "vcs.modified" {
					build[setting.Key] = setting.Value
				}
			}
		}
		b, _ := json.Marshal(map[string]any{"captureModes": []string{"systemProxy", "tun", "compatible"}, "coreVersion": "1.14.3", "httpCompatibility": true, "fallback": true, "diagnostics": true, "serviceBuild": build})
		return string(b), nil
	case "status":
		return s.report(false), nil
	case "validate":
		e := engine.Validate(m.Arguments)
		return "", e
	case "start":
		if s.core.Running() {
			return "", errors.New("代理已运行")
		}
		if s.recoveryErr {
			return "", errors.New("网络恢复尚未完成")
		}
		s.diagnostics = nil
		s.checkedAt = ""
		r, e := config.Decode(m.Arguments)
		if e != nil {
			return "", e
		}
		if e = s.core.Start(m.Arguments); e != nil {
			return "", e
		}
		if r.Capture != "tun" {
			if e = s.capture(r.Port); e != nil {
				s.recoveryErr = s.recover() != nil
				s.core.Stop()
				return "", e
			}
		}
		return "", nil
	case "stop", "recover":
		e := s.recover()
		s.recoveryErr = e != nil
		s.core.Stop()
		s.diagnostics = nil
		s.checkedAt = ""
		return "", e
	case "probe":
		ms, err := engine.Probe(m.Arguments)
		if err != nil {
			return "", err
		}
		b, _ := json.Marshal(map[string]int64{"milliseconds": ms})
		return string(b), nil
	case "delay":
		ms, err := s.core.Delay(m.Arguments)
		if err != nil {
			return "", err
		}
		b, _ := json.Marshal(map[string]int64{"milliseconds": ms})
		return string(b), nil
	case "query":
		if m.Arguments == "/diagnostics" {
			return s.report(true), nil
		}
		return s.core.Query(m.Arguments)
	case "select":
		err := s.core.Select(m.Arguments)
		if err == nil {
			s.diagnostics = nil
			s.checkedAt = ""
		}
		return "", err
	}
	return "", errors.New("操作不支持")
}

// report 不把内核存活当成网络检测成功；普通轮询只读取状态，不发起外网请求。
func (s *service) report(refresh bool) string {
	info := s.core.Info()
	if refresh && info.CoreRunning {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		s.diagnostics = s.core.Diagnose(ctx)
		cancel()
		s.checkedAt = time.Now().UTC().Format(time.RFC3339)
		// 后台回退检测可能在网络检查期间停止核心，响应必须反映最新状态。
		info = s.core.Info()
	}
	checks := map[string]engine.Check{
		"core":        {State: "unverified", Message: "内核未运行"},
		"listener":    {State: "unverified", Message: "尚未检查本地代理入口"},
		"registry":    {State: "unverified", Message: "当前未接管系统代理"},
		"systemProxy": {State: "unverified", Message: "等待登录用户核验系统实际代理"},
		"dns":         {State: "unverified", Message: "尚未独立验证 DNS"},
		"tls":         {State: "unverified", Message: "尚未检查目标 TLS 握手"},
		"https":       {State: "unverified", Message: "尚未检查实际 HTTPS 转发"},
		"tunRouting":  {State: "unverified", Message: "尚未独立验证 TUN 路由"},
		"tunDNS":      {State: "unverified", Message: "尚未独立验证 TUN DNS"},
	}
	state := "disconnected"
	if info.CoreRunning {
		state = "connected"
		for key, check := range s.diagnostics {
			checks[key] = check
		}
		checks["core"] = engine.Check{State: "passed", Message: "内核运行中；不代表网络已验证"}
		if info.CaptureMode != "tun" {
			key, err := s.key()
			if err != nil {
				checks["registry"] = engine.Check{State: "failed", Code: "registry_read_failed", Message: "用户代理设置读取失败"}
			} else {
				values, err := (registryStore{key}).Read()
				key.Close()
				if err == nil && values.Enable == 1 && values.Server == net.JoinHostPort("127.0.0.1", strconv.Itoa(info.ListenPort)) && values.PAC == "" {
					checks["registry"] = engine.Check{State: "passed", Message: "注册表代理指向本次监听端口"}
				} else {
					checks["registry"] = engine.Check{State: "failed", Code: "proxy_mismatch", Message: "系统代理配置与当前连接不一致"}
				}
			}
		}
	} else {
		s.checkedAt = ""
	}
	if s.recoveryErr {
		state = "recoveryRequired"
	}
	b, _ := json.Marshal(struct {
		engine.RuntimeInfo
		State       string                  `json:"state"`
		Diagnostics map[string]engine.Check `json:"diagnostics"`
		CheckedAt   string                  `json:"checkedAt,omitempty"`
	}{info, state, checks, s.checkedAt})
	return string(b)
}
func (s *service) key() (registry.Key, error) {
	return registry.OpenKey(registry.USERS, s.sid+`\Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.QUERY_VALUE|registry.SET_VALUE)
}

type registryStore struct{ k registry.Key }

func (s registryStore) Read() (proxyValues, error) {
	k := s.k
	enable, enableType, ee := k.GetIntegerValue("ProxyEnable")
	server, serverType, es := k.GetStringValue("ProxyServer")
	override, overrideType, eo := k.GetStringValue("ProxyOverride")
	pac, pacType, ep := k.GetStringValue("AutoConfigURL")
	for _, err := range []error{ee, es, eo, ep} {
		if err != nil && !errors.Is(err, registry.ErrNotExist) {
			return proxyValues{}, err
		}
	}
	if (ee == nil && enableType != registry.DWORD) ||
		(es == nil && serverType != registry.SZ) ||
		(eo == nil && overrideType != registry.SZ) ||
		(ep == nil && pacType != registry.SZ) || enable > uint64(^uint32(0)) {
		return proxyValues{}, errors.New("系统代理设置使用了不支持的注册表类型，未修改原值")
	}
	return proxyValues{Enable: uint32(enable), Server: server, Override: override, PAC: pac, EnablePresent: ee == nil, ServerPresent: es == nil, OverridePresent: eo == nil, PACPresent: ep == nil}, nil
}
func (s registryStore) Write(v proxyValues) error { return writeValues(s.k, v) }
func writeValues(k registry.Key, v proxyValues) error {
	values := []struct {
		name    string
		present bool
		value   any
	}{{"ProxyEnable", v.EnablePresent, v.Enable}, {"ProxyServer", v.ServerPresent, v.Server}, {"ProxyOverride", v.OverridePresent, v.Override}, {"AutoConfigURL", v.PACPresent, v.PAC}}
	for _, entry := range values {
		var e error
		if !entry.present {
			e = k.DeleteValue(entry.name)
			if e == registry.ErrNotExist {
				e = nil
			}
		} else if n, ok := entry.value.(uint32); ok {
			e = k.SetDWordValue(entry.name, n)
		} else {
			e = k.SetStringValue(entry.name, entry.value.(string))
		}
		if e != nil {
			return e
		}
	}
	notifyProxy()
	return nil
}
func notifyProxy() {
	dll := windows.NewLazySystemDLL("wininet.dll")
	p := dll.NewProc("InternetSetOptionW")
	p.Call(0, 39, 0, 0)
	p.Call(0, 37, 0, 0)
}
func (s *service) proxyManager(k registry.Key) systemproxy.Manager {
	return systemproxy.Manager{Registry: registryStore{k}, Journal: systemproxy.FileJournal{Path: filepath.Join(s.dir, "recovery.json")}}
}
func (s *service) capture(port int) error {
	k, err := s.key()
	if err != nil {
		return errors.New("用户网络设置不可访问")
	}
	defer k.Close()
	return s.proxyManager(k).Capture(port)
}
func (s *service) recover() error {
	path := filepath.Join(s.dir, "recovery.json")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	k, err := s.key()
	if err != nil {
		return err
	}
	defer k.Close()
	return s.proxyManager(k).Recover()
}
