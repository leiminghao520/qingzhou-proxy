package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

var errIPv6Unavailable = errors.New("IPv6 is disabled by address family policy")

func orderAddresses(ips []netip.Addr, policy string) []netip.Addr {
	result := make([]netip.Addr, 0, len(ips))
	for _, ip := range ips {
		ip = ip.Unmap()
		if (policy == "" || policy == "ipv4Only") && !ip.Is4() {
			continue
		}
		result = append(result, ip)
	}
	if policy == "preferIPv4" {
		sort.SliceStable(result, func(i, j int) bool { return result[i].Is4() && !result[j].Is4() })
	}
	return result
}
func (g *gateway) lookupProxy(ctx context.Context, host, network string) ([]netip.Addr, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	types := []string{"A"}
	if network != "ip4" {
		types = append(types, "AAAA")
	}
	type answerResult struct {
		ips []netip.Addr
		err error
	}
	answers := make(chan answerResult, len(types))
	for _, kind := range types {
		go func(kind string) {
			req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("http://127.0.0.1:%d/dns/query?name=%s&type=%s", g.config.ControlPort, url.QueryEscape(host), kind), nil)
			if err != nil {
				answers <- answerResult{err: err}
				return
			}
			req.Header.Set("Authorization", "Bearer "+g.config.Secret)
			// 解析使用独立八秒预算，不能继承模式查询的三秒上限。
			resolver := &http.Client{Transport: g.control.Transport, Timeout: 8 * time.Second}
			res, err := resolver.Do(req)
			if err != nil {
				answers <- answerResult{err: err}
				return
			}
			defer res.Body.Close()
			var answer struct {
				Status int
				Answer []struct {
					Type int
					Data string
				}
			}
			err = json.NewDecoder(io.LimitReader(res.Body, 65536)).Decode(&answer)
			if res.StatusCode != 200 || err != nil || answer.Status != 0 {
				answers <- answerResult{err: fmt.Errorf("core DNS resolution failed")}
				return
			}
			var ips []netip.Addr
			for _, record := range answer.Answer {
				if (kind == "A" && record.Type == 1) || (kind == "AAAA" && record.Type == 28) {
					if ip, e := netip.ParseAddr(strings.TrimSpace(record.Data)); e == nil {
						ips = append(ips, ip)
					}
				}
			}
			answers <- answerResult{ips: ips}
		}(kind)
	}
	var ips []netip.Addr
	var lastError error
	for range types {
		select {
		case result := <-answers:
			ips = append(ips, result.ips...)
			if result.err != nil {
				lastError = result.err
			}
		case <-ctx.Done():
			if len(ips) > 0 && ctx.Err() == context.DeadlineExceeded {
				return orderAddresses(ips, g.config.AddressFamilyPolicy), nil
			}
			return nil, ctx.Err()
		}
	}
	ips = orderAddresses(ips, g.config.AddressFamilyPolicy)
	if len(ips) > 0 {
		return ips, nil
	}
	if lastError != nil {
		return nil, lastError
	}
	return nil, fmt.Errorf("no address for configured family")
}
func hasToken(value, token string) bool {
	for _, v := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(v), token) {
			return true
		}
	}
	return false
}

type flushWriter struct {
	writer     http.ResponseWriter
	controller *http.ResponseController
}

func (w flushWriter) Write(data []byte) (int, error) {
	n, err := w.writer.Write(data)
	if err == nil {
		err = w.controller.Flush()
	}
	return n, err
}

// 传输诊断输出目标；测试可替换为缓冲区。
var diagnosticOutput io.Writer = os.Stderr

const (
	relayAggregateWindow = 30 * time.Second
	relayFailureWindow   = 10 * time.Second
	// SOCKS5 无认证握手：问候回包 2 字节加 IPv4 CONNECT 回包 10 字节。
	socksReplyBytes = 12
	// 客户端问候与 CONNECT 请求的最小长度，超过即表示已发送业务数据。
	socksRequestBytes = 25
)

type transferAggregate struct {
	count      uint64
	sent       int64
	received   int64
	maxElapsed int64
}

var (
	transferMu         sync.Mutex
	transferOK         = map[[2]string]*transferAggregate{}
	transferFailures   = map[[3]string]*transferAggregate{}
	transferLastFailed = map[[3]string]time.Time{}
	transferFlushOnce  sync.Once
	transferNow        = time.Now
)

