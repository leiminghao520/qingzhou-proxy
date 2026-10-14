package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type rule struct {
	Kind      string `json:"kind"`
	Value     string `json:"value"`
	Policy    string `json:"policy"`
	NoResolve bool   `json:"noResolve"`
}
type rewrite struct {
	Pattern     string `json:"pattern"`
	Replacement string `json:"replacement"`
	Status      int    `json:"status"`
}
type configuration struct {
	AddressFamilyPolicy string              `json:"addressFamilyPolicy"`
	DNSPreference       string              `json:"dnsPreference"`
	Policies            []string            `json:"policies"`
	Version             int                 `json:"version"`
	ListenPort          int                 `json:"listenPort"`
	CorePort            int                 `json:"corePort"`
	HTTPPort            int                 `json:"httpPort"`
	ControlPort         int                 `json:"controlPort"`
	Secret              string              `json:"secret"`
	Mode                string              `json:"mode"`
	Rules               []rule              `json:"rules"`
	Rewrites            []rewrite           `json:"rewrites"`
	Assets              map[string][]string `json:"assets"`
	General             map[string]string   `json:"general"`
}
type compiledRule struct {
	rule
	prefixes []netip.Prefix
	agent    *regexp.Regexp
}
type compiledRewrite struct {
	rewrite
	expression *regexp.Regexp
}
type gateway struct {
	connections *mixedListener
	config      configuration
	rules       []compiledRule
	rewrites    []compiledRewrite
	transports  map[string]*http.Transport
	control     *http.Client
	resolve     func(context.Context, string) ([]netip.Addr, error)
}

