#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
STAGE = ROOT / ".build/runtime-optimization-mutations"
STAGE.mkdir(parents=True, exist_ok=True)
for name in ("Sources", "scripts"):
    shutil.copytree(ROOT / name, STAGE / name, dirs_exist_ok=True)
shutil.copy2(ROOT / "Package.swift", STAGE / "Package.swift")
for name in ("Vendor", "Resources"):
    if not (STAGE / name).exists():
        (STAGE / name).symlink_to(ROOT / name, target_is_directory=True)

# 定向变异只证明这些行为受到测试保护，不冒充全项目变异覆盖率。
mutations = [
    ("重连等待错误", "TrafficMonitor.swift", "[1, 2, 4, 8, 16, 30]", "[2, 2, 4, 8, 16, 30]"),
    ("样本不重置退避", "TrafficMonitor.swift", "                    attempt = 0", "                    attempt += 0"),
    ("断线不通知", "TrafficMonitor.swift", "            disconnected()", "            _ = disconnected"),
    ("暂停仍显示历史速率", "TrafficMonitor.swift", "traffic != .available || paused", "traffic != .available"),
    ("健康错误被其他通道掩盖", "TrafficMonitor.swift", "if let health { issues.append(health) }", "if let health { _ = health }"),
    ("直连仍探测回退组", "FallbackBootstrap.swift", "guard state.mode != .direct else { return [] }", "guard true else { return [] }"),
    ("探测未引用回退组", "FallbackBootstrap.swift", "$0.kind == .fallback && visited.contains($0.id)", "$0.kind == .fallback"),
    ("共享节点重复探测", "FallbackBootstrap.swift", "seen.insert(id).inserted", "true"),
    ("突破四节点并发", "FallbackBootstrap.swift", "min(4, nodes.count)", "min(5, nodes.count)"),
    ("越过未知高优先级", "FallbackBootstrap.swift", "case .unknown: break", "case .unknown: continue"),
    ("事件风暴不合并", "NetworkCheckScheduler.swift", "guard !scheduled, !running else", "guard !running else"),
    ("取消仍执行旧检查", "NetworkCheckScheduler.swift", "guard !cancelled else { return }", "guard true else { return }"),
    ("重规划重复采样", "NetworkMonitor.swift", "currentSnapshot(sample: sample)", "currentSnapshot()"),
    ("忽略 DNS 冲突", "NetworkMonitor.swift", "if currentDNS != expected", "if false"),
    ("忽略路由冲突", "NetworkMonitor.swift", "issues += CaptureOwnership.protectionIssues(owned:expectedRoutes,preserved:record.preservedRoutes ?? [],actual:routes)", "issues += []"),
]


def run(command, output, timeout=120):
    with output.open("wb") as log:
        return subprocess.run(command, cwd=STAGE, stdout=log, stderr=log, timeout=timeout).returncode


# 先确认隔离副本本身通过，避免把既有失败计为检出。
assert run(["bash", "scripts/swift-local.sh", "build", "--product", "QingzhouChecks"], STAGE / "baseline-build.log") == 0
assert run([str(STAGE / ".build/debug/QingzhouChecks"), "optimization-checks"], STAGE / "baseline-checks.log") == 0
assert run(["bash", "scripts/network-monitor-checks.sh"], STAGE / "baseline-helper.log") == 0
results = []
for index, (name, filename, old, new) in enumerate(mutations):
    folder = "QingzhouHelper" if filename == "NetworkMonitor.swift" else "QingzhouKit"
    path = STAGE / "Sources" / folder / filename
    original = (ROOT / "Sources" / folder / filename).read_text()
    if old not in original:
        raise RuntimeError("变异位置未找到：" + name)
    path.write_text(original.replace(old, new))
    try:
        # 编译错误独立统计，不算检出。
        status = "BUILD_ERROR"
        product = "QingzhouHelper" if folder == "QingzhouHelper" else "QingzhouChecks"
        if run(["bash", "scripts/swift-local.sh", "build", "--product", product], STAGE / f"build-{index}.log") == 0:
            command = ["bash", "scripts/network-monitor-checks.sh"] if folder == "QingzhouHelper" else [str(STAGE / ".build/debug/QingzhouChecks"), "optimization-checks"]
            try:
                status = "KILLED" if run(command, STAGE / f"checks-{index}.log", timeout=30) else "SURVIVED"
            except subprocess.TimeoutExpired:
                # 正常基线已通过；变异造成的挂起单独记录，不能让整个检查丢失后续结果。
                status = "KILLED_TIMEOUT"
        results.append({"name": name, "file": filename, "status": status})
        print(status, name, flush=True)
    finally:
        path.write_text(original)
summary = {"scope": "首批优化的十五项定向变异，不代表全项目变异检出率", "results": results}
for status in ("KILLED", "KILLED_TIMEOUT", "SURVIVED", "BUILD_ERROR"):
    summary[status] = sum(row["status"] == status for row in results)
(ROOT / ".build/runtime-optimization-mutations.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
print("RESULT " + json.dumps({key: value for key, value in summary.items() if key != "results"}, ensure_ascii=False))
raise SystemExit(0 if summary["KILLED"] + summary["KILLED_TIMEOUT"] == len(mutations) else 1)
