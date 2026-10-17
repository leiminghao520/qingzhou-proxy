// Package systemproxy 管理系统代理的接管事务和所有权恢复，不依赖具体注册表实现。
package systemproxy

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"strconv"
)

type Values struct {
	Enable          uint32 `json:"enable"`
	Server          string `json:"server"`
	Override        string `json:"override"`
	PAC             string `json:"pac"`
	EnablePresent   bool   `json:"enablePresent"`
	ServerPresent   bool   `json:"serverPresent"`
	OverridePresent bool   `json:"overridePresent"`
	PACPresent      bool   `json:"pacPresent"`
}
type Registry interface {
	Read() (Values, error)
	Write(Values) error
}
type JournalStore interface {
	Load() ([]byte, error)
	Create([]byte) error
	Clear() error
}
type Manager struct {
	Registry Registry
	Journal  JournalStore
}
type record struct {
	Version int    `json:"version"`
	Before  Values `json:"before"`
	Owned   Values `json:"owned"`
}

func owned(before Values, port int) Values {
	after := before
	after.Enable = 1
	after.EnablePresent = true
	after.Server = net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	after.ServerPresent = true
	after.Override = "localhost;127.*;[::1]"
	after.OverridePresent = true
	return after
}

func (m Manager) Capture(port int) error {
	if port < 1024 || port > 65535 {
		return errors.New("监听端口无效")
	}
	before, err := m.Registry.Read()
	if err != nil {
		return errors.New("用户网络设置读取失败")
	}
	if before.Enable != 0 || before.PAC != "" {
		return errors.New("检测到其他代理或 PAC，请先处理冲突")
	}
	after := owned(before, port)
	data, _ := json.Marshal(record{Version: 1, Before: before, Owned: after})
	// 恢复记录持久化成功之后才能修改网络；已有记录必须先恢复。
	if err = m.Journal.Create(data); err != nil {
		return err
	}
	if err = m.Registry.Write(after); err != nil {
		return err
	}
	actual, err := m.Registry.Read()
	if err != nil || actual != after {
		return errors.New("系统代理写入后核验失败，恢复记录已保留")
	}
	return nil
}

func (m Manager) Recover() error {
	data, err := m.Journal.Load()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if len(data) > 1024*1024 {
		return errors.New("恢复记录过大")
	}
	var saved record
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&saved) != nil || decoder.Decode(new(any)) != io.EOF || saved.Version != 1 {
		return errors.New("恢复记录损坏或版本不支持")
	}
	address, portText, err := net.SplitHostPort(saved.Owned.Server)
	port, portErr := strconv.Atoi(portText)
	if err != nil || portErr != nil || address != "127.0.0.1" || port < 1024 || port > 65535 || saved.Owned != owned(saved.Before, port) || saved.Before.Enable != 0 || saved.Before.PAC != "" {
		return errors.New("恢复记录的接管设置无效")
	}
	current, err := m.Registry.Read()
	if err != nil {
		return errors.New("用户网络设置读取失败，恢复记录已保留")
	}
	matches := func(a, b, c any, ap, bp, cp bool) bool { return (a == b && ap == bp) || (a == c && ap == cp) }
	// 逐字段接受原值或本次写入值，既允许部分写入失败，也保留外部修改。
	if !matches(current.Enable, saved.Before.Enable, saved.Owned.Enable, current.EnablePresent, saved.Before.EnablePresent, saved.Owned.EnablePresent) ||
		!matches(current.Server, saved.Before.Server, saved.Owned.Server, current.ServerPresent, saved.Before.ServerPresent, saved.Owned.ServerPresent) ||
		!matches(current.Override, saved.Before.Override, saved.Owned.Override, current.OverridePresent, saved.Before.OverridePresent, saved.Owned.OverridePresent) ||
		current.PAC != saved.Before.PAC || current.PACPresent != saved.Before.PACPresent {
		return errors.New("网络设置已被外部修改，恢复记录已保留")
	}
	if err = m.Registry.Write(saved.Before); err != nil {
		return err
	}
	actual, err := m.Registry.Read()
	if err != nil || actual != saved.Before {
		return errors.New("系统代理恢复后核验失败，恢复记录已保留")
	}
	return m.Journal.Clear()
}

type FileJournal struct{ Path string }

func (s FileJournal) Load() ([]byte, error) {
	f, err := os.Open(s.Path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, 1024*1024+1))
}
func (s FileJournal) Create(data []byte) error {
	f, err := os.OpenFile(s.Path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func (s FileJournal) Clear() error { return os.Remove(s.Path) }
