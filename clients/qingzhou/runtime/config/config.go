// Package config 将受限业务模型转换为核心配置，不接收外部核心配置。
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type Node struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	Kind          string            `json:"kind"`
	Server        string            `json:"server"`
	Port          int               `json:"port"`
	Parameters    map[string]string `json:"parameters"`
	CredentialRef string            `json:"credentialRef"`
}
type Reference struct {
	Kind string `json:"kind"`
	ID   string `json:"id,omitempty"`
}
type Group struct {
	ID       string      `json:"id"`
	Name     string      `json:"name"`
	Kind     string      `json:"kind"`
	Members  []Reference `json:"members"`
	Selected *Reference  `json:"selected,omitempty"`
}
type Rule struct {
	Kind      string    `json:"kind"`
	Value     string    `json:"value"`
	Target    Reference `json:"target"`
	NoResolve bool      `json:"noResolve"`
}
type Request struct {
	Nodes             []Node            `json:"nodes"`
	Groups            []Group           `json:"groups"`
	Rules             []Rule            `json:"rules"`
	Selected          Reference         `json:"selected"`
	Final             Reference         `json:"final"`
	Mode              string            `json:"mode"`
	Capture           string            `json:"capture"`
	DNS               string            `json:"dns"`
	IPv6              bool              `json:"ipv6"`
	Port              int               `json:"port"`
	Credentials       map[string]string `json:"credentials"`
	HTTPCompatibility bool              `json:"httpCompatibility"`
	Compatibility     *Compatibility    `json:"compatibility,omitempty"`
}
type Compatibility struct {
	Rewrites []Rewrite           `json:"rewrites"`
	Assets   map[string][]string `json:"assets"`
	General  map[string]string   `json:"general"`
}
type Rewrite struct {
	Pattern     string `json:"pattern"`
	Replacement string `json:"replacement"`
	Status      int    `json:"status"`
}

type Control struct {
	CorePort int
	HTTPPort int
	Port     int
	Secret   string
}

