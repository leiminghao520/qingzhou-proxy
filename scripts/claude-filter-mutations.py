#!/usr/bin/env python3
"""在独立构建目录执行定向变异，不修改工作区源码或系统网络。"""
import json
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parent.parent
stage = root / ".build/claude-filter-mutations"
stage.mkdir(parents=True, exist_ok=True)
files = ["ClaudeApplicationPolicy.swift", "ClaudeSafetyStateMachine.swift", "ClaudeNetworkFilterClient.swift"]
originals = {}
for name in files:
    text = "import QingzhouKit\n" + (root / "Sources/QingzhouKit" / name).read_text()
    originals[name] = text
    (stage / name).write_text(text)
for source in (root / "Tests/ClaudeSafetyTests").glob("*.swift"):
    (stage / source.name).write_text(source.read_text())

mutations = [
    ("未知进程放行", files[0], "case .unresolved:\n            return false", "case .unresolved:\n            return true"),
    ("绕过专用端口", files[0], "destination.port == localProxyPort", "destination.port != 0"),
    ("允许 UDP 访问代理", files[0], "destination.transport == .tcp", "destination.transport != .unsupported"),
    ("代理任意出口", files[0], "return upstream.matches(destination)", "return destination.port != 0"),
    ("关闭后仍允许连接", files[0], "guard proxyAccessEnabled, let destination", "guard let destination"),
    ("未来时间证据有效", files[1], "age >= 0 && age < 15", "age < 15"),
    ("过期证据有效", files[1], "age >= 0 && age < 15", "age >= 0"),
    ("DNS 未核验也生效", files[1], "&& dnsProtected && ipv6Protected", "&& ipv6Protected"),
    ("子进程未覆盖也生效", files[1], "&& applicationsCovered && descendantsCovered", "&& applicationsCovered"),
    ("崩溃阻断未核验也生效", files[1], "&& crashBlockingVerified && existingConnectionsCovered", "&& existingConnectionsCovered"),
    ("操作标识不核对", files[1], "next.operationID == record.operationID", "true"),
    ("关闭中旧核验恢复绿色", files[1], "phase != .disabling, phase != .disabledBlocked", "true"),
    ("关闭时未验证阻断", files[1], "blockVerified && settingsRestored", "settingsRestored"),
    ("新开启覆盖原恢复快照", files[1], "previous: record.previous", "previous: next.previous"),
    ("允许全局可读恢复文件", files[1], "mode.intValue & 0o077 == 0", "true"),
]

sources = [str(path) for path in sorted(stage.glob("*.swift"))]
objects = []
for pattern in ["QingzhouKit.build/*.o", "CQingzhouRoute.build/*.o", "Yams.build/*.o", "CYaml.build/src/*.o"]:
    objects.extend(str(path) for path in (root / ".build/debug").glob(pattern))
command = ["swiftc", "-parse-as-library", "-swift-version", "5", "-I", str(root / ".build/debug/Modules"),
           "-I", str(root / "Vendor/Yams/Sources/CYaml/include"), "-Xcc",
           "-fmodule-map-file=" + str(root / ".build/debug/CQingzhouRoute.build/module.modulemap"),
           "-module-cache-path", str(root / ".build/module-cache"), *sources, *objects, "-o", str(stage / "checks")]


def run_case(name):
    with (stage / "build.log").open("w") as output:
        compiled = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=120)
    if compiled.returncode:
        return "BUILD_ERROR"
    with (stage / "checks.log").open("w") as output:
        checked = subprocess.run([str(stage / "checks")], cwd=root, stdout=output, stderr=subprocess.STDOUT, timeout=30)
    (stage / (name + ".log")).write_bytes((stage / "checks.log").read_bytes())
    return "KILLED" if checked.returncode else "SURVIVED"


if run_case("baseline") != "SURVIVED":
    raise SystemExit("基线检查失败，不能计算变异检出率；请查看 .build/claude-filter-mutations/build.log 和 baseline.log")

results = []
for index, (name, filename, old, new) in enumerate(mutations):
    if old not in originals[filename]:
        raise SystemExit("变异位置不存在：" + name)
    try:
        (stage / filename).write_text(originals[filename].replace(old, new))
        status = run_case(str(index))
        results.append({"name": name, "status": status})
        print(status, name, flush=True)
    finally:
        (stage / filename).write_text(originals[filename])

summary = {"scope": "仅应用策略和状态机的 15 个定向变异，不代表全项目或系统扩展实机验证",
           "results": results, "killed": sum(item["status"] == "KILLED" for item in results),
           "survived": sum(item["status"] == "SURVIVED" for item in results),
           "buildErrors": sum(item["status"] == "BUILD_ERROR" for item in results)}
(stage / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print("RESULT " + json.dumps({key: value for key, value in summary.items() if key != "results"}, ensure_ascii=False))
raise SystemExit(0 if summary["killed"] == len(mutations) else 1)
