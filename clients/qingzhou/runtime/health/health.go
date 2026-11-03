// Package health 在原生宿主中维护优先回退，不依赖界面进程定时器。
package health

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"qingzhou.local/runtime/config"
	"strings"
	"sync"
	"time"
)

type API struct{ Control config.Control }

func (a API) call(ctx context.Context, method, path, body string) ([]byte, error) {
	req, e := http.NewRequestWithContext(ctx, method, fmt.Sprintf("http://127.0.0.1:%d%s", a.Control.Port, path), strings.NewReader(body))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+a.Control.Secret)
	req.Header.Set("Content-Type", "application/json")
	resp, e := (&http.Client{Timeout: 8 * time.Second}).Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, 65537))
	if e != nil || len(b) > 65536 || resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, errors.New("核心健康检查失败")
	}
	return b, nil
}
func (a API) Delay(ctx context.Context, tag string) (int64, error) {
	b, e := a.call(ctx, "GET", "/proxies/"+url.PathEscape(tag)+"/delay?timeout=8000&url="+url.QueryEscape("https://www.gstatic.com/generate_204"), "")
	if e != nil {
		return 0, e
	}
	var value struct {
		Delay *int64 `json:"delay"`
	}
	if json.Unmarshal(b, &value) != nil || value.Delay == nil || *value.Delay < 0 {
		return 0, errors.New("测速响应无效")
	}
	return *value.Delay, nil
}
func (a API) Probe(ctx context.Context, tag string) bool { _, e := a.Delay(ctx, tag); return e == nil }

func (a API) Select(ctx context.Context, group, node string) error {
	b, _ := json.Marshal(map[string]string{"name": node})
	_, e := a.call(ctx, "PUT", "/proxies/"+url.PathEscape(group), string(b))
	return e
}
func Groups(r config.Request) []config.Group {
	if r.Mode == "direct" {
		return nil
	}
	groups := map[string]config.Group{}
	for _, g := range r.Groups {
		groups[g.ID] = g
	}
	seen := map[string]bool{}
	result := []config.Group{}
	var visit func(config.Reference)
	visit = func(ref config.Reference) {
		if ref.Kind == "selected" {
			visit(r.Selected)
			return
		}
		if ref.Kind != "group" || seen[ref.ID] {
			return
		}
		seen[ref.ID] = true
		g := groups[ref.ID]
		if g.Kind == "fallback" {
			result = append(result, g)
		}
		for _, m := range g.Members {
			visit(m)
		}
	}
	visit(r.Selected)
	if r.Mode == "rule" {
		visit(r.Final)
		for _, rule := range r.Rules {
			visit(rule.Target)
		}
	}
	return result
}

type state struct {
	group         config.Group
	current       int
	success, fail []int
	changed       time.Time
}
type Manager struct {
	states []state
	api    API
	cancel context.CancelFunc
}

func Bootstrap(ctx context.Context, r config.Request, api API) (config.Request, *Manager, error) {
	manager := &Manager{api: api}
	cache := map[string]bool{}
	for _, g := range Groups(r) {
		pick := -1
		for offset := 0; offset < len(g.Members) && pick < 0; offset += 4 {
			end := min(offset+4, len(g.Members))
			var mu sync.Mutex
			var wg sync.WaitGroup
			pending := []string{}
			seen := map[string]bool{}
			for _, member := range g.Members[offset:end] {
				tag := member.Tag()
				if _, ok := cache[tag]; !ok && !seen[tag] {
					pending = append(pending, tag)
					seen[tag] = true
				}
			}
			for _, tag := range pending {
				wg.Add(1)
				go func() { defer wg.Done(); ok := api.Probe(ctx, tag); mu.Lock(); cache[tag] = ok; mu.Unlock() }()
			}

			wg.Wait()
			if ctx.Err() != nil {
				return r, nil, errors.New("优先回退初始化超时")
			}
			for i := offset; i < end; i++ {
				if cache[g.Members[i].Tag()] {
					pick = i
					break
				}
			}
		}
		if pick < 0 {
			return r, nil, errors.New("优先回退没有可用线路")
		}
		selected := g.Members[pick]
		for i := range r.Groups {
			if r.Groups[i].ID == g.ID {
				r.Groups[i].Selected = &selected
			}
		}
		manager.states = append(manager.states, state{group: g, current: pick, success: make([]int, len(g.Members)), fail: make([]int, len(g.Members)), changed: time.Now()})
	}
	return r, manager, nil
}
func (m *Manager) Start(onFailure func()) {
	if len(m.states) == 0 {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	go func() {
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				if !m.round(ctx, now) {
					if ctx.Err() == nil {
						onFailure()
					}
					return
				}
			}
		}
	}()
}
func (m *Manager) Stop() {
	if m != nil && m.cancel != nil {
		m.cancel()
	}
}
func (m *Manager) round(ctx context.Context, now time.Time) bool {
	tags := map[string]bool{}
	for _, s := range m.states {
		for _, member := range s.group.Members {
			tags[member.Tag()] = false
		}
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	slots := make(chan struct{}, 4)
	keys := make([]string, 0, len(tags))
	for tag := range tags {
		keys = append(keys, tag)
	}
	for _, tag := range keys {
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			return false
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-slots }()
			ok := m.api.Probe(ctx, tag)
			mu.Lock()
			tags[tag] = ok
			mu.Unlock()
		}()
	}
	wg.Wait()
	for index := range m.states {
		s := &m.states[index]
		allFailed := true
		pick := -1
		for i, member := range s.group.Members {
			if tags[member.Tag()] {
				allFailed = false
				s.success[i]++
				s.fail[i] = 0
			} else {
				s.fail[i]++
				s.success[i] = 0
			}
			if pick < 0 && s.success[i] >= 2 {
				pick = i
			}
		}
		if allFailed && s.fail[s.current] >= 2 {
			return false
		}
		if pick < 0 || pick == s.current || now.Sub(s.changed) < 60*time.Second {
			continue
		}
		if pick > s.current && s.fail[s.current] < 2 {
			continue
		}
		if e := m.api.Select(ctx, (config.Reference{Kind: "group", ID: s.group.ID}).Tag(), s.group.Members[pick].Tag()); e != nil {
			return false
		}
		s.current = pick
		s.changed = now
	}
	return true
}