var uuid = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
var host = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$`)

func Decode(raw string) (Request, error) {
	var r Request
	if len(raw) > 4*1024*1024 {
		return r, errors.New("运行请求超过 4 MiB")
	}
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if e := d.Decode(&r); e != nil {
		return r, errors.New("运行请求格式无效")
	}
	if d.Decode(new(any)) != io.EOF {
		return r, errors.New("运行请求含多余内容")
	}
	return r, r.Validate()
}
func (r Reference) Tag() string {
	switch r.Kind {
	case "node":
		return "node-" + strings.ToLower(r.ID)
	case "group":
		return "group-" + strings.ToLower(r.ID)
	case "automatic":
		return "auto"
	case "selected":
		return "proxy"
	default:
		return r.Kind
	}
}
func (n Node) Validate(credentials map[string]string) error {
	if !uuid.MatchString(n.ID) || len(n.Name) > 400 || n.Server == "" || len(n.Server) > 253 || n.Port < 1 || n.Port > 65535 || strings.ContainsAny(n.Server, "\r\n /\\@") {
		return errors.New("节点地址或标识无效")
	}
	if net.ParseIP(n.Server) == nil && !host.MatchString(n.Server) {
		return errors.New("节点服务器无效")
	}
	if credentials[n.CredentialRef] == "" {
		return errors.New("节点凭据缺失")
	}
	allowed := map[string]bool{}
	keys := ""
	switch n.Kind {
	case "hysteria2":
		keys = "sni insecure obfs mport upmbps downmbps alpn"
	case "shadowsocks":
		keys = "method"
	case "trojan":
		keys = "sni insecure security type alpn"
	case "vless":
		keys = "sni insecure security type path host flow pbk sid fp alpn encryption"
	default:
		return errors.New("节点协议不支持")
	}
	for _, k := range strings.Fields(keys) {
		allowed[k] = true
	}
	p := n.Parameters
	for k, v := range p {
		if !allowed[k] || v == "" || len(v) > 16384 || strings.ContainsAny(v, "\r\n\x00") {
			return errors.New("节点含不支持或无效参数")
		}
	}
	if v, ok := p["insecure"]; ok && v != "0" && v != "1" {
		return errors.New("证书验证参数无效")
	}
	switch n.Kind {
	case "shadowsocks":
		if p["method"] != "aes-128-gcm" && p["method"] != "aes-256-gcm" && p["method"] != "chacha20-ietf-poly1305" {
			return errors.New("SS 加密方式不支持")
		}
	case "hysteria2":
		if p["obfs"] != "" && (p["obfs"] != "salamander" || credentials[n.CredentialRef+".obfs"] == "") {
			return errors.New("HY2 混淆无效")
		}
		for _, k := range []string{"upmbps", "downmbps"} {
			if p[k] != "" {
				v, e := strconv.Atoi(p[k])
				if e != nil || v < 1 || v > 100000 {
					return errors.New("带宽参数无效")
				}
			}
		}
		if p["mport"] != "" {
			for _, s := range strings.Split(p["mport"], ",") {
				parts := strings.Split(s, "-")
				a, e := strconv.Atoi(parts[0])
				if e != nil || a < 1 || a > 65535 || len(parts) > 2 {
					return errors.New("跳跃端口无效")
				}
				if len(parts) == 2 {
					b, e := strconv.Atoi(parts[1])
					if e != nil || b < a || b > 65535 {
						return errors.New("跳跃端口范围无效")
					}
				}
			}
		}
	case "trojan":
		if (p["type"] != "" && p["type"] != "tcp") || (p["security"] != "" && p["security"] != "tls") {
			return errors.New("Trojan 仅支持 TCP/TLS")
		}
	case "vless":
		if !uuid.MatchString(credentials[n.CredentialRef]) {
			return errors.New("VLESS UUID 无效")
		}
		if p["type"] != "" && p["type"] != "tcp" && p["type"] != "ws" {
			return errors.New("VLESS 传输不支持")
		}
		if p["security"] != "" && p["security"] != "none" && p["security"] != "tls" && p["security"] != "reality" {
			return errors.New("VLESS 安全类型不支持")
		}
		if p["encryption"] != "" && p["encryption"] != "none" {
			return errors.New("VLESS 加密不支持")
		}
		if p["flow"] != "" && (p["flow"] != "xtls-rprx-vision" || p["type"] == "ws" || (p["security"] != "tls" && p["security"] != "reality")) {
			return errors.New("Vision 参数无效")
		}
		if p["security"] == "reality" {
			if !regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`).MatchString(p["pbk"]) || p["sni"] == "" {
				return errors.New("Reality 公钥或 SNI 无效")
			}
			if s := p["sid"]; len(s) > 16 || len(s)%2 != 0 || (s != "" && !regexp.MustCompile(`^[0-9a-fA-F]+$`).MatchString(s)) {
				return errors.New("Reality short ID 无效")
			}
		} else if p["pbk"] != "" || p["sid"] != "" {
			return errors.New("Reality 参数需要对应安全类型")
		}
		if (p["path"] != "" || p["host"] != "") && p["type"] != "ws" {
			return errors.New("WebSocket 参数需要对应传输")
		}
		if p["fp"] != "" {
			if p["security"] != "tls" && p["security"] != "reality" {
				return errors.New("指纹需要 TLS")
			}
			if !strings.Contains(" chrome firefox edge safari ios android random randomized ", " "+p["fp"]+" ") {
				return errors.New("指纹不支持")
			}
		}
	}
	return nil
}
func (r Request) Validate() error {
	if len(r.Nodes) > 2000 || len(r.Groups) > 2000 || len(r.Rules) > 50000 || r.Port < 1024 || r.Port > 65535 {
		return errors.New("配置数量或监听端口无效")
	}
	if r.Mode != "rule" && r.Mode != "global" && r.Mode != "direct" {
		return errors.New("代理模式无效")
	}
	if r.Capture != "tun" && r.Capture != "systemProxy" && r.Capture != "compatible" {
		return errors.New("接管方式无效")
	}
	if r.DNS != "system" && r.DNS != "httpsProxy" {
		return errors.New("DNS 偏好无效")
	}
	if r.HTTPCompatibility && r.Compatibility == nil {
		return errors.New("HTTP 兼容配置缺失")
	}
	if r.Compatibility != nil {
		for key, entries := range r.Compatibility.Assets {
			if !strings.HasPrefix(key, "GEOIP:") && !strings.HasPrefix(key, "IP-ASN:") {
				return errors.New("规则资产类型无效")
			}
			if len(entries) > 50000 {
				return errors.New("规则资产过多")
			}
			for _, entry := range entries {
				if _, e := netip.ParsePrefix(entry); e != nil {
					return errors.New("规则资产 CIDR 无效")
				}
			}
		}
	}

	nodes := map[string]bool{}
	groups := map[string]Group{}
	for _, n := range r.Nodes {
		if nodes[n.ID] {
			return errors.New("节点 ID 重复")
		}
		nodes[n.ID] = true
		if e := n.Validate(r.Credentials); e != nil {
			return e
		}
	}
	for _, g := range r.Groups {
		if !uuid.MatchString(g.ID) || groups[g.ID].ID != "" || len(g.Members) == 0 {
			return errors.New("策略组无效")
		}
		if g.Kind != "select" && g.Kind != "urltest" && g.Kind != "fallback" {
			return errors.New("策略组类型无效")
		}
		groups[g.ID] = g
	}
	valid := func(p Reference) bool {
		switch p.Kind {
		case "node":
			return nodes[p.ID]
		case "group":
			return groups[p.ID].ID != ""
		case "automatic":
			return len(nodes) > 0
		case "selected", "direct", "reject":
			return p.ID == ""
		}
		return false
	}
	visiting := map[string]bool{}
	done := map[string]bool{}
	var visit func(string) error
	visit = func(id string) error {
		if visiting[id] {
			return errors.New("策略组循环引用")
		}
		if done[id] {
			return nil
		}
		visiting[id] = true
		g := groups[id]
		if g.Kind == "fallback" {
			for _, m := range g.Members {
				if m.Kind != "node" {
					return errors.New("优先回退仅接受节点")
				}
			}
		}

		selected := g.Selected == nil
		for _, m := range g.Members {
			if !valid(m) || m.Kind == "selected" || m.Kind == "reject" {
				return errors.New("策略组成员无效")
			}
			if g.Selected != nil && m == *g.Selected {
				selected = true
			}
			if m.Kind == "group" {
				if e := visit(m.ID); e != nil {
					return e
				}
			}
		}
		if !selected {
			return errors.New("策略组选择无效")
		}
		visiting[id] = false
		done[id] = true
		return nil
	}
	for id := range groups {
		if e := visit(id); e != nil {
			return e
		}
	}
	if !valid(r.Selected) || r.Selected.Kind == "selected" || r.Selected.Kind == "reject" || !valid(r.Final) {
		return errors.New("当前或最终策略无效")
	}
	for _, v := range r.Rules {
		if !valid(v.Target) {
			return errors.New("规则策略失效")
		}
		switch v.Kind {
		case "match":
			if v.Value != "" {
				return errors.New("MATCH 内容必须为空")
			}
		case "domain", "suffix":
			if len(v.Value) > 253 || !host.MatchString(v.Value) {
				return errors.New("域名规则无效")
			}
		case "keyword":
			if v.Value == "" || strings.ContainsAny(v.Value, " \r\n\t") {
				return errors.New("关键词无效")
			}
		case "userAgent":
			if r.Compatibility == nil || len(v.Value) > 512 || v.Value == "" || strings.ContainsAny(v.Value, "\r\n") {
				return errors.New("User-Agent 需要 HTTP 兼容模式")
			}
		case "geoip", "asn":
			key := "GEOIP:" + v.Value
			if v.Kind == "asn" {
				key = "IP-ASN:" + v.Value
			}
			if r.Compatibility == nil || len(r.Compatibility.Assets[key]) == 0 {
				return errors.New("地理或 ASN 规则资产缺失")
			}
		case "cidr":
			if _, e := netip.ParsePrefix(v.Value); e != nil {
				if _, e = netip.ParseAddr(v.Value); e != nil {
					return errors.New("CIDR 无效")
				}
			}
		default:
			return errors.New("此规则类型尚不支持")
		}
	}
	return nil
}
func outbound(n Node, c map[string]string) map[string]any {
	p := n.Parameters
	o := map[string]any{"type": n.Kind, "tag": Reference{"node", n.ID}.Tag(), "server": n.Server, "server_port": n.Port}
	s := c[n.CredentialRef]
	switch n.Kind {
	case "vless":
		o["uuid"] = s
		if p["flow"] != "" {
			o["flow"] = p["flow"]
		}
		if p["type"] == "ws" {
			ws := map[string]any{"type": "ws", "path": "/"}
			if p["path"] != "" {
				ws["path"] = p["path"]
			}
			if p["host"] != "" {
				ws["headers"] = map[string]string{"Host": p["host"]}
			}
			o["transport"] = ws
		}
	case "shadowsocks":
		o["method"] = p["method"]
		o["password"] = s
	default:
		o["password"] = s
	}
	if n.Kind == "hysteria2" {
		if p["obfs"] != "" {
			o["obfs"] = map[string]any{"type": "salamander", "password": c[n.CredentialRef+".obfs"]}
		}
		if p["mport"] != "" {
			ports := []string{}
			for _, s := range strings.Split(p["mport"], ",") {
				if strings.Contains(s, "-") {
					ports = append(ports, strings.ReplaceAll(s, "-", ":"))
				} else {
					ports = append(ports, s+":"+s)
				}
			}
			delete(o, "server_port")
			o["server_ports"] = ports
		}
		for _, k := range []string{"upmbps", "downmbps"} {
			if p[k] != "" {
				v, _ := strconv.Atoi(p[k])
				key := strings.Replace(k, "mbps", "_mbps", 1)
				o[key] = v
			}
		}
	}
	if n.Kind == "hysteria2" || n.Kind == "trojan" || p["security"] == "tls" || p["security"] == "reality" {
		server := p["sni"]
		if server == "" {
			server = n.Server
		}
		t := map[string]any{"enabled": true, "server_name": server, "insecure": p["insecure"] == "1"}
		if p["alpn"] != "" {
			t["alpn"] = strings.Split(p["alpn"], ",")
		}
		if p["fp"] != "" || p["security"] == "reality" {
			fp := p["fp"]
			if fp == "" {
				fp = "chrome"
			}
			t["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
		}
		if p["security"] == "reality" {
			t["reality"] = map[string]any{"enabled": true, "public_key": p["pbk"], "short_id": p["sid"]}
		}
		o["tls"] = t
	}
	return o
}
func Build(r Request, control Control) ([]byte, error) {
	if e := r.Validate(); e != nil {
		return nil, e
	}
	if control.Port < 1024 || control.Port > 65535 || control.Port == r.Port || len(control.Secret) < 32 {
		return nil, errors.New("控制端口或密钥无效")
	}
	outs := []any{}
	choices := []string{}
	nodes := []string{}
	for _, n := range r.Nodes {
		outs = append(outs, outbound(n, r.Credentials))
		nodes = append(nodes, Reference{"node", n.ID}.Tag())
		choices = append(choices, Reference{"node", n.ID}.Tag())
	}
	outs = append(outs, map[string]any{"type": "direct", "tag": "direct"})
	if len(nodes) > 0 {
		outs = append(outs, map[string]any{"type": "urltest", "tag": "auto", "outbounds": nodes, "url": "https://www.gstatic.com/generate_204", "interval": "5m", "tolerance": 50})
		choices = append(choices, "auto")
	}
	for _, g := range r.Groups {
		members := []string{}
		for _, m := range g.Members {
			members = append(members, m.Tag())
		}
		o := map[string]any{"tag": Reference{"group", g.ID}.Tag(), "outbounds": members, "interrupt_exist_connections": false}
		if g.Kind == "urltest" {
			o["type"] = "urltest"
			o["url"] = "https://www.gstatic.com/generate_204"
			o["interval"] = "5m"
			o["tolerance"] = 50
		} else {
			o["type"] = "selector"
			o["default"] = members[0]
			if g.Selected != nil {
				o["default"] = g.Selected.Tag()
			}
		}
		outs = append(outs, o)
		choices = append(choices, Reference{"group", g.ID}.Tag())
	}
	choices = append(choices, "direct")
	outs = append(outs, map[string]any{"type": "selector", "tag": "proxy", "outbounds": choices, "default": r.Selected.Tag(), "interrupt_exist_connections": false})
	rules := []any{map[string]any{"action": "sniff", "timeout": "300ms"}, map[string]any{"port": 53, "action": "hijack-dns"}}
	if r.Mode == "direct" {
		rules = append(rules, map[string]any{"action": "route", "outbound": "direct"})
	} else if r.Mode == "global" {
		rules = append(rules, map[string]any{"action": "route", "outbound": "proxy"})
	} else {
		rules = append(rules, map[string]any{"ip_is_private": true, "action": "route", "outbound": "direct"}, map[string]any{"domain": []string{"localhost"}, "action": "route", "outbound": "direct"})
		for _, v := range r.Rules {
			if v.Kind == "userAgent" {
				continue
			}
			rule := map[string]any{}
			key := map[string]string{"domain": "domain", "suffix": "domain_suffix", "keyword": "domain_keyword", "cidr": "ip_cidr"}[v.Kind]
			if key != "" {
				rule[key] = []string{v.Value}
			}
			if v.Kind == "geoip" || v.Kind == "asn" {
				asset := "GEOIP:" + v.Value
				if v.Kind == "asn" {
					asset = "IP-ASN:" + v.Value
				}
				rule["ip_cidr"] = r.Compatibility.Assets[asset]
			}
			if v.Target.Kind == "reject" {
				rule["action"] = "reject"
			} else {
				rule["action"] = "route"
				rule["outbound"] = v.Target.Tag()
			}
			rules = append(rules, rule)
		}
	}
	final := r.Final.Tag()
	if final == "reject" {
		rules = append(rules, map[string]any{"action": "reject"})
		final = "proxy"
	}
	inbounds := []any{map[string]any{"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": r.Port, "set_system_proxy": false}}
	if r.Capture != "systemProxy" {
		addresses := []string{"172.29.0.1/30"}
		if r.IPv6 {
			addresses = append(addresses, "fdfe:dcba:9876::1/126")
		}
		inbounds = append(inbounds, map[string]any{"type": "tun", "tag": "tun-in", "address": addresses, "mtu": 1500, "stack": "gvisor", "auto_route": true, "strict_route": true})
	}
	servers := []any{map[string]any{"type": "local", "tag": "local"}}
	dnsFinal := "local"
	if r.DNS == "httpsProxy" {
		servers = append(servers, map[string]any{"type": "https", "tag": "remote", "server": "1.1.1.1", "path": "/dns-query", "tls": map[string]any{"enabled": true, "server_name": "cloudflare-dns.com"}, "detour": "proxy"})
		dnsFinal = "remote"
	}
	dnsRules := []any{}
	for _, n := range r.Nodes {
		if net.ParseIP(n.Server) == nil {
			dnsRules = append(dnsRules, map[string]any{"domain": []string{n.Server}, "server": "local"})
		}
	}
	if r.Mode == "direct" {
		dnsFinal = "local"
	} else if r.Mode == "rule" {
		for _, rule := range r.Rules {
			if rule.Target.Kind == "direct" {
				key := map[string]string{"domain": "domain", "suffix": "domain_suffix", "keyword": "domain_keyword"}[rule.Kind]
				if key != "" {
					dnsRules = append(dnsRules, map[string]any{key: []string{rule.Value}, "server": "local"})
				}
			}
		}
	}
	strategy := "ipv4_only"
	if r.IPv6 {
		strategy = "prefer_ipv4"
	}
	object := map[string]any{"log": map[string]any{"level": "warn", "timestamp": true}, "inbounds": inbounds, "outbounds": outs, "route": map[string]any{"rules": rules, "final": final, "auto_detect_interface": true, "default_domain_resolver": "local"}, "dns": map[string]any{"servers": servers, "rules": dnsRules, "final": dnsFinal, "strategy": strategy, "reverse_mapping": true}, "experimental": map[string]any{"clash_api": map[string]any{"external_controller": fmt.Sprintf("127.0.0.1:%d", control.Port), "secret": control.Secret, "external_ui": "", "default_mode": r.Mode, "access_control_allow_origin": []string{"qingzhou://local"}, "access_control_allow_private_network": false}}}
	if r.HTTPCompatibility {
		if control.CorePort < 1024 || control.HTTPPort < 1024 || control.CorePort > 65535 || control.HTTPPort > 65535 || control.CorePort == control.HTTPPort || control.CorePort == r.Port || control.HTTPPort == r.Port || control.CorePort == control.Port || control.HTTPPort == control.Port {
			return nil, errors.New("HTTP 兼容端口无效")
		}
		inbounds[0].(map[string]any)["listen_port"] = control.CorePort
		policies := Policies(r)
		users := []any{}
		forced := []any{}
		for _, policy := range policies {
			users = append(users, map[string]string{"username": "compat-" + strings.ToLower(policy), "password": control.Secret})
			target := policy
			if policy == "DIRECT" {
				target = "direct"
			}
			if policy == "PROXY" {
				target = "proxy"
			}
			forced = append(forced, map[string]any{"inbound": []string{"http-compat-in"}, "auth_user": []string{"compat-" + strings.ToLower(policy)}, "action": "route", "outbound": target})
		}
		inbounds = append(inbounds, map[string]any{"type": "http", "tag": "http-compat-in", "listen": "127.0.0.1", "listen_port": control.HTTPPort, "users": users})
		for _, entry := range inbounds {
			item := entry.(map[string]any)
			if item["type"] == "tun" {
				item["platform"] = map[string]any{"http_proxy": map[string]any{"enabled": true, "server": "127.0.0.1", "server_port": r.Port}}
			}
		}
		object["inbounds"] = inbounds
		route := object["route"].(map[string]any)
		route["rules"] = append(forced, rules...)
	}
	return json.Marshal(object)
}
func EqualJSON(a, b []byte) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	p, _ := json.Marshal(x)
	q, _ := json.Marshal(y)
	return bytes.Equal(p, q)
}

