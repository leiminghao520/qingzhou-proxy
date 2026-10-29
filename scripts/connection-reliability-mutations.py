#!/usr/bin/env python3
"""定向验证切换验收与出口健康隔离；变异仅写入构建目录。"""
import glob
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
stage = root / ".build/connection-reliability-mutations"
stage.mkdir(parents=True, exist_ok=True)
source = (root / "Sources/QingzhouKit/ConnectionReliability.swift").read_text()
mutations = [
    ("全部失败也确认切换", 'if target.status == .passed { return .verified }', 'if target.status == .passed || target.status == .failed { return .verified }'),
    ("网站通过掩盖节点故障", 'let target = results[requiresNode ? 1 : 0]', 'let target = results[0]'),
    ("超时当作节点失效", '? .unconfirmed : .failed', '? .failed : .failed'),
    ("鉴权错误放行", 'return .failed }', 'return .verified }'),
    ("出口失败计数互相污染", 'let failed = counter.update([status])', 'counters = [:]; let failed = counter.update([status])'),
    ("每轮清除出口失败", 'var counter = counters[id] ?? HealthFailureCounter()', 'var counter = HealthFailureCounter()'),
]
objects = []
for pattern in ["QingzhouKit.build/*.o", "CQingzhouRoute.build/*.o", "Yams.build/*.o", "CYaml.build/src/*.o"]:
    objects.extend(glob.glob(str(root / ".build/debug" / pattern)))
results = []
cases = [("基线", source)] + [(name, source.replace(old, new)) for name, old, new in mutations]
for index, (name, value) in enumerate(cases):
    path = stage / "ConnectionReliability.swift"
    path.write_text("import QingzhouKit\n" + value)
    command = ["swiftc", "-parse-as-library", "-swift-version", "5", "-I", str(root / ".build/debug/Modules"), "-I", str(root / "Vendor/Yams/Sources/CYaml/include"), "-Xcc", "-fmodule-map-file=" + str(root / ".build/debug/CQingzhouRoute.build/module.modulemap"), str(path), str(root / "scripts/connection-recovery-checks.swift"), *objects, "-o", str(stage / "checks")]
    with (stage / f"{index}.log").open("w") as log:
        built = subprocess.run(command, cwd=root, stdout=log, stderr=log)
        if built.returncode:
            raise SystemExit("变异编译失败，不能算检出：" + name)
        tested = subprocess.run([str(stage / "checks")], cwd=root, stdout=log, stderr=log, timeout=20)
    if index == 0:
        if tested.returncode:
            raise SystemExit("基线检查失败")
        continue
    result = {"name": name, "status": "KILLED" if tested.returncode else "SURVIVED"}
    results.append(result)
    print(result["status"], name, flush=True)
summary = {"scope": "连接验收与出口健康的六项定向变异，不代表全项目变异覆盖", "results": results, "killed": sum(item["status"] == "KILLED" for item in results)}
(stage / "results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
if summary["killed"] != len(mutations):
    raise SystemExit("存在未检出的变异")
