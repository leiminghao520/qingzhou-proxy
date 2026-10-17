package systemproxy

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var failure = errors.New("模拟 I/O 失败")

type fakeRegistry struct {
	value             Values
	readErr, writeErr error
	writes            int
	partial           bool
}

func (s *fakeRegistry) Read() (Values, error) { return s.value, s.readErr }
func (s *fakeRegistry) Write(v Values) error {
	s.writes++
	if s.writeErr != nil {
		if s.partial {
			s.value.Enable = v.Enable
			s.value.EnablePresent = v.EnablePresent
		}
		return s.writeErr
	}
	s.value = v
	return nil
}

type fakeJournal struct {
	data                         []byte
	loadErr, createErr, clearErr error
}

func (s *fakeJournal) Load() ([]byte, error) {
	if s.loadErr != nil {
		return nil, s.loadErr
	}
	if s.data == nil {
		return nil, os.ErrNotExist
	}
	return s.data, nil
}
func (s *fakeJournal) Create(b []byte) error {
	if s.createErr != nil {
		return s.createErr
	}
	if s.data != nil {
		return os.ErrExist
	}
	s.data = append([]byte{}, b...)
	return nil
}
func (s *fakeJournal) Clear() error {
	if s.clearErr != nil {
		return s.clearErr
	}
	s.data = nil
	return nil
}
func fixture() (Manager, *fakeRegistry, *fakeJournal) {
	r := &fakeRegistry{value: Values{Server: "旧的未启用代理", ServerPresent: true, Override: "原排除项", OverridePresent: true}}
	j := &fakeJournal{}
	return Manager{Registry: r, Journal: j}, r, j
}
func TestCaptureRecoveryAndPartialWrites(t *testing.T) {
	for mask := 0; mask < 8; mask++ {
		m, r, j := fixture()
		before := r.value
		if err := m.Capture(2080); err != nil {
			t.Fatal(err)
		}
		after := r.value
		if after.Enable != 1 || after.Server != "127.0.0.1:2080" || len(j.data) == 0 {
			t.Fatal("接管未持久化")
		}
		if mask&1 == 0 {
			r.value.Enable = before.Enable
			r.value.EnablePresent = before.EnablePresent
		}
		if mask&2 == 0 {
			r.value.Server = before.Server
			r.value.ServerPresent = before.ServerPresent
		}
		if mask&4 == 0 {
			r.value.Override = before.Override
			r.value.OverridePresent = before.OverridePresent
		}
		if err := m.Recover(); err != nil {
			t.Fatal(mask, err)
		}
		if r.value != before || j.data != nil {
			t.Fatal("未恢复原设置")
		}
		if err := m.Recover(); err != nil {
			t.Fatal("重复恢复失败", err)
		}
	}
	m, r, j := fixture()
	before := r.value
	r.writeErr = failure
	r.partial = true
	if m.Capture(2080) == nil || j.data == nil {
		t.Fatal("部分失败没有恢复记录")
	}
	r.writeErr = nil
	if err := m.Recover(); err != nil || r.value != before {
		t.Fatal("部分写入失败无法回滚", err)
	}
}
func TestExternalChangesArePreserved(t *testing.T) {
	edits := []func(*Values){
		func(v *Values) { v.Enable = 2 }, func(v *Values) { v.EnablePresent = false; v.Enable = 1 },
		func(v *Values) { v.Server = "other:8080" }, func(v *Values) { v.ServerPresent = false },
		func(v *Values) { v.Override = "other" }, func(v *Values) { v.OverridePresent = false },
		func(v *Values) { v.PAC = "https://example.com/proxy.pac" }, func(v *Values) { v.PACPresent = true },
	}
	for _, edit := range edits {
		m, r, j := fixture()
		if err := m.Capture(2080); err != nil {
			t.Fatal(err)
		}
		edit(&r.value)
		external := r.value
		if m.Recover() == nil || r.value != external || j.data == nil || r.writes != 1 {
			t.Fatal("覆盖了外部更改")
		}
	}
}
func TestFailuresNeverDiscardJournal(t *testing.T) {
	for _, port := range []int{0, 1023, 65536} {
		m, r, _ := fixture()
		if m.Capture(port) == nil || r.writes != 0 {
			t.Fatal("接受无效端口")
		}
	}
	for _, v := range []Values{{Enable: 1}, {PAC: "https://example.com/pac"}} {
		m, r, _ := fixture()
		r.value = v
		if m.Capture(2080) == nil || r.writes != 0 {
			t.Fatal("覆盖了冲突代理")
		}
	}
	m, r, j := fixture()
	r.readErr = failure
	if m.Capture(2080) == nil || j.data != nil {
		t.Fatal("读取失败后仍接管")
	}
	r.readErr = nil
	j.createErr = failure
	if m.Capture(2080) == nil || r.writes != 0 {
		t.Fatal("记录失败后仍修改网络")
	}
	j.createErr = nil
	if err := m.Capture(2080); err != nil {
		t.Fatal(err)
	}
	r.value = Values{}
	if m.Capture(2080) == nil || r.writes != 1 {
		t.Fatal("覆盖了已有恢复记录")
	}
	j.loadErr = failure
	if m.Recover() == nil {
		t.Fatal("忽略读取失败")
	}
	j.loadErr = nil
	r.readErr = failure
	if m.Recover() == nil || j.data == nil {
		t.Fatal("忽略注册表读取失败")
	}
	r.readErr = nil
	r.value = owned(Values{}, 2080)
	r.writeErr = failure
	// 使用当前记录里的原值，避免恢复检查先被外部变更拦截。
	var saved record
	if err := json.Unmarshal(j.data, &saved); err != nil {
		t.Fatal(err)
	}
	r.value = saved.Owned
	if m.Recover() == nil || j.data == nil {
		t.Fatal("写入失败丢失记录")
	}
	r.writeErr = nil
	j.clearErr = failure
	if m.Recover() == nil || j.data == nil {
		t.Fatal("删除失败没有上报")
	}
	j.clearErr = nil
	if err := m.Recover(); err != nil {
		t.Fatal("重试恢复失败", err)
	}
}
func TestUntrustedJournal(t *testing.T) {
	for _, text := range []string{"{", `{}`, `{"version":2}`, `{"version":1,"extra":true}`, `{} {}`, strings.Repeat("x", 1024*1024+1)} {
		m, r, j := fixture()
		j.data = []byte(text)
		if m.Recover() == nil || r.writes != 0 || j.data == nil {
			t.Fatal("接受损坏记录")
		}
	}
	changes := []func(*record){
		func(r *record) { r.Owned.Server = "remote:2080" }, func(r *record) { r.Owned.Server = "127.0.0.1:80" },
		func(r *record) { r.Owned.Server = "127.0.0.1:bad" }, func(r *record) { r.Owned.Server = "bad" },
		func(r *record) { r.Owned.Enable = 0 }, func(r *record) { r.Before.Enable = 1 }, func(r *record) { r.Before.PAC = "changed" },
	}
	for _, edit := range changes {
		m, r, j := fixture()
		saved := record{Version: 1, Owned: owned(Values{}, 2080)}
		edit(&saved)
		j.data, _ = json.Marshal(saved)
		if m.Recover() == nil || r.writes != 0 {
			t.Fatal("接受伪造的接管记录")
		}
	}
}
func TestFileJournal(t *testing.T) {
	dir := t.TempDir()
	s := FileJournal{Path: filepath.Join(dir, "recovery.json")}
	if _, err := s.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	if err := s.Create([]byte("first")); err != nil {
		t.Fatal(err)
	}
	if s.Create([]byte("second")) == nil {
		t.Fatal("覆盖了现有记录")
	}
	b, err := s.Load()
	if err != nil || string(b) != "first" {
		t.Fatal("记录内容错误", err)
	}
	if err = s.Clear(); err != nil {
		t.Fatal(err)
	}
	if s.Clear() == nil {
		t.Fatal("忽略删除失败")
	}
	s.Path = filepath.Join(dir, "missing", "recovery.json")
	if s.Create(nil) == nil {
		t.Fatal("忽略文件打开失败")
	}
	s.Path = dir
	if _, err = s.Load(); err == nil {
		t.Fatal("目录被当作记录")
	}
}
