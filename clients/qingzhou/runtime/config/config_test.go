package config

import (
	"encoding/json"
	"strings"
	"testing"
)

const nodeID = "00000000-0000-4000-8000-000000000001"

func request() Request {
	return Request{Nodes: []Node{{ID: nodeID, Name: "测试", Kind: "trojan", Server: "example.com", Port: 443, Parameters: map[string]string{}, CredentialRef: "secret"}}, Selected: Reference{Kind: "node", ID: nodeID}, Final: Reference{Kind: "selected"}, Mode: "rule", Capture: "tun", DNS: "httpsProxy", Port: 17890, Credentials: map[string]string{"secret": "test-only-password"}}
}
func TestRejectUnsafeInput(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Request)
	}{
		{"未知节点参数", func(r *Request) { r.Nodes[0].Parameters["plugin"] = "shell" }},
		{"缺失凭据", func(r *Request) { delete(r.Credentials, "secret") }},
		{"失效策略", func(r *Request) { r.Selected.ID = "missing" }},
		{"非法端口", func(r *Request) { r.Port = 80 }},
		{"证书值不明确", func(r *Request) { r.Nodes[0].Parameters["insecure"] = "yes" }},
		{"非法规则", func(r *Request) {
			r.Rules = []Rule{{Kind: "cidr", Value: "1.2.3.4/99", Target: Reference{Kind: "direct"}}}
		}},
		{"不支持传输", func(r *Request) { r.Nodes[0].Parameters["type"] = "grpc" }},
		{"不存在的组成员", func(r *Request) {
			r.Groups = []Group{{ID: nodeID, Kind: "select", Members: []Reference{{Kind: "node", ID: "missing"}}}}
		}},
		{"重复节点", func(r *Request) { r.Nodes = append(r.Nodes, r.Nodes[0]) }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			r := request()
			test.edit(&r)
			if r.Validate() == nil {
				t.Fatal("应拒绝配置")
			}
		})
	}
}
func TestCycleAndSelection(t *testing.T) {
	r := request()
	a := "00000000-0000-4000-8000-000000000002"
	b := "00000000-0000-4000-8000-000000000003"
	r.Groups = []Group{{ID: a, Kind: "select", Members: []Reference{{Kind: "group", ID: b}}}, {ID: b, Kind: "select", Members: []Reference{{Kind: "group", ID: a}}}}
	if r.Validate() == nil {
		t.Fatal("未检测循环")
	}
	r.Groups[1].Members = []Reference{{Kind: "node", ID: nodeID}}
	if e := r.Validate(); e != nil {
		t.Fatal(e)
	}
	r.Groups[0].Selected = &Reference{Kind: "direct"}
	if r.Validate() == nil {
		t.Fatal("选择不在组中")
	}
}
func TestBuildProtocolAndOrder(t *testing.T) {
	for _, kind := range []string{"hysteria2", "trojan", "shadowsocks", "vless"} {
		t.Run(kind, func(t *testing.T) {
			r := request()
			r.Nodes[0].Kind = kind
			if kind == "shadowsocks" {
				r.Nodes[0].Parameters["method"] = "aes-256-gcm"
			}
			if kind == "vless" {
				r.Credentials["secret"] = nodeID
				r.Nodes[0].Parameters = map[string]string{"security": "reality", "pbk": strings.Repeat("a", 43), "sni": "example.com", "flow": "xtls-rprx-vision"}
			}
			r.Rules = []Rule{{Kind: "suffix", Value: "example.net", Target: Reference{Kind: "direct"}}}
			b, e := Build(r, Control{Port: 17891, Secret: strings.Repeat("a", 64)})
			if e != nil {
				t.Fatal(e)
			}
			var cfg map[string]any
			if json.Unmarshal(b, &cfg) != nil {
				t.Fatal("无效 JSON")
			}
			outs := cfg["outbounds"].([]any)
			if outs[0].(map[string]any)["type"] != kind {
				t.Fatal("协议改变")
			}
			in := cfg["inbounds"].([]any)
			if len(in) != 2 {
				t.Fatal("缺少 TUN")
			}
			api := cfg["experimental"].(map[string]any)["clash_api"].(map[string]any)
			if api["external_controller"] != "127.0.0.1:17891" {
				t.Fatal("控制接口未限制回环")
			}
			rules := cfg["route"].(map[string]any)["rules"].([]any)
			if rules[2].(map[string]any)["ip_is_private"] != true {
				t.Fatal("私网规则顺序改变")
			}
		})
	}
}
func TestDecodeBoundaries(t *testing.T) {
	r := request()
	b, _ := json.Marshal(r)
	if _, e := Decode(string(b)); e != nil {
		t.Fatal(e)
	}
	for _, raw := range []string{string(b) + "{}", `{"program":"sh"}`, strings.Repeat("x", 4*1024*1024+1)} {
		if _, e := Decode(raw); e == nil {
			t.Fatal("接受未受限请求")
		}
	}
}
func TestDirectAndReject(t *testing.T) {
	r := request()
	r.Mode = "direct"
	r.Capture = "systemProxy"
	r.Final = Reference{Kind: "reject"}
	b, e := Build(r, Control{Port: 17891, Secret: strings.Repeat("x", 64)})
	if e != nil {
		t.Fatal(e)
	}
	var cfg map[string]any
	json.Unmarshal(b, &cfg)
	if len(cfg["inbounds"].([]any)) != 1 {
		t.Fatal("系统代理包含 TUN")
	}
	if _, e = Build(r, Control{Port: r.Port, Secret: strings.Repeat("x", 64)}); e == nil {
		t.Fatal("接受冲突端口")
	}
}
