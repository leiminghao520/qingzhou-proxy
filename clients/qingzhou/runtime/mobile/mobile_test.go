package mobile

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"qingzhou.local/runtime/config"
	"testing"
)

type probeHost struct{ opened bool }

func (h *probeHost) OpenTun(string) (int32, error) {
	h.opened = true
	return -1, errors.New("测速禁止接管网络")
}
func (*probeHost) ProtectSocket(int32) error         { return nil }
func (*probeHost) Interfaces() (string, error)       { return `[]`, nil }
func (*probeHost) DefaultInterface() (string, error) { return `{"Name":"","Index":-1}`, nil }
func (*probeHost) IsExtension() bool                 { return false }

func TestProbeLifecycleWithoutVPN(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	id := "00000000-0000-4000-8000-000000000001"
	request := config.Request{Nodes: []config.Node{{ID: id, Name: "测试", Kind: "trojan", Server: "127.0.0.1", Port: 1, CredentialRef: "fixture", Parameters: map[string]string{}}}, Selected: config.Reference{Kind: "node", ID: id}, Final: config.Reference{Kind: "selected"}, Mode: "rule", Capture: "tun", DNS: "system", Port: port, Credentials: map[string]string{"fixture": "fictional-only"}}
	raw, _ := json.Marshal(request)
	host := &probeHost{}
	directory := t.TempDir()
	session, err := NewSession(directory, host)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Stop()
	if err = session.StartProbe(string(raw)); err != nil {
		t.Fatal(err)
	}
	if host.opened || !session.Running() {
		t.Fatal("测速状态或隔离无效")
	}
	if _, err = session.Query("/version"); err != nil {
		t.Fatal(err)
	}
	if _, err = session.Query("/configs"); err == nil {
		t.Fatal("接受任意控制接口")
	}
	if _, err = os.Stat(filepath.Join(directory, "configuration.json")); !os.IsNotExist(err) {
		t.Fatal("遗留明文配置快照")
	}
	if err = session.Stop(); err != nil {
		t.Fatal(err)
	}
	if session.Running() {
		t.Fatal("停止后仍显示运行")
	}
	if _, err = session.Delay("proxy"); err == nil {
		t.Fatal("断开后仍允许测速")
	}
}
