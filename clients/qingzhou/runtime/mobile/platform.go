package mobile

import (
	"encoding/json"
	"errors"
	"github.com/sagernet/sing-box/experimental/libbox"
	"net"
	"qingzhou.local/runtime/config"
	"sync"
	"time"
)

type platform struct {
	host Host
	mu   sync.Mutex
	stop chan struct{}
}

func (p *platform) LocalDNSTransport() libbox.LocalDNSTransport { return nil }
func (p *platform) UsePlatformAutoDetectInterfaceControl() bool { return true }
func (p *platform) AutoDetectInterfaceControl(fd int32) error   { return p.host.ProtectSocket(fd) }
func (p *platform) OpenTun(o libbox.TunOptions) (int32, error) {
	prefixes := func(it libbox.RoutePrefixIterator) []string {
		v := []string{}
		for it.HasNext() {
			v = append(v, it.Next().String())
		}
		return v
	}
	dns, e := o.GetDNSServerAddress()
	if e != nil {
		return -1, e
	}
	servers := []string{}
	for dns.HasNext() {
		servers = append(servers, dns.Next())
	}
	routes := append(prefixes(o.GetInet4RouteRange()), prefixes(o.GetInet6RouteRange())...)
	excludes := append(prefixes(o.GetInet4RouteExcludeAddress()), prefixes(o.GetInet6RouteExcludeAddress())...)
	if len(routes) == 0 {
		routes = []string{"0.0.0.0/0"}
		if o.GetInet6Address().HasNext() {
			routes = append(routes, "::/0")
		}
	}
	routes, e = config.RouteComplement(routes, excludes)
	if e != nil {
		return -1, e
	}
	if len(routes) == 0 {
		return -1, errors.New("接管范围为空")
	}
	b, e := json.Marshal(map[string]any{"mtu": o.GetMTU(), "addresses": append(prefixes(o.GetInet4Address()), prefixes(o.GetInet6Address())...), "routes": routes, "excludes": []string{}, "dns": servers, "httpProxy": o.IsHTTPProxyEnabled(), "httpPort": func() int32 {
		if o.IsHTTPProxyEnabled() {
			return o.GetHTTPProxyServerPort()
		}
		return 0
	}()})
	if e != nil {
		return -1, e
	}
	return p.host.OpenTun(string(b))
}
func (p *platform) UseProcFS() bool { return false }
func (p *platform) FindConnectionOwner(int32, string, int32, string, int32) (*libbox.ConnectionOwner, error) {
	return nil, errors.New("进程归属不可用")
}
func (p *platform) StartDefaultInterfaceMonitor(l libbox.InterfaceUpdateListener) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stop != nil {
		return errors.New("网络监控已启动")
	}
	p.stop = make(chan struct{})
	stop := p.stop
	update := func() {
		raw, e := p.host.DefaultInterface()
		if e != nil {
			return
		}
		var v struct {
			Name        string
			Index       int32
			Expensive   bool
			Constrained bool
		}
		if json.Unmarshal([]byte(raw), &v) == nil {
			l.UpdateDefaultInterface(v.Name, v.Index, v.Expensive, v.Constrained)
		}
	}
	update()
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		last := ""
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				raw, e := p.host.DefaultInterface()
				if e == nil && raw != last {
					last = raw
					update()
				}
			}
		}
	}()
	return nil
}
func (p *platform) CloseDefaultInterfaceMonitor(libbox.InterfaceUpdateListener) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.stop != nil {
		close(p.stop)
		p.stop = nil
	}
	return nil
}

type stringsIterator struct {
	v []string
	i int
}

func (s *stringsIterator) Len() int32    { return int32(len(s.v)) }
func (s *stringsIterator) HasNext() bool { return s.i < len(s.v) }
func (s *stringsIterator) Next() string  { v := s.v[s.i]; s.i++; return v }

type interfaceIterator struct {
	v []*libbox.NetworkInterface
	i int
}

func (s *interfaceIterator) HasNext() bool                  { return s.i < len(s.v) }
func (s *interfaceIterator) Next() *libbox.NetworkInterface { v := s.v[s.i]; s.i++; return v }
func (p *platform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) {
	raw, e := p.host.Interfaces()
	if e != nil {
		return nil, e
	}
	var entries []struct {
		Name      string
		Index     int32
		MTU       int32
		Addresses []string
		DNS       []string
		Type      int32
		Metered   bool
	}
	if e = json.Unmarshal([]byte(raw), &entries); e != nil {
		return nil, e
	}
	it := &interfaceIterator{}
	for _, v := range entries {
		it.v = append(it.v, &libbox.NetworkInterface{Name: v.Name, Index: v.Index, MTU: v.MTU, Addresses: &stringsIterator{v: v.Addresses}, DNSServer: &stringsIterator{v: v.DNS}, Flags: int32(net.FlagUp | net.FlagRunning | net.FlagMulticast), Type: v.Type, Metered: v.Metered})
	}
	return it, nil
}
func (p *platform) UnderNetworkExtension() bool      { return p.host.IsExtension() }
func (p *platform) IncludeAllNetworks() bool         { return false }
func (p *platform) ReadWIFIState() *libbox.WIFIState { return nil }
func (p *platform) ClearDNSCache()                   {}
func (p *platform) SendNotification(*libbox.Notification) error {
	return errors.New("核心通知不可用")
}
func (p *platform) CancelNotification(string, int32) error { return nil }
func (p *platform) StartNeighborMonitor(libbox.NeighborUpdateListener) error {
	return errors.New("邻居监控不可用")
}
func (p *platform) CloseNeighborMonitor(libbox.NeighborUpdateListener) error { return nil }
func (p *platform) RegisterMyInterface(string)                               {}
func (p *platform) UsePlatformShell() bool                                   { return false }
func (p *platform) CheckPlatformShell() error                                { return errors.New("禁止平台 shell") }
func (p *platform) OpenShellSession(*libbox.PlatformUser, string, libbox.StringIterator, string, int32, int32) (libbox.ShellSession, error) {
	return nil, errors.New("禁止平台 shell")
}
func (p *platform) LookupUser(string) (*libbox.PlatformUser, error) {
	return nil, errors.New("用户查询不可用")
}
func (p *platform) LookupSFTPServer() (string, error) { return "", errors.New("禁止 SFTP") }
func (p *platform) ReadSystemSSHHostKey() (string, error) {
	return "", errors.New("禁止读取 SSH 密钥")
}
func (p *platform) TailscaleHostname() string { return "" }
func (p *platform) UsePlatformBridge() bool   { return false }
func (p *platform) CreateBridge(*libbox.BridgeOptions) (libbox.BridgeSession, error) {
	return nil, errors.New("禁止桥接")
}

type handler struct{}

func (*handler) ServiceStop() error   { return errors.New("请使用应用断开") }
func (*handler) ServiceReload() error { return errors.New("请使用应用重连") }
func (*handler) GetSystemProxyStatus() (*libbox.SystemProxyStatus, error) {
	return &libbox.SystemProxyStatus{}, nil
}
func (*handler) SetSystemProxyEnabled(bool) error { return errors.New("不支持系统代理") }
func (*handler) TriggerNativeCrash() error        { return errors.New("禁止触发崩溃") }
func (*handler) WriteDebugMessage(string)         {}
func (*handler) ConnectSSHAgent() (int32, error)  { return -1, errors.New("禁止 SSH agent") }