func Policies(r Request) []string {
	seen := map[string]bool{"DIRECT": true, "PROXY": true}
	for _, rule := range r.Rules {
		policy := Policy(rule.Target)
		if policy != "REJECT" {
			seen[policy] = true
		}
	}
	policy := Policy(r.Final)
	if policy != "REJECT" {
		seen[policy] = true
	}
	out := []string{}
	for policy := range seen {
		out = append(out, policy)
	}
	sort.Strings(out)
	return out
}
func Policy(ref Reference) string {
	switch ref.Kind {
	case "direct":
		return "DIRECT"
	case "selected":
		return "PROXY"
	case "reject":
		return "REJECT"
	default:
		return ref.Tag()
	}
}
func Gateway(r Request, c Control) (string, error) {
	if !r.HTTPCompatibility {
		return "", errors.New("HTTP 兼容未启用")
	}
	rows := []any{}
	kinds := map[string]string{"domain": "DOMAIN", "suffix": "DOMAIN-SUFFIX", "keyword": "DOMAIN-KEYWORD", "cidr": "IP-CIDR", "geoip": "GEOIP", "asn": "IP-ASN", "userAgent": "USER-AGENT", "match": "FINAL"}
	final := false
	for _, rule := range r.Rules {
		rows = append(rows, map[string]any{"kind": kinds[rule.Kind], "value": rule.Value, "policy": Policy(rule.Target), "noResolve": rule.NoResolve})
		if rule.Kind == "match" {
			final = true
			break
		}
	}
	if !final {
		rows = append(rows, map[string]any{"kind": "FINAL", "value": "", "policy": Policy(r.Final), "noResolve": false})
	}
	family := "ipv4Only"
	if r.IPv6 {
		family = "preferIPv4"
	}
	b, e := json.Marshal(map[string]any{"version": 1, "listenPort": r.Port, "corePort": c.CorePort, "httpPort": c.HTTPPort, "controlPort": c.Port, "secret": c.Secret, "mode": r.Mode, "addressFamilyPolicy": family, "dnsPreference": r.DNS, "policies": Policies(r), "rules": rows, "rewrites": r.Compatibility.Rewrites, "assets": r.Compatibility.Assets, "general": r.Compatibility.General})
	return string(b), e
}

