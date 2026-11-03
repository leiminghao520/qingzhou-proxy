package gateway

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type transferLine struct {
	Entry    string `json:"entry"`
	Category string `json:"category"`
	Elapsed  int64  `json:"elapsedMs"`
	Count    uint64 `json:"count"`
	Sent     int64  `json:"sentBytes"`
	Received int64  `json:"receivedBytes"`
}

// 替换输出与时钟，返回读取已输出行的函数；测试结束恢复全局状态。
func captureTransfers(t *testing.T) (func() []transferLine, *time.Time) {
	t.Helper()
	var buffer bytes.Buffer
	now := time.Unix(1_700_000_000, 0)
	previousOutput, previousNow := diagnosticOutput, transferNow
	diagnosticOutput = &buffer
	transferNow = func() time.Time { return now }
	transferFlushOnce.Do(func() {})
	transferMu.Lock()
	transferOK = map[[2]string]*transferAggregate{}
	transferFailures = map[[3]string]*transferAggregate{}
	transferLastFailed = map[[3]string]time.Time{}
	transferMu.Unlock()
	t.Cleanup(func() { diagnosticOutput, transferNow = previousOutput, previousNow })
	return func() []transferLine {
		var lines []transferLine
		for _, raw := range strings.Split(strings.TrimSpace(buffer.String()), "\n") {
			if raw == "" {
				continue
			}
			var line transferLine
			if err := json.Unmarshal([]byte(raw), &line); err != nil {
				t.Fatalf("诊断行不是 JSON：%q", raw)
			}
			lines = append(lines, line)
		}
		buffer.Reset()
		return lines
	}, &now
}

func TestSuccessfulTransfersAreAggregated(t *testing.T) {
	read, _ := captureTransfers(t)
	for i := 0; i < 7; i++ {
		transferDiagnostic("socks", "relay", "ok", time.Now(), 25, 12)
	}
	transferDiagnostic("socks", "relay", "ok", time.Now().Add(-time.Second), 623, 6293)
	if lines := read(); len(lines) != 0 {
		t.Fatalf("成功传输不应逐条输出：%v", lines)
	}
	flushTransferDiagnostics()
	lines := read()
	if len(lines) != 1 || lines[0].Count != 8 || lines[0].Sent != 7*25+623 || lines[0].Received != 7*12+6293 || lines[0].Elapsed < 1000 {
		t.Fatalf("汇总不正确：%+v", lines)
	}
	flushTransferDiagnostics()
	if lines := read(); len(lines) != 0 {
		t.Fatalf("空窗口不应输出：%v", lines)
	}
}

func TestSilentUpstreamIsNotReportedAsSuccess(t *testing.T) {
	read, _ := captureTransfers(t)
	transferDiagnostic("socks", "relay", "ok", time.Now(), 530, 12)
	lines := read()
	if len(lines) != 1 || lines[0].Category != "noResponse" {
		t.Fatalf("只收到握手回包应记为 noResponse：%+v", lines)
	}
	if got := transferCategory("socks", "ok", 25, 12); got != "ok" {
		t.Fatalf("仅握手后关闭不应判为无响应：%s", got)
	}
	if got := transferCategory("connect", "ok", 530, 0); got != "ok" {
		t.Fatalf("非 SOCKS 入口不按握手长度判断：%s", got)
	}
}

func TestRepeatedFailuresAreMergedWithinWindow(t *testing.T) {
	read, now := captureTransfers(t)
	for i := 0; i < 4; i++ {
		transferDiagnostic("socks", "relay", "upstream", time.Now(), 3, 2)
	}
	if lines := read(); len(lines) != 1 || lines[0].Count != 1 {
		t.Fatalf("首次失败应立即输出且只输出一次：%+v", lines)
	}
	flushTransferDiagnostics()
	if lines := read(); len(lines) != 1 || lines[0].Count != 3 || lines[0].Category != "upstream" {
		t.Fatalf("窗口内重复失败应合并计数：%+v", lines)
	}
	*now = now.Add(relayFailureWindow)
	transferDiagnostic("socks", "relay", "upstream", time.Now(), 3, 2)
	if lines := read(); len(lines) != 1 {
		t.Fatalf("窗口过后再次失败应立即输出：%+v", lines)
	}
}
