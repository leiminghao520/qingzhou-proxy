package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

var diagnosticMu sync.Mutex

func diagnostic(stage, category string, started time.Time, count uint64) {
	diagnosticMu.Lock()
	defer diagnosticMu.Unlock()
	// 仅输出固定阶段、错误类别、耗时和计数，不包含连接内容。
	_ = json.NewEncoder(os.Stderr).Encode(struct {
		Stage    string `json:"stage"`
		Category string `json:"category"`
		Elapsed  int64  `json:"elapsedMs"`
		Count    uint64 `json:"count"`
	}{stage, category, time.Since(started).Milliseconds(), count})
}

type trackedConnection struct {
	net.Conn
	owner *mixedListener
	once  sync.Once
}

func (c *trackedConnection) Close() error {
	var err error
	c.once.Do(func() { err = c.Conn.Close(); c.owner.mu.Lock(); delete(c.owner.connections, c); c.owner.mu.Unlock() })
	return err
}
func (c *trackedConnection) CloseWrite() error {
	if tcp, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return tcp.CloseWrite()
	}
	return c.Close()
}
func (c *bufferedConnection) CloseWrite() error {
	if tcp, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return tcp.CloseWrite()
	}
	return c.Close()
}

type mixedListener struct {
	net.Listener
	corePort         int
	ready            chan net.Conn
	slots            chan struct{}
	done             chan struct{}
	mu               sync.Mutex
	closed           bool
	connections      map[*trackedConnection]struct{}
	workers          sync.WaitGroup
	rejected         uint64
	firstByteTimeout time.Duration
}

func newMixedListener(raw net.Listener, corePort int) *mixedListener {
	l := &mixedListener{Listener: raw, corePort: corePort, ready: make(chan net.Conn, 256), slots: make(chan struct{}, 256), done: make(chan struct{}), connections: make(map[*trackedConnection]struct{}), firstByteTimeout: 10 * time.Second}
	l.workers.Add(1)
	go l.receive()
	return l
}
func (l *mixedListener) track(raw net.Conn) (net.Conn, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		_ = raw.Close()
		return nil, false
	}
	c := &trackedConnection{Conn: raw, owner: l}
	l.connections[c] = struct{}{}
	return c, true
}
func (l *mixedListener) receive() {
	defer l.workers.Done()
	for {
		raw, err := l.Listener.Accept()
		if err != nil {
			_ = l.Close()
			return
		}
		conn, ok := l.track(raw)
		if !ok {
			return
		}
		select {
		case l.slots <- struct{}{}:
			l.workers.Add(1)
			go l.identify(conn)
		default:
			_ = conn.Close()
			l.rejected++
			diagnostic("identify", "limit", time.Now(), l.rejected)
		}
	}
}
func (l *mixedListener) identify(conn net.Conn) {
	defer l.workers.Done()
	var release sync.Once
	free := func() { release.Do(func() { <-l.slots }) }
	defer free()
	start := time.Now()
	_ = conn.SetReadDeadline(start.Add(l.firstByteTimeout))
	reader := bufio.NewReader(conn)
	first, err := reader.Peek(1)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		category := "cancelled"
		if e, ok := err.(net.Error); ok && e.Timeout() {
			category = "timeout"
		}
		diagnostic("identify", category, start, 1)
		_ = conn.Close()
		return
	}
	if first[0] == 5 {
		free()
		defer conn.Close()
		raw, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", l.corePort), 5*time.Second)
		if err != nil {
			diagnostic("socks", "upstream", start, 1)
			return
		}
		upstream, ok := l.track(raw)
		if !ok {
			return
		}
		defer upstream.Close()
		// 缓冲区保留已读取的协议首字节及后续数据。
		relayEntry("socks", conn, reader, upstream, upstream)
		return
	}
	select {
	case l.ready <- &bufferedConnection{conn, reader}:
	case <-l.done:
		_ = conn.Close()
	}
}
func (l *mixedListener) Accept() (net.Conn, error) {
	select {
	case <-l.done:
		return nil, net.ErrClosed
	case conn := <-l.ready:
		select {
		case <-l.done:
			_ = conn.Close()
			return nil, net.ErrClosed
		default:
			return conn, nil
		}
	}
}
func (l *mixedListener) Close() error {
	l.mu.Lock()
	if l.closed {
		l.mu.Unlock()
		return nil
	}
	l.closed = true
	close(l.done)
	connections := make([]*trackedConnection, 0, len(l.connections))
	for c := range l.connections {
		connections = append(connections, c)
	}
	l.mu.Unlock()
	err := l.Listener.Close()
	for _, c := range connections {
		_ = c.Close()
	}
	return err
}
func (l *mixedListener) wait() { l.workers.Wait() }
func relay(left net.Conn, leftReader io.Reader, right net.Conn, rightReader io.Reader) {
	relayEntry("connect", left, leftReader, right, rightReader)
}
func relayEntry(entry string, left net.Conn, leftReader io.Reader, right net.Conn, rightReader io.Reader) {
	start := time.Now()
	type result struct {
		direction int
		n         int64
		err       error
	}
	results := make(chan result, 2)
	copySide := func(direction int, dst net.Conn, src io.Reader) {
		n, err := io.Copy(dst, src)
		if err == nil {
			if half, ok := dst.(interface{ CloseWrite() error }); ok {
				err = half.CloseWrite()
			}
		}
		results <- result{direction, n, err}
	}
	go copySide(0, right, leftReader)
	go copySide(1, left, rightReader)
	first := <-results
	// 正常上传结束后继续等待响应；活动连接由监听器关闭或对端错误终止。
	if first.err != nil {
		_ = left.Close()
		_ = right.Close()
	}
	other := <-results
	category := "ok"
	if first.err != nil {
		category = errorCategory(first.err, "upstream")
	} else if other.err != nil {
		category = errorCategory(other.err, "upstream")
	}
	var sent, received int64
	for _, r := range []result{first, other} {
		if r.direction == 0 {
			sent = r.n
		} else {
			received = r.n
		}
	}
	transferDiagnostic(entry, "relay", category, start, sent, received)
	_ = left.Close()
	_ = right.Close()
}