// ExtraPorts 为兼容入口分配独立回环端口，实际绑定失败由启动事务回滚。
func ExtraPorts(c *Control, public int) error {
	listeners := []net.Listener{}
	defer func() {
		for _, l := range listeners {
			l.Close()
		}
	}()
	for index := 0; index < 2; {
		l, e := net.Listen("tcp", "127.0.0.1:0")
		if e != nil {
			return e
		}
		port := l.Addr().(*net.TCPAddr).Port
		if port == public || port == c.Port {
			l.Close()
			continue
		}
		listeners = append(listeners, l)
		if index == 0 {
			c.CorePort = port
		} else {
			c.HTTPPort = port
		}
		index++
	}
	return nil
}

// ProbeRequest 只保留单节点测速所需字段，禁止测速流程接管网络。
func ProbeRequest(raw string) (Request, error) {
	r, e := Decode(raw)
	if e != nil {
		return r, e
	}
	if len(r.Nodes) != 1 || r.Selected.Kind != "node" || r.Selected.ID != r.Nodes[0].ID {
		return r, errors.New("测速需要明确的单个节点")
	}
	r.Capture = "systemProxy"
	r.Mode = "global"
	r.Final = Reference{Kind: "selected"}
	r.Groups = nil
	r.Rules = nil
	r.HTTPCompatibility = false
	r.Compatibility = nil
	return r, nil
}