func emitTransfer(entry, stage, category string, elapsed int64, count uint64, sent, received int64) {
	diagnosticMu.Lock()
	defer diagnosticMu.Unlock()
	// 只记录固定入口和传输计数，不记录目标、凭据、请求头或正文。
	_ = json.NewEncoder(diagnosticOutput).Encode(struct {
		Entry    string `json:"entry"`
		Stage    string `json:"stage"`
		Category string `json:"category"`
		Elapsed  int64  `json:"elapsedMs"`
		Count    uint64 `json:"count"`
		Sent     int64  `json:"sentBytes"`
		Received int64  `json:"receivedBytes"`
	}{entry, stage, category, elapsed, count, sent, received})
}

// 已发送业务数据却只收到 SOCKS 握手回包就结束，说明上游未响应，不能记为成功。
func transferCategory(entry, category string, sent, received int64) string {
	if category == "ok" && entry == "socks" && sent > socksRequestBytes && received <= socksReplyBytes {
		return "noResponse"
	}
	return category
}

func (a *transferAggregate) add(elapsed int64, sent, received int64) {
	a.count++
	a.sent += sent
	a.received += received
	if elapsed > a.maxElapsed {
		a.maxElapsed = elapsed
	}
}

// 成功传输按入口汇总，每个窗口输出一行；失败逐类首次立即输出，窗口内重复的合并计数。
func transferDiagnostic(entry, stage, category string, start time.Time, sent, received int64) {
	transferFlushOnce.Do(func() {
		go func() {
			ticker := time.NewTicker(relayAggregateWindow)
			for range ticker.C {
				flushTransferDiagnostics()
			}
		}()
	})
	category = transferCategory(entry, category, sent, received)
	elapsed := time.Since(start).Milliseconds()
	transferMu.Lock()
	if category == "ok" {
		key := [2]string{entry, stage}
		if transferOK[key] == nil {
			transferOK[key] = &transferAggregate{}
		}
		transferOK[key].add(elapsed, sent, received)
		transferMu.Unlock()
		return
	}
	key := [3]string{entry, stage, category}
	now := transferNow()
	if last, ok := transferLastFailed[key]; ok && now.Sub(last) < relayFailureWindow {
		if transferFailures[key] == nil {
			transferFailures[key] = &transferAggregate{}
		}
		transferFailures[key].add(elapsed, sent, received)
		transferMu.Unlock()
		return
	}
	transferLastFailed[key] = now
	transferMu.Unlock()
	emitTransfer(entry, stage, category, elapsed, 1, sent, received)
}

// 输出并清空当前窗口内的汇总；退出前也应调用，避免丢失最后一个窗口。
func flushTransferDiagnostics() {
	transferMu.Lock()
	ok, failures := transferOK, transferFailures
	transferOK = map[[2]string]*transferAggregate{}
	transferFailures = map[[3]string]*transferAggregate{}
	transferMu.Unlock()
	for key, a := range ok {
		emitTransfer(key[0], key[1], "ok", a.maxElapsed, a.count, a.sent, a.received)
	}
	for key, a := range failures {
		emitTransfer(key[0], key[1], key[2], a.maxElapsed, a.count, a.sent, a.received)
	}
}
func (g *gateway) upgrade(w http.ResponseWriter, r *http.Request, response *http.Response, start time.Time) {
	upstream, ok := response.Body.(io.ReadWriteCloser)
	if !ok {
		http.Error(w, "Upgrade unavailable", 502)
		return
	}
	h, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "Upgrade unavailable", 500)
		return
	}
	client, buffer, err := h.Hijack()
	if err != nil {
		return
	}
	defer client.Close()
	// 只保留升级必需的逐跳字段，不向客户端泄露内部代理认证。
	upgrade := response.Header.Get("Upgrade")
	removeHopHeaders(response.Header)
	response.Header.Set("Connection", "Upgrade")
	response.Header.Set("Upgrade", upgrade)
	fmt.Fprint(buffer, "HTTP/1.1 101 Switching Protocols\r\n")
	if err = response.Header.Write(buffer); err != nil {
		return
	}
	fmt.Fprint(buffer, "\r\n")
	if err = buffer.Flush(); err != nil {
		return
	}
	type result struct {
		n      int64
		err    error
		upload bool
	}
	done := make(chan result, 2)
	go func() { n, e := io.Copy(upstream, buffer); done <- result{n, e, true} }()
	go func() { n, e := io.Copy(client, upstream); done <- result{n, e, false} }()
	first := <-done
	client.Close()
	upstream.Close()
	second := <-done
	var sent, received int64
	for _, v := range []result{first, second} {
		if v.upload {
			sent = v.n
		} else {
			received = v.n
		}
	}
	category := "ok"
	if first.err != nil {
		category = errorCategory(first.err, "upstream")
	}
	transferDiagnostic("upgrade", "relay", category, start, sent, received)
}
