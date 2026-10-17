//go:build windows

package main

import (
	"encoding/json"
	"testing"
)

func TestDisconnectedDiagnosticsAreNotReportedAsSuccess(t *testing.T) {
	var host service
	for _, method := range []message{{Method: "status"}, {Method: "query", Arguments: "/diagnostics"}} {
		raw, err := host.call(method)
		if err != nil {
			t.Fatal(err)
		}
		var report struct {
			State       string `json:"state"`
			CoreRunning bool   `json:"coreRunning"`
			Diagnostics map[string]struct {
				State string `json:"state"`
			} `json:"diagnostics"`
		}
		if err := json.Unmarshal([]byte(raw), &report); err != nil {
			t.Fatal(err)
		}
		if report.State != "disconnected" || report.CoreRunning {
			t.Fatal("未运行的核心状态错误", report)
		}
		for name, check := range report.Diagnostics {
			if check.State == "passed" {
				t.Fatal("未运行的检查不能标记通过", name)
			}
		}
	}
	host.recoveryErr = true
	if err := json.Unmarshal([]byte(host.report(false)), new(map[string]any)); err != nil {
		t.Fatal(err)
	}
	var report map[string]any
	json.Unmarshal([]byte(host.report(false)), &report)
	if report["state"] != "recoveryRequired" {
		t.Fatal(report)
	}
}

func TestCapabilitiesExposeDiagnosticsAndReadOnlyBuildIdentity(t *testing.T) {
	var host service
	raw, err := host.call(message{Method: "capabilities"})
	if err != nil {
		t.Fatal(err)
	}
	var capabilities map[string]any
	if err = json.Unmarshal([]byte(raw), &capabilities); err != nil {
		t.Fatal(err)
	}
	if capabilities["diagnostics"] != true || capabilities["coreVersion"] != "1.14.3" {
		t.Fatal(capabilities)
	}
	if _, err = host.call(message{Method: "query", Arguments: "/diagnostics?target=http://example.invalid"}); err == nil {
		t.Fatal("诊断接口接受了任意目标")
	}
}
