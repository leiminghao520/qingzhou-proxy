package main

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
	types := []string{"A"}
	if network != "ip4" {
		types = append(types, "AAAA")
	}
	client := &http.Client{Transport: g.transports["PROXY"], Timeout: 8 * time.Second}
	var ips []netip.Addr
	for _, kind := range types {
		req, err := http.NewRequestWithContext(ctx, "GET", "https://1.1.1.1/dns-query?name="+url.QueryEscape(host)+"&type="+kind, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/dns-json")
		res, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		var answer struct {
			Status int
			Answer []struct {
				Type int
				Data string
			}
		}
		err = json.NewDecoder(io.LimitReader(res.Body, 65536)).Decode(&answer)
		res.Body.Close()
		if res.StatusCode != 200 || err != nil || answer.Status != 0 {
			return nil, fmt.Errorf("proxy DNS resolution failed")
		}
		for _, record := range answer.Answer {
			if (kind == "A" && record.Type == 1) || (kind == "AAAA" && record.Type == 28) {
				if ip, e := netip.ParseAddr(record.Data); e == nil {
					ips = append(ips, ip)
				}
			}
		}
	}
	ips = orderAddresses(ips, g.config.AddressFamilyPolicy)
	if len(ips) == 0 {
		return nil, fmt.Errorf("no address for configured family")
	}
	return ips, nil
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
func transferDiagnostic(entry, stage, category string, start time.Time, sent, received int64) {
	diagnosticMu.Lock()
	defer diagnosticMu.Unlock()
	// 只记录固定入口和传输计数，不记录目标、凭据、请求头或正文。
	_ = json.NewEncoder(os.Stderr).Encode(struct {
		Entry    string `json:"entry"`
		Stage    string `json:"stage"`
		Category string `json:"category"`
		Elapsed  int64  `json:"elapsedMs"`
		Count    uint64 `json:"count"`
		Sent     int64  `json:"sentBytes"`
		Received int64  `json:"receivedBytes"`
	}{entry, stage, category, time.Since(start).Milliseconds(), 1, sent, received})
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