func prepare(config configuration) (*gateway, error) {
	switch config.AddressFamilyPolicy {
	case "", "ipv4Only", "preferIPv4", "dualStack":
	default:
		return nil, fmt.Errorf("invalid address family policy")
	}
	switch config.DNSPreference {
	case "", "system", "httpsProxy":
	default:
		return nil, fmt.Errorf("invalid DNS preference")
	}

	if config.Version != 1 || config.Secret == "" || len(config.Rules) == 0 {
		return nil, fmt.Errorf("invalid configuration")
	}
	g := &gateway{config: config, transports: map[string]*http.Transport{}, control: &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}}
	g.resolve = func(ctx context.Context, host string) ([]netip.Addr, error) {
		network := "ip"
		if config.AddressFamilyPolicy == "" || config.AddressFamilyPolicy == "ipv4Only" {
			network = "ip4"
		}
		if config.DNSPreference == "httpsProxy" {
			return g.lookupProxy(ctx, host, network)
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, network, host)
		return orderAddresses(ips, config.AddressFamilyPolicy), err
	}
	for _, item := range config.Rules {
		c := compiledRule{rule: item}
		allowed := item.Policy == "REJECT"
		for _, policy := range config.Policies {
			if item.Policy == policy {
				allowed = true
			}
		}
		if !allowed {
			return nil, fmt.Errorf("invalid policy")
		}
		switch item.Kind {
		case "IP-CIDR", "IP-CIDR6":
			prefix, e := netip.ParsePrefix(item.Value)
			if e != nil {
				return nil, e
			}
			c.prefixes = []netip.Prefix{prefix}
		case "GEOIP", "IP-ASN":
			entries := config.Assets[item.Kind+":"+item.Value]
			if len(entries) == 0 {
				return nil, fmt.Errorf("missing asset")
			}
			for _, entry := range entries {
				prefix, e := netip.ParsePrefix(entry)
				if e != nil {
					return nil, e
				}
				c.prefixes = append(c.prefixes, prefix)
			}
		case "USER-AGENT":
			if item.Value == "" {
				return nil, fmt.Errorf("empty agent")
			}
			expression := regexp.QuoteMeta(item.Value)
			expression = strings.ReplaceAll(expression, `\*`, ".*")
			expression = strings.ReplaceAll(expression, `\?`, ".")
			c.agent = regexp.MustCompile("^" + expression + "$")
		case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
			if item.Value == "" {
				return nil, fmt.Errorf("empty domain")
			}
		case "FINAL":
		default:
			return nil, fmt.Errorf("unsupported rule")
		}
		g.rules = append(g.rules, c)
	}
	if g.rules[len(g.rules)-1].Kind != "FINAL" {
		return nil, fmt.Errorf("missing final")
	}
	for _, item := range config.Rewrites {
		if item.Status != 301 && item.Status != 302 && item.Status != 307 && item.Status != 308 {
			return nil, fmt.Errorf("invalid redirect")
		}
		parsed, e := url.Parse(item.Replacement)
		if e != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return nil, fmt.Errorf("invalid redirect URL")
		}
		expression, e := regexp.Compile(item.Pattern)
		if e != nil {
			return nil, e
		}
		g.rewrites = append(g.rewrites, compiledRewrite{item, expression})
	}
	for _, policy := range config.Policies {
		upstream := &url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(config.HTTPPort)), User: url.UserPassword("compat-"+strings.ToLower(policy), config.Secret)}
		g.transports[policy] = &http.Transport{Proxy: http.ProxyURL(upstream), ForceAttemptHTTP2: false, MaxIdleConns: 32, IdleConnTimeout: 30 * time.Second, ResponseHeaderTimeout: 30 * time.Second}
	}
	return g, nil
}
func (g *gateway) mode(ctx context.Context) (string, error) {
	req, e := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("http://127.0.0.1:%d/configs", g.config.ControlPort), nil)
	if e != nil {
		return "", e
	}
	req.Header.Set("Authorization", "Bearer "+g.config.Secret)
	res, e := g.control.Do(req)
	if e != nil {
		return "", e
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return "", controlStatusError(res.StatusCode)
	}
	var value struct {
		Mode string `json:"mode"`
	}
	e = json.NewDecoder(io.LimitReader(res.Body, 65536)).Decode(&value)
	if e != nil {
		return "", e
	}
	switch strings.ToLower(value.Mode) {
	case "rule", "global", "direct":
		return strings.ToLower(value.Mode), nil
	default:
		return "", fmt.Errorf("unknown mode")
	}
}
func (g *gateway) pick(ctx context.Context, host, agent, mode string) (string, error) {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	if addr, e := netip.ParseAddr(host); e == nil && addr.Is6() && !addr.Is4In6() && (g.config.AddressFamilyPolicy == "" || g.config.AddressFamilyPolicy == "ipv4Only") {
		return "", errIPv6Unavailable
	}
	// 系统代理绕过项优先于代理模式，保持企业内网和本地服务的直连设置。
	for _, item := range strings.Split(g.config.General["skip-proxy"], ",") {
		item = strings.TrimSpace(strings.ToLower(item))
		if item == "" {
			continue
		}
		if prefix, e := netip.ParsePrefix(item); e == nil {
			if addr, e := netip.ParseAddr(host); e == nil && prefix.Contains(addr) {
				return "DIRECT", nil
			}
		} else if strings.HasPrefix(item, "*.") {
			suffix := strings.TrimPrefix(item, "*.")
			if host == suffix || strings.HasSuffix(host, "."+suffix) {
				return "DIRECT", nil
			}
		} else if host == item {
			return "DIRECT", nil
		}
	}
	if mode == "direct" {
		return "DIRECT", nil
	}
	if mode == "global" {
		return "PROXY", nil
	}
	var ips []netip.Addr
	resolved := false
	if addr, e := netip.ParseAddr(host); e == nil {
		ips = []netip.Addr{addr}
		resolved = true
	}
	for _, item := range g.rules {
		matched := false
		switch item.Kind {
		case "DOMAIN":
			matched = host == strings.ToLower(item.Value)
		case "DOMAIN-SUFFIX":
			suffix := strings.ToLower(item.Value)
			matched = host == suffix || strings.HasSuffix(host, "."+suffix)
		case "DOMAIN-KEYWORD":
			matched = strings.Contains(host, strings.ToLower(item.Value))
		case "USER-AGENT":
			matched = item.agent.MatchString(agent)
		case "IP-CIDR", "IP-CIDR6", "GEOIP", "IP-ASN":
			if !resolved {
				if item.NoResolve {
					continue
				}
				var e error
				ips, e = g.resolve(ctx, host)
				if e != nil {
					return "", e
				}
				resolved = true
			}
			for _, ip := range ips {
				for _, prefix := range item.prefixes {
					if prefix.Contains(ip) {
						matched = true
						break
					}
				}
				if matched {
					break
				}
			}
		case "FINAL":
			matched = true
		}
		if matched {
			return item.Policy, nil
		}
	}
	return "", fmt.Errorf("no final policy")
}
func removeHopHeaders(header http.Header) {
	for _, v := range header.Values("Connection") {
		for _, name := range strings.Split(v, ",") {
			header.Del(strings.TrimSpace(name))
		}
	}
	for _, name := range []string{"Connection", "Proxy-Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer", "Transfer-Encoding", "Upgrade"} {
		header.Del(name)
	}
}
func (g *gateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.Method == http.MethodConnect {
		g.connect(w, r)
		return
	}
	if r.URL.Scheme != "http" || r.URL.Host == "" {
		diagnostic("http", "compatibility", start, 1)
		http.Error(w, "Absolute HTTP URL required", http.StatusBadRequest)
		return
	}
	mode, e := g.mode(r.Context())
	if e != nil {
		diagnostic("control", errorCategory(e, "control"), start, 1)
		http.Error(w, "Proxy controller unavailable", http.StatusBadGateway)
		return
	}
	if mode == "rule" {
		for _, item := range g.rewrites {
			if item.expression.MatchString(r.URL.String()) {
				target := item.expression.ReplaceAllString(r.URL.String(), item.Replacement)
				w.Header().Set("Location", target)
				w.WriteHeader(item.Status)
				return
			}
		}
	}
	policy, e := g.pick(r.Context(), r.URL.Hostname(), r.UserAgent(), mode)
	if e != nil {
		diagnostic("resolve", errorCategory(e, "dns"), start, 1)
		http.Error(w, "Destination resolution failed", http.StatusBadGateway)
		return
	}
	if policy == "REJECT" {
		http.Error(w, "Rejected by rule", http.StatusForbidden)
		return
	}
	outbound := r.Clone(r.Context())
	outbound.RequestURI = ""
	upgrade := r.Header.Get("Upgrade")
	wantsUpgrade := upgrade != "" && hasToken(r.Header.Get("Connection"), "upgrade")
	removeHopHeaders(outbound.Header)
	if wantsUpgrade {
		outbound.Header.Set("Connection", "Upgrade")
		outbound.Header.Set("Upgrade", upgrade)
	}
	response, e := g.transports[policy].RoundTrip(outbound)
	if e != nil {
		diagnostic("connect", errorCategory(e, "upstream"), start, 1)
		http.Error(w, "Upstream proxy unavailable", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusSwitchingProtocols {
		if !wantsUpgrade || !strings.EqualFold(response.Header.Get("Upgrade"), upgrade) {
			http.Error(w, "Invalid upstream upgrade", 502)
			return
		}
		g.upgrade(w, r, response, start)
		return
	}
	removeHopHeaders(response.Header)
	for key, values := range response.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.WriteHeader(response.StatusCode)
	// 每次回传后刷新，保证 SSE 等流式响应的首段及时到达。
	controller := http.NewResponseController(w)
	_ = controller.Flush()
	n, err := io.Copy(flushWriter{w, controller}, response.Body)
	category := "ok"
	if err != nil {
		category = errorCategory(err, "upstream")
	}
	transferDiagnostic("http", "http", category, start, 0, n)
}
func (g *gateway) connect(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	// HTTPS 隧道只转发字节，不解密 TLS，也不声称能匹配加密后的 User-Agent 和 URL 路径。
	host, port, e := net.SplitHostPort(r.Host)
	n, pe := strconv.Atoi(port)
	if e != nil || pe != nil || host == "" || n < 1 || n > 65535 {
		diagnostic("connect", "compatibility", start, 1)
		http.Error(w, "Invalid tunnel target", 400)
		return
	}
	mode, e := g.mode(r.Context())
	if e != nil {
		diagnostic("control", errorCategory(e, "control"), start, 1)
		http.Error(w, "Proxy controller unavailable", 502)
		return
	}
	policy, e := g.pick(r.Context(), host, "", mode)
	if e != nil {
		diagnostic("resolve", errorCategory(e, "dns"), start, 1)
		http.Error(w, "Destination resolution failed", 502)
		return
	}
	if policy == "REJECT" {
		http.Error(w, "Rejected by rule", 403)
		return
	}
	upstream, e := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(r.Context(), "tcp", fmt.Sprintf("127.0.0.1:%d", g.config.HTTPPort))
	if e != nil {
		diagnostic("connect", errorCategory(e, "upstream"), start, 1)
		http.Error(w, "Upstream proxy unavailable", 502)
		return
	}
	if g.connections != nil {
		var ok bool
		upstream, ok = g.connections.track(upstream)
		if !ok {
			return
		}
	}
	defer upstream.Close()
	_ = upstream.SetDeadline(time.Now().Add(10 * time.Second))
	if _, e = fmt.Fprintf(upstream, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n", r.Host, r.Host, base64.StdEncoding.EncodeToString([]byte("compat-"+strings.ToLower(policy)+":"+g.config.Secret))); e != nil {
		diagnostic("connect", errorCategory(e, "upstream"), start, 1)
		http.Error(w, "Upstream proxy unavailable", 502)
		return
	}
	reader := bufio.NewReader(upstream)
	response, e := http.ReadResponse(reader, r)
	if e != nil || response.StatusCode != 200 {
		category := errorCategory(e, "upstream")
		if response != nil && (response.StatusCode == 401 || response.StatusCode == 407) {
			category = "auth"
		}
		diagnostic("connect", category, start, 1)
		http.Error(w, "Tunnel refused", 502)
		return
	}
	_ = upstream.SetDeadline(time.Time{})
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "Tunnel unavailable", 500)
		return
	}
	client, buffer, e := hijacker.Hijack()
	if e != nil {
		return
	}
	defer client.Close()
	_, _ = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
	if buffer.Flush() != nil {
		return
	}
	relay(client, buffer, upstream, reader)
}

