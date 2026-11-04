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

// 替换输出与时钟，返回读取已输出行的函数；全局状态都在对应的锁内访问，其他测试遗留的连接收尾时也不会竞争。
// 这些连接可能写入诊断，因此只返回本测试入口的行。
func captureTransfers(t *testing.T, entry string) (func() []transferLine, func(time.Duration)) {
	t.Helper()
	var buffer bytes.Buffer
	now := time.Unix(1_700_000_000, 0)
	transferFlushOnce.Do(func() {})
	diagnosticMu.Lock()
	previousOutput := diagnosticOutput
	diagnosticOutput = &buffer
	diagnosticMu.Unlock()
	transferMu.Lock()
	previousNow := transferNow
	transferNow = func() time.Time { return now }
	transferOK = map[[2]string]*transferAggregate{}
	transferFailures = map[[3]string]*transferAggregate{}
	transferLastFailed = map[[3]string]time.Time{}
	transferMu.Unlock()
	t.Cleanup(func() {
		diagnosticMu.Lock()
		diagnosticOutput = previousOutput
		diagnosticMu.Unlock()
		transferMu.Lock()
		transferNow = previousNow
		transferMu.Unlock()
	})
	read := func() []transferLine {
		diagnosticMu.Lock()
		raw := buffer.String()
		buffer.Reset()
		diagnosticMu.Unlock()
		var lines []transferLine
		for _, row := range strings.Split(strings.TrimSpace(raw), "\n") {
			if row == "" {
				continue
			}
			var line transferLine
			if err := json.Unmarshal([]byte(row), &line); err != nil {
				t.Fatalf("诊断行不是 JSON：%q", row)
			}
			if line.Entry == entry {
				lines = append(lines, line)
			}
		}
		return lines
	}
	advance := func(step time.Duration) {
		transferMu.Lock()
		now = now.Add(step)
		transferMu.Unlock()
	}
	return read, advance
}

func TestSuccessfulTransfersAreAggregated(t *testing.T) {
	read, _ := captureTransfers(t, "test-aggregate")
	for i := 0; i < 7; i++ {
		transferDiagnostic("test-aggregate", "relay", "ok", time.Now(), 25, 12)
	}
	transferDiagnostic("test-aggregate", "relay", "ok", time.Now().Add(-time.Second), 623, 6293)
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
	read, _ := captureTransfers(t, "socks")
	transferDiagnostic("socks", "relay", "ok", time.Now(), 530, 12)
	var lines []transferLine
	for _, line := range read() {
		if line.Category == "noResponse" {
			lines = append(lines, line)
		}
	}
	if len(lines) != 1 {
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
	read, advance := captureTransfers(t, "test-failure")
	for i := 0; i < 4; i++ {
		transferDiagnostic("test-failure", "relay", "upstream", time.Now(), 3, 2)
	}
	if lines := read(); len(lines) != 1 || lines[0].Count != 1 {
		t.Fatalf("首次失败应立即输出且只输出一次：%+v", lines)
	}
	flushTransferDiagnostics()
	if lines := read(); len(lines) != 1 || lines[0].Count != 3 || lines[0].Category != "upstream" {
		t.Fatalf("窗口内重复失败应合并计数：%+v", lines)
	}
	advance(relayFailureWindow)
	transferDiagnostic("test-failure", "relay", "upstream", time.Now(), 3, 2)
	if lines := read(); len(lines) != 1 {
		t.Fatalf("窗口过后再次失败应立即输出：%+v", lines)
	}
}
