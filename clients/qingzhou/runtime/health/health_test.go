package health

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"qingzhou.local/runtime/config"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestBootstrapAndRecoveryHysteresis(t *testing.T) {
	a := "00000000-0000-4000-8000-000000000001"
	b := "00000000-0000-4000-8000-000000000002"
	groupID := "00000000-0000-4000-8000-000000000003"
	var mu sync.Mutex
	available := map[string]bool{"node-" + a: false, "node-" + b: true}
	selected := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer test-secret" {
			w.WriteHeader(401)
			return
		}
		if r.Method == "PUT" {
			var v map[string]string
			json.NewDecoder(r.Body).Decode(&v)
			selected = append(selected, v["name"])
			w.WriteHeader(204)
			return
		}
		tag := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/proxies/"), "/delay")
		if !available[tag] {
			w.WriteHeader(504)
			return
		}
		w.Write([]byte(`{"delay":10}`))
	}))
	defer server.Close()
	_, port, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
	n, _ := strconv.Atoi(port)
	request := config.Request{Mode: "rule", Selected: config.Reference{Kind: "group", ID: groupID}, Final: config.Reference{Kind: "selected"}, Groups: []config.Group{{ID: groupID, Kind: "fallback", Members: []config.Reference{{Kind: "node", ID: a}, {Kind: "node", ID: b}}}}}
	next, m, e := Bootstrap(context.Background(), request, API{Control: config.Control{Port: n, Secret: "test-secret"}})
	if e != nil {
		t.Fatal(e)
	}
	if next.Groups[0].Selected.ID != b {
		t.Fatal("未选取首个可用成员")
	}
	mu.Lock()
	available["node-"+a] = true
	mu.Unlock()
	now := time.Now().Add(61 * time.Second)
	if !m.round(context.Background(), now) || len(selected) != 0 {
		t.Fatal("过早切回")
	}
	if !m.round(context.Background(), now.Add(time.Second)) || len(selected) != 1 || selected[0] != "node-"+a {
		t.Fatal("连续成功未切回")
	}
	mu.Lock()
	available["node-"+a] = false
	available["node-"+b] = false
	mu.Unlock()
	if !m.round(context.Background(), now.Add(62*time.Second)) {
		t.Fatal("单次失败即停止")
	}
	if m.round(context.Background(), now.Add(123*time.Second)) {
		t.Fatal("全部失败未停止")
	}
}
func TestReachableClosure(t *testing.T) {
	r := config.Request{Mode: "global", Selected: config.Reference{Kind: "direct"}, Groups: []config.Group{{ID: "unused", Kind: "fallback"}}}
	if len(Groups(r)) != 0 {
		t.Fatal("探测无关策略")
	}
	r.Mode = "direct"
	r.Selected = config.Reference{Kind: "group", ID: "unused"}
	if len(Groups(r)) != 0 {
		t.Fatal("直连模式探测回退")
	}
}