type bufferedConnection struct {
	net.Conn
	reader *bufio.Reader
}

func (c *bufferedConnection) Read(b []byte) (int, error) { return c.reader.Read(b) }

func run(input io.Reader) error {
	var config configuration
	decoder := json.NewDecoder(io.LimitReader(input, 4*1024*1024))
	if e := decoder.Decode(&config); e != nil {
		return e
	}
	seen := map[int]bool{}
	for _, port := range []int{config.ListenPort, config.CorePort, config.HTTPPort, config.ControlPort} {
		if port < 1024 || port > 65535 || seen[port] {
			return fmt.Errorf("invalid port")
		}
		seen[port] = true
	}
	g, e := prepare(config)
	if e != nil {
		return e
	}
	listener, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", config.ListenPort))
	if e != nil {
		return e
	}
	mixed := newMixedListener(listener, config.CorePort)
	defer func() { _ = mixed.Close(); mixed.wait() }()
	g.connections = mixed
	defer func() {
		for _, transport := range g.transports {
			transport.CloseIdleConnections()
		}
	}()
	server := &http.Server{Handler: g, ReadHeaderTimeout: 10 * time.Second, MaxHeaderBytes: 65536}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	// 应用崩溃后结束兼容监听，避免留下独立于应用生命周期的代理服务。
	parent := os.Getppid()
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				_ = server.Close()
				return
			case <-ticker.C:
				if os.Getppid() != parent {
					_ = server.Close()
					return
				}
			}
		}
	}()
	e = server.Serve(mixed)
	if e == http.ErrServerClosed {
		return nil
	}
	return e
}
func main() {
	if run(os.Stdin) != nil {
		diagnostic("startup", "compatibility", time.Now(), 1)
		os.Exit(1)
	}
}

type controlStatusError int

func (e controlStatusError) Error() string { return "controller status" }
func errorCategory(err error, fallback string) string {
	if errors.Is(err, errIPv6Unavailable) {
		return "ipv6Unavailable"
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed) || errors.Is(err, io.ErrClosedPipe) {
		return "cancelled"
	}
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return "timeout"
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "dns"
	}
	var status controlStatusError
	if errors.As(err, &status) && (status == 401 || status == 403 || status == 407) {
		return "auth"
	}
	return fallback
}
